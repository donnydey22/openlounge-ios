// OLCall — headless lifecycle of one Open Lounge phone call on iOS:
//
//   OLCallAudioDevice (ADM + AVAudioSession)  created first
//   OLSignalingRelay  join -> joined(key, isOutgoing)
//   OLTgcallsCall     tgcalls Instance; blobs relayed both ways unchanged
//
// UI-agnostic: the OL call screen (Expo module OpenLoungeOlcall / OLCallSession)
// maps `onEvent` to its existing avatar/squircle UI.
import AVFAudio
import Foundation
import UIKit

public final class OLCall {
    public enum Event {
        case joined(isOutgoing: Bool, version: String)
        case state(OLTgcallsCall.State, remoteVideoActive: Bool, remoteMuted: Bool)
        case audio(active: Bool)
        case audioFailed(String)
        case remoteVideoView(UIView)
        case localVideoView(UIView)
        case route(String)
        case ended(String)
    }

    /// Main queue.
    public var onEvent: ((Event) -> Void)?

    public let traceId = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)).lowercased()
    public let version: String

    private let queue = OLCallQueue(label: "ol.call.tgcalls")
    private let crumbs: OLBreadcrumbs
    private let audio: OLCallAudioDevice
    private let relay: OLSignalingRelay
    private let token: String
    private let video: Bool
    private var engine: OLTgcallsCall?
    private var ended = false

    /// - Parameters:
    ///   - serverURL: wss://<olcall host>/v1/call
    ///   - joinToken: the olcall token the OL backend issued for THIS party on call:accept
    ///   - video: start with the camera on (and loudspeaker, OL behaviour)
    ///   - usesCallKit: forward CXProvider didActivate/didDeactivate to callKitDidActivate/Deactivate
    public init(serverURL: URL, joinToken: String, video: Bool, usesCallKit: Bool) throws {
        let local = OLTgcallsCall.linkedVersions()
        guard let v = OLTgcallsVersion.pick(local: local) else { throw OLTgcallsError.noCommonVersion(local) }
        version = v
        token = joinToken
        self.video = video
        crumbs = OLBreadcrumbs(crumbURL: OLBreadcrumbs.crumbURL(forCallURL: serverURL), engineBuild: OLSignalingRelay.engine)
        audio = OLCallAudioDevice(usesCallKit: usesCallKit, crumbs: crumbs)
        relay = OLSignalingRelay(url: serverURL, queue: queue, crumbs: crumbs)
    }

    public func start() {
        crumbs.traceId = traceId
        audio.onActiveChanged = { [weak self] on in self?.emit(.audio(active: on)) }
        audio.onRouteChanged = { [weak self] r in self?.emit(.route(r)) }
        audio.begin(speakerOn: video) { [weak self] outcome in
            if case let .failed(domain, code, first) = outcome { self?.emit(.audioFailed("\(domain):\(code):\(first)")) }
        }
        relay.onInbound = { [weak self] in self?.onInbound($0) }
        relay.onClosed = { [weak self] reason in self?.finish(reason) }
        relay.start(join: .init(token: token, traceId: traceId, version: version, device: OLDevice.model,
                                os: "iOS \(UIDevice.current.systemVersion)"))
    }

    public func setMuted(_ m: Bool) { engine?.setMuted(m) }
    public func setVideoEnabled(_ on: Bool) {
        engine?.setVideoEnabled(on)
        if on { engine?.makeOutgoingVideoView { [weak self] v in if let v { self?.emit(.localVideoView(v)) } } }
    }
    public func switchCamera(front: Bool) { engine?.switchCamera(front: front) }
    public func setSpeaker(_ on: Bool) { audio.setSpeaker(on) }
    public func hangup() { relay.hangup() }

    public func callKitDidActivate(_ s: AVAudioSession) { audio.callKitDidActivate(s) }
    public func callKitDidDeactivate(_ s: AVAudioSession) { audio.callKitDidDeactivate(s) }

    // queue
    private func onInbound(_ m: OLSignalingRelay.Inbound) {
        switch m {
        case let .joined(j):
            crumbs.callId = j.callId
            crumbs.leg = j.leg
            crumbs.event("tg", "joined:outgoing=\(j.isOutgoing):version=\(version)")
            if !j.serverVersions.isEmpty && !j.serverVersions.contains(version) {
                crumbs.event("tg", "server-lacks-version:\(version)", level: "error")
                relay.hangup()
                return
            }
            let docs = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            do {
                var key = j.key
                let e = try OLTgcallsCall(config: .init(version: version, key: key, isOutgoing: j.isOutgoing, video: video,
                                                        logDirectory: docs, traceId: traceId),
                                          queue: queue, audioDevice: audio,
                                          sendSignalingData: { [weak self] blob in self?.relay.sendBlob(blob) })
                key.resetBytes(in: 0..<key.count)  // tgcalls holds its own copy
                e.onState = { [weak self] st, rv, rm in
                    self?.emit(.state(st, remoteVideoActive: rv, remoteMuted: rm))
                    if st == .failed { self?.relay.close("tg-failed") }
                }
                engine = e
                e.makeIncomingVideoView { [weak self] v in if let v { self?.emit(.remoteVideoView(v)) } }
                if video { e.makeOutgoingVideoView { [weak self] v in if let v { self?.emit(.localVideoView(v)) } } }
                emit(.joined(isOutgoing: j.isOutgoing, version: version))
            } catch {
                crumbs.event("tg", "create-failed:\(error)", level: "error")
                relay.close("native-create-failed")
            }
        case let .blob(b):
            engine?.receiveSignalingData(b)
        case let .bye(reason):
            relay.close("bye:\(reason)")
        case let .error(e):
            crumbs.event("ws", "server-error:\(e)", level: "error")
            relay.close("server-error")
        case .stats, .pong, .ignored:
            break
        }
    }

    // queue
    private func finish(_ reason: String) {
        guard !ended else { return }
        ended = true
        engine?.stop()
        engine = nil
        audio.end()
        crumbs.event("call", "ended:\(reason)")
        crumbs.flush()
        emit(.ended(reason))
    }

    private func emit(_ e: Event) { DispatchQueue.main.async { self.onEvent?(e) } }
}
