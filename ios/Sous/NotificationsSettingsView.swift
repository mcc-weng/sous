import SwiftUI
import UserNotifications

/// Stands in for the real onboarding permission flow (M3's later Onboarding phase)
/// until that lands — same shape either way: request authorization, register for
/// remote notifications, upsert device_tokens on success.
struct NotificationsSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    // Tracks only the pre-registration steps that are inherently tied to this view's
    // own button tap (requesting authorization). What happens after that — the actual
    // device_tokens upsert, and whether it succeeded or failed — lives on AppModel,
    // since that callback can land after this sheet is gone (see AppModel.init()).
    @State private var authorizationStatus: String = "尚未開啟"
    @State private var isRequesting = false

    private var status: String {
        if let error = model.deviceTokenRegistrationError {
            return "裝置註冊失敗:\(error)"
        }
        if model.deviceTokenRegistered {
            return "已註冊這台裝置"
        }
        return authorizationStatus
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("推播通知").font(.title2.bold())
                Text(status).foregroundStyle(.secondary)
                Button(isRequesting ? "處理中…" : "開啟通知") {
                    Task { await requestAndRegister() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRequesting)
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("關閉") { dismiss() }
                }
            }
        }
    }

    private func requestAndRegister() async {
        isRequesting = true
        defer { isRequesting = false }
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            if granted {
                await UIApplication.shared.registerForRemoteNotifications()
                authorizationStatus = "已開啟,正在註冊裝置…"
            } else {
                authorizationStatus = "已拒絕通知權限"
            }
        } catch {
            authorizationStatus = "發生錯誤:\(error.localizedDescription)"
        }
    }
}
