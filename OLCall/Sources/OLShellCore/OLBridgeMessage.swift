// Page -> app messages on the native bridge (window.OpenLoungeNative, see OLBridgeScript).
// Strict parser: anything malformed, oversized or unknown is dropped. Only pages on the app's
// own hosts are honoured (checked by the caller with OLAppURL.isAppURL on the frame URL).
import Foundation

public enum OLHaptic: String, CaseIterable {
    case raiseHand, joinStage, sendDm, light, medium, heavy, soft, rigid, selection, success, warning, error
}

/// Call messages the page posts as plain {"type":"call:*"} JSON.
public enum OLPageCallMessage: Equatable {
    case incoming(callId: String, name: String, video: Bool, photo: String?, expiresAt: Double?)
    case outgoing(callId: String, name: String, video: Bool, photo: String?)
    case answering(callId: String, name: String, video: Bool, photo: String?)
    case connected(callId: String)
    case ended(callId: String)
    case muted(Bool)
    case audioRoute(speaker: Bool)
    case ringbackStop
    case ringtonePrepare
}

public enum OLBridgeRequest: Equatable {
    case theme(String)
    case ready
    case haptic(OLHaptic)
    case openExternal(String)
    case share(text: String, url: String)
    case requestContacts
    case openAppSettings
    case requestNotificationPermission
    case setBadge(Int)
    case phoneAuthStart(id: String, phone: String)
    case phoneAuthConfirm(id: String, code: String)
    case call(OLPageCallMessage)
    case nativeMedia(id: String, command: [String: OLJSON])
    case getSession(id: String)
    case setSession(id: String, value: String)
    case clearSession(id: String)
    case openAuth(id: String, url: String)
    case bioIsAvailable(id: String)
    case bioGetEnabled(id: String)
    case bioSetEnabled(id: String, on: Bool)
}

/// A JSON value with value semantics (Equatable, Linux-safe).
public indirect enum OLJSON: Equatable {
    case null, bool(Bool), number(Double), string(String), array([OLJSON]), object([String: OLJSON])

    public init(_ any: Any?) {
        switch any {
        case nil, is NSNull: self = .null
        case let b as Bool where Self.isBool(any!): self = .bool(b)
        case let n as NSNumber: self = .number(n.doubleValue)
        case let i as Int: self = .number(Double(i))
        case let d as Double: self = .number(d)
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map { OLJSON($0) })
        case let o as [String: Any]: self = .object(o.mapValues { OLJSON($0) })
        default: self = .null
        }
    }

    static func isBool(_ v: Any) -> Bool {
        if v is Bool && type(of: v) == Bool.self { return true }
        #if canImport(Darwin)
        if let n = v as? NSNumber { return CFGetTypeID(n) == CFBooleanGetTypeID() }
        #endif
        return String(describing: type(of: v)) == "__NSCFBoolean"
    }

    public var string: String? { if case let .string(s) = self { return s }; return nil }
    public var bool: Bool? { if case let .bool(b) = self { return b }; return nil }
    public var number: Double? { if case let .number(n) = self { return n }; return nil }
    public var object: [String: OLJSON]? { if case let .object(o) = self { return o }; return nil }
    public subscript(_ k: String) -> OLJSON { object?[k] ?? .null }

    /// Foundation form (for JSONSerialization and OLCallMedia.parse).
    public var foundation: Any {
        switch self {
        case .null: return NSNull()
        case let .bool(b): return b
        case let .number(n): return n
        case let .string(s): return s
        case let .array(a): return a.map(\.foundation)
        case let .object(o): return o.mapValues(\.foundation)
        }
    }
}

public enum OLBridgeMessage {
    public static let maxBytes = 200_000
    static let callIdPattern = "^[A-Za-z0-9_-]{1,64}$"

    public static func isCallId(_ s: String) -> Bool { OLAppURL.matches(s, callIdPattern) }

