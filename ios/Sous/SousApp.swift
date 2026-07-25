import SwiftUI
import UIKit

final class SousAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NotificationCenter.default.post(name: .sousDidRegisterDeviceToken, object: nil,
                                         userInfo: ["tokenHex": hexString(deviceToken)])
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("APNs registration failed: \(error)")
    }
}

extension Notification.Name {
    static let sousDidRegisterDeviceToken = Notification.Name("sousDidRegisterDeviceToken")
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
