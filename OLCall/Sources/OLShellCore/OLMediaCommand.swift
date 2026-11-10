// The page's nativeMedia(cmd) commands (same ops as the Open Lounge Android app). The page owns
// call control on Railway; the app owns the call's media: one OLTgcallsEngine per call.
import Foundation

public enum OLMediaCommand: Equatable {
    case connect(callId: String, media: OLJSON, video: Bool, caller: Bool)
    case camera(on: Bool, front: Bool)
    case mute(Bool)
    case close
    case prewarm
    case stats
    case restartIce
    case signalConnected
    case videoLayout
    case unknown(String)

    public static func parse(_ c: [String: OLJSON]) -> OLMediaCommand? {
        guard let op = c["op"]?.string else { return nil }
        switch op {
        case "connect":
            guard let id = c["callId"]?.string, OLBridgeMessage.isCallId(id) else { return nil }
            return .connect(callId: id, media: c["media"] ?? .null, video: c["video"]?.bool == true, caller: c["caller"]?.bool == true)
        case "camera": return .camera(on: c["on"]?.bool == true, front: c["facing"]?.string != "environment")
        case "mute": return .mute(c["muted"]?.bool == true)
        case "close", "end": return .close
        case "prewarm": return .prewarm
        case "stats": return .stats
        case "restartIce": return .restartIce
        case "signalConnected": return .signalConnected
        case "videoLayout": return .videoLayout
        default: return .unknown(op)
        }
    }
}
