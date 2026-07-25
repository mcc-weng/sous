import SwiftUI
import UserNotifications

/// Stands in for the real onboarding permission flow (M3's later Onboarding phase)
/// until that lands — same shape either way: request authorization, register for
/// remote notifications, upsert device_tokens on success.
struct NotificationsSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var status: String = "尚未開啟"
    @State private var isRequesting = false

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
        .onReceive(NotificationCenter.default.publisher(for: .sousDidRegisterDeviceToken)) { note in
            guard let tokenHex = note.userInfo?["tokenHex"] as? String else { return }
            Task { await upsertDeviceToken(tokenHex: tokenHex) }
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
                status = "已開啟,正在註冊裝置…"
            } else {
                status = "已拒絕通知權限"
            }
        } catch {
            status = "發生錯誤:\(error.localizedDescription)"
        }
    }

    private func upsertDeviceToken(tokenHex: String) async {
        guard let userId = model.session?.user.id else { return }
        let upsert = makeDeviceTokenUpsert(userId: userId, tokenHex: tokenHex)
        do {
            try await model.client.from("device_tokens").upsert(upsert).execute()
            status = "已註冊這台裝置"
        } catch {
            status = "裝置註冊失敗:\(error.localizedDescription)"
        }
    }
}
