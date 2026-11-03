// Native call signaling over the existing TLS WebSocket (call-signal). Same protocol as Android/browser:
// call:new{to,kind,route} / call:accept / call:reject / call:leave / offer|answer|ice{sdp with a=crypto} / sfu:plain.
// Runs entirely in native; RN only receives UI events via `onUIEvent`.
import Foundation
import VideoToolbox

public final class CallSignalClient: NSObject {
  public enum Route: String { case p2p, sfu }
  public var onMessage: (([String: Any]) -> Void)?
  public var onUIEvent: ((String, [String: Any]) -> Void)?
  private var task: URLSessionWebSocketTask?
  private let url: URL
  private var ackSeq = 0

  public init(baseURL: URL, token: String) {
    var c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
    c.queryItems = [URLQueryItem(name: "token", value: token)]
    url = c.url!
  }
  public func connect() { task = URLSession(configuration: .default).webSocketTask(with: url); task?.resume(); receive() }
  public func close() { task?.cancel(with: .normalClosure, reason: nil); task = nil }

  public func call(to: String, video: Bool, route: Route) { send(["t": "call:new", "to": to, "kind": video ? "video" : "audio", "route": route.rawValue]) }
  public func accept(_ callId: String) { send(["t": "call:accept", "callId": callId]) }
  public func reject(_ callId: String) { send(["t": "call:reject", "callId": callId]) }
  public func leave(_ callId: String) { send(["t": "call:leave", "callId": callId]) }
  public func sdp(_ type: String, callId: String, sdp: String) { send(["t": type, "callId": callId, "sdp": sdp]) }
  public func sfuPlain(callId: String, sdp: String) { send(["t": "sfu:plain", "callId": callId, "sdp": sdp]) }

  /// Capability advertised in SDP/signaling; AV1 only where hardware decode exists.
  public static var hardwareAV1: Bool { if #available(iOS 17.0, *) { return VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) } else { return false } }

  private func send(_ m: [String: Any]) {
    var m = m; ackSeq += 1; m["ack"] = ackSeq
    guard let d = try? JSONSerialization.data(withJSONObject: m), let s = String(data: d, encoding: .utf8) else { return }
    task?.send(.string(s)) { _ in }
  }
  private func receive() {
    task?.receive { [weak self] r in
      guard let self else { return }
      if case .success(.string(let s)) = r, let d = s.data(using: .utf8), let m = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
        self.onMessage?(m)
        if let t = m["t"] as? String, ["call:incoming", "call:accepted", "call:ended", "call:busy"].contains(t) { self.onUIEvent?(t, m) }
      }
      if case .failure = r { self.onUIEvent?("signal:disconnected", [:]); return }
      self.receive()
    }
  }
}

/// a=crypto helpers (baseline AES_CM_128_HMAC_SHA1_80, keys only in SDP).
public enum SDPCrypto {
  public static func key(in sdp: String) -> String? {
    guard let r = sdp.range(of: #"a=crypto:\d+ AES_CM_128_HMAC_SHA1_80 inline:([A-Za-z0-9+/=]{40})"#, options: .regularExpression) else { return nil }
    return String(sdp[r].split(separator: ":").last!)
  }
}
