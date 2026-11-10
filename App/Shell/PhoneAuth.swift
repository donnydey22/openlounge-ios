// Phone sign-in with Firebase (silent APNs verification, reCAPTCHA page only if APNs can't be used).
// The page gets a Firebase ID token and signs in with it; the Firebase user is signed out at once.
import FirebaseAuth
import FirebaseCore
import Foundation

enum PhoneAuth {
    private static var verificationId: String?

    static var available: Bool { FirebaseApp.app() != nil }

    static func start(id: String, phone: String, _ done: @escaping ([String: Any]) -> Void) {
        guard available else { return done(["id": id, "ok": false, "code": "auth/unavailable"]) }
        PhoneAuthProvider.provider().verifyPhoneNumber(phone, uiDelegate: nil) { vid, err in
            if let err { return done(failure(id, err)) }
            verificationId = vid
            done(["id": id, "ok": true, "sent": true])
        }
    }

    static func confirm(id: String, code: String, _ done: @escaping ([String: Any]) -> Void) {
        guard available, let vid = verificationId else {
            return done(["id": id, "ok": false, "code": "auth/missing-verification-id", "error": "Request a new code and try again."])
        }
        let cred = PhoneAuthProvider.provider().credential(withVerificationID: vid, verificationCode: code)
        Auth.auth().signIn(with: cred) { result, err in
            if let err { return done(failure(id, err)) }
            guard let user = result?.user else { return done(["id": id, "ok": false, "code": "auth/no-user"]) }
            user.getIDTokenForcingRefresh(true) { token, err in
                try? Auth.auth().signOut()
                verificationId = nil
                if let err { return done(failure(id, err)) }
                done(["id": id, "ok": true, "idToken": token ?? ""])
            }
        }
    }

    private static func failure(_ id: String, _ e: Error) -> [String: Any] {
        let name = (e as NSError).userInfo[AuthErrorUserInfoNameKey] as? String ?? "ERROR_UNKNOWN"
        // ERROR_INVALID_VERIFICATION_CODE -> auth/invalid-verification-code (the page's codes)
        let code = "auth/" + name.replacingOccurrences(of: "ERROR_", with: "").lowercased().replacingOccurrences(of: "_", with: "-")
        return ["id": id, "ok": false, "code": code]
    }
}
