// OLCallAudioDevice — the call's AudioDeviceModule and the AVAudioSession owner.
//
// ADM: TgVoipWebrtc's SharedCallAudioDevice, i.e. tgcalls'
// webrtc::tgcalls_ios_adm::AudioDeviceModuleIOS (tgcalls/platform/darwin/iOS,
// VoiceProcessingIO unit) wrapped as tgcalls::SharedAudioDeviceModule. It is
// created BEFORE the tgcalls Instance and handed to it through
// OngoingCallThreadLocalContextWebrtc(audioDevice:), which feeds the Instance a
// child ADM (Descriptor.createWrappedAudioDeviceModule). Nothing records or
// plays until `setManualAudioSessionIsActive(true)`, which this class calls only
// after AVAudioSession is active — so the session is ours from the first sample.
// This is exactly Telegram-iOS's production pattern (SharedCallAudioDevice +
// manual audio + CallKit didActivate).
//
// AVAudioSession: configured through +[SharedCallAudioDevice setupAudioSession]
// (RTCAudioSessionConfiguration: PlayAndRecord / VoiceChat / MixWithOthers /
// AllowBluetoothA2DP, mono output, inactive), activated either by CallKit
// (didActivate) or by us (setActive(true)) under the tested C policy
// audio/core/ol_session_policy.c (retry transient errors, wait for the end of a
// higher-priority interruption on '!pri', report the verbatim NSError code).
// Interruptions, route changes and media-services resets are handled here.
//
// Threading: every state change runs on `queue`; callbacks go to the main queue.
// Replaces audio/ios/OLAudioSessionController.swift (which predates the
// SharedCallAudioDevice integration and set the category itself).
import AVFAudio
import Foundation
#if canImport(OLAudioCore)
import OLAudioCore
#endif
#if canImport(TgVoipWebrtc)
import TgVoipWebrtc
#endif

public final class OLCallAudioDevice {
    public enum Outcome { case active, failed(domain: String, code: Int32, first: Int32) }

    /// Handed to OngoingCallThreadLocalContextWebrtc(audioDevice:).
    public let shared: SharedCallAudioDevice
    /// Main queue: audio usable (true) / suspended (false), e.g. interruption.
    public var onActiveChanged: ((Bool) -> Void)?
    /// Main queue: route changed (new output port type, e.g. "Speaker", "Receiver", "BluetoothHFP").
    public var onRouteChanged: ((String) -> Void)?

    private var policy = ol_session()
    private let crumbs: OLBreadcrumbs
    private let usesCallKit: Bool
    private let queue = DispatchQueue(label: "ol.call.audio")
    private var onOutcome: ((Outcome) -> Void)?
    private var timeoutWork: DispatchWorkItem?
    private var speaker = false
    private var ended = false
    private var observers: [NSObjectProtocol] = []

