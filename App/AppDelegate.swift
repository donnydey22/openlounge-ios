// Open Lounge app entry: Firebase (push, phone sign-in), CallKit / PushKit, and the page shell.
import FirebaseAuth
import FirebaseCore
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var shell: ShellViewController?
    private var pendingURL: String?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        if FirebaseApp.app() == nil, Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil {
            FirebaseApp.configure()
        }
        Push.shared.install()
        CallCenter.shared.start()

        let shell = ShellViewController()
        self.shell = shell
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.rootViewController = shell
        w.makeKeyAndVisible()
        window = w
        if let u = launchOptions?[.url] as? URL { open(u) }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        if FirebaseApp.app() != nil { Auth.auth().setAPNSToken(deviceToken, type: .unknown) }
        Push.shared.didRegister(apnsToken: deviceToken)
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        if FirebaseApp.app() != nil, Auth.auth().canHandleNotification(userInfo) { return completionHandler(.noData) }
        Push.shared.didReceive(userInfo)
        completionHandler(.newData)
    }

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        if FirebaseApp.app() != nil, Auth.auth().canHandle(url) { return true }
        open(url)
        return true
    }

    func application(_ application: UIApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb, let u = userActivity.webpageURL else { return false }
        open(u)
        return true
    }

    private func open(_ url: URL) {
        DispatchQueue.main.async { [weak self] in self?.shell?.handleIncomingURL(url.absoluteString) }
    }
}
