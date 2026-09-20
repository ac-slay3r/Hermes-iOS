import SwiftUI
import UIKit

@MainActor
final class HermesAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // A fresh installation performs no companion work. Previously persisted,
        // explicit push/device-sync consent may resume its matching service.
        Task { @MainActor in
            await AppContainer.sharedDefault().handleSystemLaunch()
        }
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        UserDefaults.standard.set(token, forKey: "hermes.apns.deviceToken")
        Task { @MainActor in
            let container = AppContainer.sharedDefault()
            guard container.isCompanionRuntimeActive else { return }
            await container.registerPushTokenIfNeeded(token)
        }
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
        Task { @MainActor in
            let container = AppContainer.sharedDefault()
            let didWork = await container.handleRemoteNotificationWake()
            completionHandler(didWork ? .newData : .noData)
        }
    }
}

@main
struct HermesMobileApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(HermesAppDelegate.self) private var appDelegate
    @State private var container = AppContainer.sharedDefault()

    var body: some Scene {
        WindowGroup {
            CombinedAppRoot()
                .environment(container)
                .environment(container.router)
                .environment(container.sessionStore)
                .environment(container.pairingStore)
                .environment(container.hostStore)
                .environment(container.chatStore)
                .environment(container.inboxStore)
                .environment(container.permissionsStore)
                .environment(container.settingsStore)
                .environment(container.talkStore)
                .onChange(of: scenePhase) { _, phase in
                    guard container.isCompanionRuntimeActive else { return }
                    if phase == .active {
                        Task { await container.handleAppDidBecomeActive() }
                    } else if phase == .background {
                        Task { await container.reportAppStateIfNeeded("background") }
                    }
                }
        }
    }
}
