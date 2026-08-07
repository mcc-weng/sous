import SwiftUI
import UIKit
import UserNotifications

final class SousAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NotificationCenter.default.post(name: .sousDidRegisterDeviceToken, object: nil,
                                         userInfo: ["tokenHex": hexString(deviceToken)])
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NotificationCenter.default.post(name: .sousDidFailToRegisterDeviceToken, object: nil,
                                         userInfo: ["message": error.localizedDescription])
    }

    /// Cook-mode timers rely on this to satisfy "timers fire a haptic and a sound" even
    /// while the app is in the foreground — without it, a foreground local notification
    /// is silently suppressed. Push notifications (the other user of this delegate)
    /// don't fire while foreground in this app's flows, so this doesn't change their
    /// behaviour.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // Haptics are main-thread UIKit calls; this delegate callback isn't guaranteed
        // to run on main, so hop explicitly rather than assume.
        await MainActor.run {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        return [.banner, .sound]
    }
}

extension Notification.Name {
    static let sousDidRegisterDeviceToken = Notification.Name("sousDidRegisterDeviceToken")
    static let sousDidFailToRegisterDeviceToken = Notification.Name("sousDidFailToRegisterDeviceToken")
}

@main
struct SousApp: App {
    @UIApplicationDelegateAdaptor(SousAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            Group {
                if model.session == nil {
                    AuthView()
                } else {
                    CounterView()
                }
            }
            .environmentObject(model)
            .task { await model.restoreSession() }
        }
    }
}
