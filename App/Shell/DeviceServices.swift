// Device features the page asks for through the bridge: haptics, App Lock, contacts.
import Contacts
import Foundation
import LocalAuthentication
import OLShellCore
import UIKit

enum Haptics {
    private static var lastAt = Date.distantPast

    static func play(_ k: OLHaptic) {
        guard Date().timeIntervalSince(lastAt) >= 0.06 else { return }
        lastAt = Date()
        switch k {
        case .raiseHand, .light: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .medium: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .heavy: UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        case .sendDm, .soft: UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        case .rigid: UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        case .selection: UISelectionFeedbackGenerator().selectionChanged()
        case .joinStage, .success: UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning: UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .error: UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}

/// Opt-in App Lock: Face ID / Touch ID with the passcode allowed.
enum AppLock {
    enum Result { case success, cancelled, failed, unavailable }
    private static let key = "openlounge.biometricLock"

    static var isAvailable: Bool {
        var e: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &e)
    }

    static var enabled: Bool { KeychainStore.prefs.get(key) == "1" && isAvailable }

    static func setFlag(_ on: Bool) {
        if on { KeychainStore.prefs.set(key, "1") } else { KeychainStore.prefs.delete(key) }
    }

    static func authenticate(_ reason: String, _ done: @escaping (Result) -> Void) {
        guard isAvailable else { return done(.unavailable) }
        let c = LAContext()
        c.localizedCancelTitle = "Cancel"
        c.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, err in
            let r: Result
            if ok { r = .success } else {
                switch (err as? LAError)?.code {
                case .userCancel?, .systemCancel?, .appCancel?: r = .cancelled
                case .biometryNotEnrolled?, .biometryNotAvailable?, .passcodeNotSet?: r = .unavailable
                default: r = .failed
                }
            }
            DispatchQueue.main.async { done(r) }
        }
    }

    /// Turning it on needs one successful unlock first.
    static func setEnabled(_ on: Bool, _ done: @escaping (Bool) -> Void) {
        guard on else { setFlag(false); return done(false) }
        authenticate("Turn on app lock") { r in
            if r == .success { setFlag(true) }
            done(enabled)
        }
    }
}

/// Phone numbers from the address book for "friends already here" (the page hashes them).
enum ContactsReader {
    static func read(_ done: @escaping (String) -> Void) {
        let store = CNContactStore()
        store.requestAccess(for: .contacts) { granted, _ in
            guard granted else { return done(#"{"granted":false}"#) }
            DispatchQueue.global(qos: .userInitiated).async {
                var list: [[String: Any]] = []
                let req = CNContactFetchRequest(keysToFetch: [CNContactPhoneNumbersKey as CNKeyDescriptor,
                                                              CNContactFormatter.descriptorForRequiredKeys(for: .fullName)])
                try? store.enumerateContacts(with: req) { c, stop in
                    let nums = c.phoneNumbers.map { $0.value.stringValue }.filter { !$0.isEmpty }
                    if !nums.isEmpty { list.append(["name": CNContactFormatter.string(from: c, style: .fullName) ?? "", "numbers": nums]) }
                    if list.count >= 50_000 { stop.pointee = true }
                }
                var limited = false
                if #available(iOS 18.0, *) { limited = CNContactStore.authorizationStatus(for: .contacts) == .limited }
                let country = (Locale.current.regionCode ?? "US").uppercased()
                let out: [String: Any] = ["granted": true, "country": country, "contacts": list, "accessPrivileges": limited ? "limited" : "all"]
                let json = (try? JSONSerialization.data(withJSONObject: out)).flatMap { String(data: $0, encoding: .utf8) } ?? #"{"granted":false}"#
                done(json)
            }
        }
    }
}
