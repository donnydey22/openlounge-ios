// OLCallAudioDevice — the call's audio device module and the ONLY owner of AVAudioSession
// during a call. Nothing else in the app configures, activates or deactivates the session.
//
// Audio device: the engine's SharedCallAudioDevice (VoiceProcessingIO). It is created before the
// engine instance and handed to it, and it records/plays nothing until
// setManualAudioSessionIsActive(true), which this class calls only once the session is active,
// so the session is ours from the first sample.
//
// Session: configured by +[SharedCallAudioDevice setupAudioSession] (PlayAndRecord, VoiceChat,
// Bluetooth allowed, inactive), then activated by CallKit (didActivate) or by this class
// (setActive(true)) under the C policy in OLAudioCore (retry transient errors, wait out a
// higher-priority interruption, report the verbatim NSError code). Interruptions, route changes
// and media-services resets are handled here.
//
// Threading: every state change runs on `queue`; callbacks go to the main queue.
import AVFAudio
import Foundation
import OLAudioCore
import OLCallCore
import TgVoipWebrtc

public final class OLCallAudioDevice {
    public enum Outcome { case active, failed(domain: String, code: Int32, first: Int32) }

    /// Handed to the engine instance.
    public let shared: SharedCallAudioDevice
    /// Main queue: audio usable (true) / suspended (false), e.g. interruption.
    public var onActiveChanged: ((Bool) -> Void)?
    /// Main queue: route changed (new output port type, e.g. "Speaker", "Receiver", "BluetoothHFP").
    public var onRouteChanged: ((String) -> Void)?
    /// Structured audio-session trail for the call log (logging only; t5614u target 1). Called on `queue`.
    /// Events: audio_session_requested / callkit_did_activate / callkit_did_deactivate / audio_session_setactive /
    /// audio_session_activated / audio_session_failed / audio_engine_start / audio_engine_stop / audio_session_note.
    public var onLog: ((String, [String: Any]) -> Void)?
    /// "push" (app not active when the call's media started, e.g. VoIP-push wake) or "foreground". Set before begin().
    public var trigger = "foreground"
    private var requestedAt: Date?
    private var activateVia = "callkit"
    private var lastSetActiveError: [String: Any]?

    private var policy = ol_session()
    private let crumbs: OLBreadcrumbs
    private let usesCallKit: Bool
    private let queue = DispatchQueue(label: "ol.call.audio")
    private var onOutcome: ((Outcome) -> Void)?
    private var timeoutWork: DispatchWorkItem?
    private var speaker = false
    private var ended = false
    private var observers: [NSObjectProtocol] = []