    public static func parse(_ data: String) -> OLBridgeRequest? {
        guard data.utf8.count <= maxBytes, let raw = data.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: raw), let m = OLJSON(any).object else { return nil }
        if m["__ol"] == nil, let t = m["type"]?.string, t.hasPrefix("call:") {
            return parseCall(m).map(OLBridgeRequest.call)
        }
        guard m["__ol"]?.number == 1, let method = m["method"]?.string else { return nil }
        let value = m["value"] ?? .null
        switch method {
        case "theme":
            guard let t = value.string, t == "dark" || t == "light" else { return nil }
            return .theme(t)
        case "ready": return .ready
        case "haptic": return value.string.flatMap(OLHaptic.init(rawValue:)).map(OLBridgeRequest.haptic)
        case "openExternal":
            guard let s = value.string, s.count <= 4096 else { return nil }
            return .openExternal(s)
        case "share":
            guard let t = value["text"].string, let u = value["url"].string, t.count <= 1000, u.count <= 2048 else { return nil }
            return .share(text: t, url: u)
        case "phoneAuthStart":
            guard let id = value["id"].string, id.count <= 100, let p = value["phone"].string,
                  OLAppURL.matches(p, "^\\+[0-9]{6,16}$") else { return nil }
            return .phoneAuthStart(id: id, phone: p)
        case "phoneAuthConfirm":
            guard let id = value["id"].string, id.count <= 100, let c = value["code"].string,
                  OLAppURL.matches(c, "^[0-9]{4,8}$") else { return nil }
            return .phoneAuthConfirm(id: id, code: c)
        case "setBadge":
            guard let n = value.number, n.isFinite, n >= 0 else { return nil }
            return .setBadge(Int(min(9999, n.rounded(.down))))
        case "requestContacts": return .requestContacts
        case "openAppSettings": return .openAppSettings
        case "requestNotificationPermission": return .requestNotificationPermission
        default: break
        }
        guard let id = m["id"]?.string, id.count <= 64 else { return nil }
        switch method {
        case "nativeMedia":
            guard let o = value.object, o["op"]?.string != nil else { return nil }
            return .nativeMedia(id: id, command: o)
        case "getSession": return .getSession(id: id)
        case "clearSession": return .clearSession(id: id)
        case "setSession": return value.string.map { .setSession(id: id, value: $0) }
        case "openAuth": return value.string.map { .openAuth(id: id, url: $0) }
        case "bioIsAvailable": return .bioIsAvailable(id: id)
        case "bioGetEnabled": return .bioGetEnabled(id: id)
        case "bioSetEnabled": return value.bool.map { .bioSetEnabled(id: id, on: $0) }
        default: return nil
        }
    }

    static func parseCall(_ m: [String: OLJSON]) -> OLPageCallMessage? {
        let rawId = m["callId"]?.string
        let id = rawId.flatMap { isCallId($0) ? $0 : nil } ?? ""
        let name = String((m["name"]?.string ?? "").prefix(80))
        let video = m["video"]?.bool == true
        let photo = m["photo"]?.string.flatMap { $0.isEmpty ? nil : String($0.prefix(500)) }
        switch m["type"]?.string {
        case "call:incoming":
            return id.isEmpty ? nil : .incoming(callId: id, name: name, video: video, photo: photo, expiresAt: m["expiresAt"]?.number)
        case "call:outgoing":
            return id.isEmpty ? nil : .outgoing(callId: id, name: name, video: video, photo: photo)
        case "call:answering":
            return id.isEmpty ? nil : .answering(callId: id, name: name, video: video, photo: photo)
        case "call:connected":
            return rawId != nil && id.isEmpty ? nil : .connected(callId: id)
        case "call:ended":
            return rawId != nil && id.isEmpty ? nil : .ended(callId: id)
        case "call:muted":
            return m["muted"]?.bool.map(OLPageCallMessage.muted)
        case "call:audioRoute":
            return m["speaker"]?.bool.map { OLPageCallMessage.audioRoute(speaker: $0) }
        case "call:ringbackStop": return .ringbackStop
        case "call:ringtonePrepare": return .ringtonePrepare
        default: return nil
        }
    }
}
