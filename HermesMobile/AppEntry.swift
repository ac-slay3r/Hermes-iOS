import SwiftUI
import UIKit

@MainActor
final class HermesAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Also revoke an earlier installation's registration. Never construct
        // AppContainer, sensors, a relay client, or a notification service here.
        application.unregisterForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        // Late callbacks from an older registration are intentionally ignored.
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {}

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        // Always finish immediately, including cold/background launch.
        completionHandler(.noData)
    }
}

@main
struct HermesMobileApp: App {
    @UIApplicationDelegateAdaptor(HermesAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            AdminRoot()
                // Legacy Hermes links cannot initialize or navigate into remote features.
                .onOpenURL { _ in }
        }
    }
}