    /// - Parameter usesCallKit: true when the app reports the call to CallKit and forwards
    ///   provider(_:didActivate:) / provider(_:didDeactivate:) to this object.
    public init(usesCallKit: Bool, crumbs: OLBreadcrumbs) {
        self.usesCallKit = usesCallKit
        self.crumbs = crumbs
        shared = SharedCallAudioDevice(disableRecording: false, enableSystemMute: false)
        ol_session_init(&policy, usesCallKit ? 1 : 0, 3)
        shared.startResultHandler = { [weak self, crumbs] started, failure, attempts in
            crumbs.event("adm", "ios.adm-start:\(started ? "ok" : "failed"):attempts=\(attempts)\(failure.map { ":" + $0 } ?? "")",
                         level: started ? "info" : "error")
            guard let self else { return }
            self.queue.async {
                var x: [String: Any] = ["ok": started, "attempts": Int(attempts)]
                if let failure { x["failure"] = String(failure.prefix(160)) }
                self.log("audio_engine_start", x)
            }
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

    // MARK: structured log (queue)

    private func sessionSnapshot() -> [String: Any] {
        let s = AVAudioSession.sharedInstance()
        return ["category": s.category.rawValue, "mode": s.mode.rawValue,
                "route": s.currentRoute.outputs.first?.portType.rawValue ?? "none",
                "input": s.currentRoute.inputs.first?.portType.rawValue ?? "none",
                "policyState": String(cString: ol_session_state_name(policy.state)), "callkit": usesCallKit, "trigger": trigger]
    }

    private func sinceRequestedMs() -> Int { requestedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1 }

    private func log(_ name: String, _ extra: [String: Any] = [:]) {
        var x = sessionSnapshot()
        x["msSinceRequested"] = sinceRequestedMs()
        for (k, v) in extra { x[k] = v }
        onLog?(name, x)
    }

    /// Every early return / swallowed error leaves a line (no silent failures).
    private func note(_ what: String, _ extra: [String: Any] = [:]) {
        crumbs.event("adm", "ios.note:\(what)", level: "warning")
        var x = extra
        x["what"] = what
        log("audio_session_note", x)
    }

    /// Configure the session (inactive) and activate it per policy. With CallKit, activation is
    /// CallKit's: this only arms a 5 s didActivate deadline.
    public func begin(speakerOn: Bool, completion: @escaping (Outcome) -> Void) {
        queue.async {
            self.onOutcome = completion
            self.speaker = speakerOn
            SharedCallAudioDevice.setupAudioSession()
            self.crumbs.event("adm", "ios.session-configured:speaker=\(speakerOn)")
            self.requestedAt = Date()
            self.activateVia = self.usesCallKit ? "callkit" : "setActive"
            self.log("audio_session_requested", ["speaker": speakerOn, "awaiting": self.usesCallKit ? "callkit-didActivate(5s)" : "setActive"])
            self.apply(ol_session_begin(&self.policy))
            if self.usesCallKit { self.armTimeout(seconds: 5) }
        }
    }

    /// Loudspeaker on/off (video calls start on the loudspeaker, audio calls on the receiver).
    public func setSpeaker(_ on: Bool) {
        queue.async {
            self.speaker = on
            self.applyRoute()
        }
    }

    public func end() {
        queue.async {
            guard !self.ended else { return self.note("end-after-end") }
            self.ended = true
            self.timeoutWork?.cancel()
            self.shared.setManualAudioSessionIsActive(false)
            self.shared.stop()
            if !self.usesCallKit {
                do {
                    try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                } catch {
                    self.note("setActive(false)-failed", OLAudioStatus.describe(error))
                }
            }
            self.crumbs.event("adm", "ios.session-ended")
            self.log("audio_engine_stop", [:])
        }
    }

    // MARK: CallKit (a CXProviderDelegate forwards these)

    public func callKitDidActivate(_ session: AVAudioSession) {
        queue.async {
            self.crumbs.event("adm", "ios.callkit-didActivate:state=\(String(cString: ol_session_state_name(self.policy.state)))")
            self.log("callkit_did_activate")
            let act = ol_session_on_callkit_activate(&self.policy)
            if act == OL_ACT_NONE { self.note("didActivate-ignored(already-active)") }
            self.activateVia = "callkit"
            self.apply(act)
        }
    }

    public func callKitDidDeactivate(_ session: AVAudioSession) {
        queue.async {
            self.crumbs.event("adm", "ios.callkit-didDeactivate:state=\(String(cString: ol_session_state_name(self.policy.state)))")
            self.log("callkit_did_deactivate")
            let act = ol_session_on_callkit_deactivate(&self.policy)
            if act == OL_ACT_NONE { self.note("didDeactivate-ignored(not-active)") }
            self.apply(act)
        }
    }

    // MARK: notifications

    private func onInterruption(_ n: Notification) {
        guard let info = n.userInfo, let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else {
            queue.async { self.note("interruption-unparsed") }
            return
        }
        let opts = (info[AVAudioSessionInterruptionOptionKey] as? UInt).map { AVAudioSession.InterruptionOptions(rawValue: $0) } ?? []
        queue.async {
            guard !self.ended else { return self.note("interruption-after-end") }
            self.crumbs.event("adm", "ios.interruption:\(type == .began ? "began" : "ended"):resume=\(opts.contains(.shouldResume))")
            self.log("audio_session_note", ["what": "interruption-\(type == .began ? "began" : "ended")", "shouldResume": opts.contains(.shouldResume)])
            self.apply(ol_session_on_interruption(&self.policy, type == .began ? 1 : 0, opts.contains(.shouldResume) ? 1 : 0))
            if type == .began { self.armTimeout(seconds: 30) }
        }
    }

    private func onRouteChange(_ n: Notification) {
        let reason = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
        queue.async {
            guard !self.ended else { return } // routes keep changing after the call; not a failure
            let out = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType.rawValue ?? "none"
            self.crumbs.event("adm", "ios.route:\(reason.map { "\($0.rawValue)" } ?? "?"):\(out)")
            switch reason {
            case .oldDeviceUnavailable, .newDeviceAvailable, .categoryChange, .override, .routeConfigurationChange:
                // A headset or Bluetooth device came or went: re-assert the speaker choice
                // unless an external device now owns the route.
                self.applyRoute()
            default:
                break
            }
            DispatchQueue.main.async { self.onRouteChanged?(out) }
        }
    }

    private func onMediaServicesReset() {
        // mediaserverd restarted: every audio object is invalid. Run the policy again from the start.
        queue.async {
            guard !self.ended else { return self.note("media-services-reset-after-end") }
            self.crumbs.event("adm", "ios.media-services-reset", level: "warning")
            self.log("audio_session_note", ["what": "media-services-reset"])
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
            note("override-output-failed", OLAudioStatus.describe(error))
        }
    }

    private func callSetActive() {
        var status: Int32 = 0
        var err: [String: Any] = [:]
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            status = Int32(truncatingIfNeeded: (error as NSError).code) // verbatim, e.g. '!pri' = 561017449
            err = OLAudioStatus.describe(error)
            lastSetActiveError = err
        }
        crumbs.event("adm", "ios.setActive:\(status)", level: status == 0 ? "info" : "warning")
        var x = err
        x["ok"] = status == 0
        x["status"] = Int(status)
        x["attempt"] = Int(policy.attempts)
        log("audio_session_setactive", x)
        activateVia = "setActive"
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
            // First moment the audio device may touch the hardware.
            shared.setManualAudioSessionIsActive(true)
            crumbs.event("adm", "ios.audio-enabled")
            log("audio_session_activated", ["via": activateVia])
            DispatchQueue.main.async { self.onActiveChanged?(true) }
            finish(.active)
        case OL_ACT_DISABLE_AUDIO:
            shared.setManualAudioSessionIsActive(false)
            crumbs.event("adm", "ios.audio-disabled")
            log("audio_session_note", ["what": "audio-disabled"])
            DispatchQueue.main.async { self.onActiveChanged?(false) }
        case OL_ACT_REPORT_FAILURE:
            timeoutWork?.cancel()
            crumbs.event("adm", "ios.session-failed:first=\(policy.first_status),last=\(policy.last_status)", level: "error")
            var x: [String: Any] = ["first": Int(policy.first_status), "last": Int(policy.last_status), "attempts": Int(policy.attempts),
                                    "cause": policy.last_status == -1 ? (usesCallKit ? "timeout-no-callkit-didActivate" : "timeout") : "setActive-error",
                                    "domain": "avaudiosession", "code": Int(policy.last_status)]
            if let f = OLAudioStatus.fourCC(Int(policy.last_status)) { x["osstatus"] = f }
            if let e = lastSetActiveError { x["lastNSError"] = e }
            log("audio_session_failed", x)
            finish(.failed(domain: "avaudiosession", code: policy.last_status, first: policy.first_status))
        default:
            break // OL_ACT_NONE / OL_ACT_SCHEDULE_RETRY: nothing to do here (retries are scheduled by callSetActive)
        }
    }

    private func armTimeout(seconds: Int) {
        timeoutWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.crumbs.event("adm", "ios.timeout:state=\(String(cString: ol_session_state_name(self.policy.state)))", level: "warning")
            self.log("audio_session_note", ["what": "timeout-\(seconds)s"])
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
