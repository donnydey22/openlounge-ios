// What the call layer needs from the page shell (ShellViewController implements it).
import Foundation

protocol ShellHost: AnyObject {
    /// https origin of the page on screen.
    var origin: String { get }
    /// The page session's access token, when signed in and not expired.
    var accessToken: String? { get }
    /// window.dispatchEvent(new CustomEvent("openlounge:native-call", {detail})), page controls the call.
    func dispatchNativeCall(_ detail: [String: Any])
    /// window.dispatchEvent(new CustomEvent("openlounge:native-media", {detail})), call media state.
    func emitNativeMedia(_ detail: [String: Any])
    /// Answer a ringing call in the page (in place, or by opening /call/<id>?accept=1).
    func answerInPage(callId: String)
    /// A call needs the app in front of App Lock.
    func unlockForCall()
    /// Read-only peek of the page's existing call-screen presence (`data-presence`), if any.
    func peekCallPresence(_ done: @escaping (String?) -> Void)
    /// Read-only peek of the page call-screen profile photo src (the person's current profile photo).
    func peekCallPhoto(_ done: @escaping (String?) -> Void)
    /// Read-only peek of the page call-screen display name (the person's current profile name, OLCallScreenIdentity).
    func peekCallName(_ done: @escaping (String?) -> Void)
}

extension ShellHost {
    func peekCallPresence(_ done: @escaping (String?) -> Void) { done(nil) }
    func peekCallPhoto(_ done: @escaping (String?) -> Void) { done(nil) }
    func peekCallName(_ done: @escaping (String?) -> Void) { done(nil) }
}
