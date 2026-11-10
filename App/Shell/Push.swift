// Notifications: Firebase Cloud Messaging token for the page (the server sends message and room
// notifications through FCM), foreground presentation, taps, badge, and "clear" data messages.
// Push starts only after the first page load, never at launch, and only asks the user when the
// page calls requestNotificationPermission (after sign-in).
import FirebaseCore
import FirebaseMessaging
import Foundation
import OLShellCore
import UIKit
import UserNotifications

final class Push: NSObject, UNUserNotificationCenterDelegate, MessagingDelegate {
    static let shared = Push()

    /// Main queue.
    var onToken: ((String) -> Void)?
    var onForeground: (([String: String]) -> Void)?
    var onOpenPath: ((String) -> Void)?
    var onCallCancel: ((String) -> Void)?

    private(set) var started = false
    private var pendingOpenPath: String?

    static var firebaseConfigured: Bool { FirebaseApp.app() != nil }

    /// Called from application(_:didFinishLaunchingWithOptions:) so taps that launched the app are seen.
    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// After the first page load: wire FCM; asks for nothing.
    func start() {
        guard !started, Self.firebaseConfigured else { return }
        started = true
        Messaging.messaging().delegate = self
        UNUserNotificationCenter.current().getNotificationSettings { s in
            guard s.authorizationStatus == .authorized || s.authorizationStatus == .provisional else { return }
            DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
        }
        if let p = pendingOpenPath { pendingOpenPath = nil; onOpenPath?(p) }
    }

    /// The page's requestNotificationPermission(): one system prompt, then the token.
    func requestPermission() {
        start()
        guard Self.firebaseConfigured else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { ok, _ in
            guard ok else { return }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
                Messaging.messaging().token { t, _ in if let t, !t.isEmpty { DispatchQueue.main.async { self.onToken?(t) } } }
            }
        }
    }

    func setBadge(_ n: Int) {
        if #available(iOS 16.0, *) { UNUserNotificationCenter.current().setBadgeCount(n) }
    }

    func didRegister(apnsToken: Data) {
        guard Self.firebaseConfigured else { return }
        Messaging.messaging().apnsToken = apnsToken
    }

    /// Data messages delivered to application(_:didReceiveRemoteNotification:fetchCompletionHandler:).
    func didReceive(_ info: [AnyHashable: Any]) {
        let d = OLForegroundPush.data(info)
        if d["clear"] == "1", let tag = d["tag"] { clearDelivered(tag: tag) }
        if d["type"] == "call_cancel", let id = d["callId"] { DispatchQueue.main.async { self.onCallCancel?(id) } }
    }

    func clearDelivered(tag: String) {
        let c = UNUserNotificationCenter.current()
        c.getDeliveredNotifications { list in
            let ids = list.filter { ($0.request.content.userInfo["tag"] as? String) == tag }.map(\.request.identifier)
            c.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    // MARK: MessagingDelegate

    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let t = fcmToken, !t.isEmpty else { return }
        DispatchQueue.main.async { self.onToken?(t) }
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        let d = OLForegroundPush.data(n.request.content.userInfo)
        didReceive(n.request.content.userInfo)
        if OLForegroundPush.shouldForward(d) { DispatchQueue.main.async { self.onForeground?(d) } }
        done([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive r: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        if let p = OLForegroundPush.openPath(r.notification.request.content.userInfo) {
            DispatchQueue.main.async {
                if self.onOpenPath != nil && self.started { self.onOpenPath?(p) } else { self.pendingOpenPath = p }
            }
        }
        done()
    }
}
