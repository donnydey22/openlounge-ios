// OLCallPermissions — when the app may ask for the microphone and the camera.
//
//   app launch            nothing (no gate entry exists for it)
//   audio call tap        microphone only
//   video call tap        camera + microphone, one combined flow (camera, then microphone)
//   video on mid-call     camera only, at that moment
//   anything denied       that call / that toggle fails silently: no retry, no nag, no re-prompt
//
// A permission iOS already reports as denied or restricted is never requested again; the system
// prompt is shown at most once per permission, only while it is still undetermined.
import Foundation

public enum OLDevicePermission: String, CaseIterable { case microphone, camera }

public enum OLPermissionStatus { case undetermined, granted, denied }

/// The intents that may ask. There is deliberately no launch intent.
public enum OLCallPermissionIntent: Equatable {
    case audioCall
    case videoCall
    case videoToggle

    /// What this intent needs, in the order it is asked.
    public var required: [OLDevicePermission] {
        switch self {
        case .audioCall: return [.microphone]
        case .videoCall: return [.camera, .microphone]
        case .videoToggle: return [.camera]
        }
    }
}

/// System access, injectable for tests (the app uses AVCaptureDevice).
public protocol OLPermissionProvider: AnyObject {
    func status(_ p: OLDevicePermission) -> OLPermissionStatus
    /// Shows the one system prompt; completion(true) if granted.
    func request(_ p: OLDevicePermission, completion: @escaping (Bool) -> Void)
}

public final class OLCallPermissionGate {
    private let provider: OLPermissionProvider

    public init(provider: OLPermissionProvider) { self.provider = provider }

    /// completion(true) only when every required permission is granted. A denial anywhere ends the
    /// flow at once with false; the caller drops the call (or the toggle) without any message.
    public func authorize(_ intent: OLCallPermissionIntent, completion: @escaping (Bool) -> Void) {
        step(intent.required[...], completion)
    }

    private func step(_ rest: ArraySlice<OLDevicePermission>, _ completion: @escaping (Bool) -> Void) {
        guard let p = rest.first else { return completion(true) }
        switch provider.status(p) {
        case .granted:
            step(rest.dropFirst(), completion)
        case .denied:
            completion(false)
        case .undetermined:
            provider.request(p) { [weak self] granted in
                guard granted, let self else { return completion(false) }
                self.step(rest.dropFirst(), completion)
            }
        }
    }
}