    /// - Parameter usesCallKit: true when the app reports the call to CallKit and
    ///   forwards provider(_:didActivate:)/(_:didDeactivate:) to this object.
    public init(usesCallKit: Bool, crumbs: OLBreadcrumbs) {
        self.usesCallKit = usesCallKit
        self.crumbs = crumbs
        shared = SharedCallAudioDevice(disableRecording: false, enableSystemMute: false)
        ol_session_init(&policy, usesCallKit ? 1 : 0, 3)
        shared.startResultHandler = { [crumbs] started, failure, attempts in
            // AudioDeviceModuleIOS start (VPIO unit init/start), verbatim.
            crumbs.event("adm", "ios.adm-start:\(started ? "ok" : "failed"):attempts=\(attempts)\(failure.map { ":" + $0 } ?? "")",
                         level: started ? "info" : "error")
        }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] n in
            self?.onInterruption(n)
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] n in
            self?.onRouteChange(n)
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { [weak self] _ in
            self?.onMediaServicesReset()
        })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    /// Configure the session (inactive) and activate it per policy. With CallKit,
    /// activation is CallKit's: this only arms a 5 s didActivate watchdog.
    public func begin(speakerOn: Bool, completion: @escaping (Outcome) -> Void) {
        queue.async {
            self.onOutcome = completion
            self.speaker = speakerOn
            SharedCallAudioDevice.setupAudioSession()
            self.crumbs.event("adm", "ios.session-configured:speaker=\(speakerOn)")
            self.apply(ol_session_begin(&self.policy))
            if self.usesCallKit { self.armTimeout(seconds: 5) }
        }
    }

    /// Loudspeaker on/off (video calls default on, audio calls receiver — OL behaviour).
    public func setSpeaker(_ on: Bool) {
        queue.async {
            self.speaker = on
            self.applyRoute()
        }
    }

    public func end() {
        queue.async {
            guard !self.ended else { return }
            self.ended = true
            self.timeoutWork?.cancel()
            self.shared.setManualAudioSessionIsActive(false)
            self.shared.stop()
            if !self.usesCallKit {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
            self.crumbs.event("adm", "ios.session-ended")
        }
    }

    // MARK: CallKit (CXProviderDelegate forwards these)

    public func callKitDidActivate(_ session: AVAudioSession) {
        queue.async { self.apply(ol_session_on_callkit_activate(&self.policy)) }
    }

    public func callKitDidDeactivate(_ session: AVAudioSession) {
        queue.async { self.apply(ol_session_on_callkit_deactivate(&self.policy)) }
    }

    // MARK: notifications

    private func onInterruption(_ n: Notification) {
        guard let info = n.userInfo, let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        let opts = (info[AVAudioSessionInterruptionOptionKey] as? UInt).map { AVAudioSession.InterruptionOptions(rawValue: $0) } ?? []
        queue.async {
            guard !self.ended else { return }
            self.crumbs.event("adm", "ios.interruption:\(type == .began ? "began" : "ended"):resume=\(opts.contains(.shouldResume))")
            self.apply(ol_session_on_interruption(&self.policy, type == .began ? 1 : 0, opts.contains(.shouldResume) ? 1 : 0))
            if type == .began { self.armTimeout(seconds: 30) }
        }
    }

    private func onRouteChange(_ n: Notification) {
        let reason = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
        queue.async {
            guard !self.ended else { return }
            let out = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType.rawValue ?? "none"
            self.crumbs.event("adm", "ios.route:\(reason.map { "\($0.rawValue)" } ?? "?"):\(out)")
            switch reason {
            case .oldDeviceUnavailable, .newDeviceAvailable, .categoryChange, .override, .routeConfigurationChange:
                // Headset/Bluetooth came or went, or WebRTC re-applied its category:
                // re-assert the user's speaker choice unless an external device now owns the route.
                self.applyRoute()
            default:
                break
            }
            DispatchQueue.main.async { self.onRouteChanged?(out) }
        }
    }

    private func onMediaServicesReset() {
        // mediaserverd restarted: every audio object is invalid. Re-run the policy from the start.
        queue.async {
            guard !self.ended else { return }
            self.crumbs.event("adm", "ios.media-services-reset", level: "warning")
            self.shared.setManualAudioSessionIsActive(false)
            SharedCallAudioDevice.setupAudioSession()
            ol_session_init(&self.policy, self.usesCallKit ? 1 : 0, 3)
            self.apply(ol_session_begin(&self.policy))
        }
    }

    // MARK: policy

    private func applyRoute() {
        let s = AVAudioSession.sharedInstance()
        let external = s.currentRoute.outputs.contains { [.bluetoothHFP, .bluetoothA2DP, .bluetoothLE, .headphones, .carAudio, .usbAudio].contains($0.portType) }
        do {
            try s.overrideOutputAudioPort(speaker && !external ? .speaker : .none)
        } catch {
            crumbs.event("adm", "ios.override-failed:\((error as NSError).code)", level: "warning")
        }
    }

    private func callSetActive() {
        var status: Int32 = 0
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            status = Int32(truncatingIfNeeded: (error as NSError).code) // verbatim, e.g. '!pri' = 561017449
        }
        crumbs.event("adm", "ios.setActive:\(status)", level: status == 0 ? "info" : "warning")
        var delay: Int64 = 0
        let act = ol_session_on_set_active(&policy, status, &delay)
        if act == OL_ACT_SCHEDULE_RETRY {
            queue.asyncAfter(deadline: .now() + .milliseconds(Int(delay))) { self.apply(ol_session_on_timer(&self.policy)) }
        } else {
            apply(act)
            if policy.state == OL_SESS_WAIT_INTERRUPTION { armTimeout(seconds: 30) }
        }
    }

    private func apply(_ act: ol_session_action) {
        switch act {
        case OL_ACT_CALL_SET_ACTIVE:
            callSetActive()
        case OL_ACT_ENABLE_AUDIO:
            timeoutWork?.cancel()
            applyRoute()
            // First moment tgcalls' ADM may touch the hardware.
            shared.setManualAudioSessionIsActive(true)
            crumbs.event("adm", "ios.audio-enabled")
            DispatchQueue.main.async { self.onActiveChanged?(true) }
            finish(.active)
        case OL_ACT_DISABLE_AUDIO:
            shared.setManualAudioSessionIsActive(false)
            crumbs.event("adm", "ios.audio-disabled")
            DispatchQueue.main.async { self.onActiveChanged?(false) }
        case OL_ACT_REPORT_FAILURE:
            timeoutWork?.cancel()
            crumbs.event("adm", "ios.session-failed:first=\(policy.first_status),last=\(policy.last_status)", level: "error")
            finish(.failed(domain: "avaudiosession", code: policy.last_status, first: policy.first_status))
        default:
            break
        }
    }

    private func armTimeout(seconds: Int) {
        timeoutWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.apply(ol_session_on_timeout(&self.policy))
        }
        timeoutWork = w
        queue.asyncAfter(deadline: .now() + .seconds(seconds), execute: w)
    }

    private func finish(_ o: Outcome) {
        let cb = onOutcome
        onOutcome = nil
        DispatchQueue.main.async { cb?(o) }
    }
}
