import SwiftUI
import UserNotifications

/// E3 · 設定 (settings as colophon) — restyled per design_handoff_sous_m3/README.md
/// "E3 · 設定" and `Sous App v2.dc.html` lines 718-839. That mock has three sections
/// (儀式節奏, 便條通知, 這本書是為誰寫的) plus an imprint. Pass 2a adds the ritual
/// interval and reminder-day controls. 這本書是為誰寫的 (structured preferences display) doesn't exist
/// anywhere in the app today — `AppModel.preferencesContent` is stored freeform text
/// and is never displayed, only used to gate onboarding (`needsOnboarding`) — building
/// the mock's per-field dotted-leader rows would mean parsing that free text back into
/// fields, which is new logic layered on `OnboardingLogic` (frozen for this task), not
/// a restyle. So this view restyles what genuinely exists: the one push-notification
/// control (`便條通知`, as a single printed-square toggle — the app only has one
/// on/off control, not the mock's two independent toggles) and the one preferences
/// action (`重新設定偏好`, restyled under a `偏好設定` label). See task-11-brief.md and
/// task-11-report.md for the full scoping note.
///
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

    private var serifName: String { serifFontName(bundled: FontBook.isSerifBundled) }
    private var sansName: String { sansFontName(bundled: FontBook.isSansBundled) }

    private var status: String {
        if isRequesting { return "處理中…" }
        if let error = model.deviceTokenRegistrationError {
            return "裝置註冊失敗:\(error)"
        }
        if model.deviceTokenRegistered {
            return "已註冊這台裝置"
        }
        return authorizationStatus
    }

    /// The one control this screen actually has — no in-app "off" exists (Apple
    /// requires that round-trip through the Settings app), so the printed toggle is a
    /// state indicator, not a two-way switch: filled = registered, outlined = not.
    private var notificationsOn: Bool { model.deviceTokenRegistered }

    private var bookTitle: String { model.personaCopy["book_title"] ?? "私廚手記" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ritualCadenceSection
                    notificationsSection
                    preferencesSection
                    imprint
                }
            }
            .background(PaperTokens.stock)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("關閉") { dismiss() }
                        .font(.custom(sansName, size: 13))
                        .foregroundStyle(PaperTokens.ink)
                }
            }
        }
    }

    // MARK: 儀式節奏

    private var ritualCadenceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("儀式節奏")
                .padding(.top, Spacing.pageMargin)
            HStack(spacing: 8) {
                cadenceChip("每週", interval: "weekly")
                cadenceChip("每兩週", interval: "biweekly")
            }
            Text("提醒日")
                .font(.custom(sansName, size: 10.5))
                .foregroundStyle(PaperTokens.inkDim)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(Array(["日", "一", "二", "三", "四", "五", "六"].enumerated()), id: \.offset) { index, glyph in
                    anchorDayChip("週\(glyph)", day: index + 1)
                }
            }
            Text(cadenceExplanation)
                .font(.custom(sansName, size: 11).weight(.light))
                .foregroundStyle(PaperTokens.inkDim)
        }
        .padding(.horizontal, Spacing.pageMargin)
        .padding(.bottom, Spacing.lg)
        .overlay(alignment: .bottom) { Rectangle().fill(PaperTokens.rule).frame(height: 1) }
    }

    private func cadenceChip(_ label: String, interval: String) -> some View {
        let selected = model.household?.ritualCadenceInterval == interval
        return Button {
            Task {
                await model.updateRitualCadence(
                    interval: interval,
                    anchorDay: model.household?.ritualCadenceAnchorDay ?? 1
                )
            }
        } label: {
            Text(label)
                .font(.custom(sansName, size: 12))
                .foregroundStyle(selected ? PaperTokens.stock : PaperTokens.ink)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(selected ? model.personaTint : Color.clear)
                .overlay(Rectangle().stroke(selected ? Color.clear : PaperTokens.ruleStrong, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func anchorDayChip(_ label: String, day: Int) -> some View {
        let selected = model.household?.ritualCadenceAnchorDay == day
        return Button {
            Task {
                await model.updateRitualCadence(
                    interval: model.household?.ritualCadenceInterval ?? "weekly",
                    anchorDay: day
                )
            }
        } label: {
            Text(label)
                .font(.custom(sansName, size: 11.5))
                .foregroundStyle(selected ? PaperTokens.stock : PaperTokens.ink)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(selected ? model.personaTint : Color.clear)
                .overlay(Rectangle().stroke(selected ? Color.clear : PaperTokens.rule, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var cadenceExplanation: String {
        let interval = model.household?.ritualCadenceInterval == "biweekly" ? "每兩週" : "每週"
        let index = max(1, min(model.household?.ritualCadenceAnchorDay ?? 1, 7)) - 1
        let glyph = ["日", "一", "二", "三", "四", "五", "六"][index]
        return "\(interval)週\(glyph)提醒你開始排菜儀式。"
    }

    // MARK: 便條通知

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("便條通知")
                .padding(.top, Spacing.lg + 4)
            notificationRow
        }
    }

    private var notificationRow: some View {
        Button {
            Task { await requestAndRegister() }
        } label: {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("推播通知")
                        .font(.custom(serifName, size: 14.5))
                        .foregroundStyle(PaperTokens.ink)
                    Text(status)
                        .font(.custom(sansName, size: 11))
                        .foregroundStyle(model.deviceTokenRegistrationError != nil
                                         ? .red : PaperTokens.inkDim)
                }
                Spacer(minLength: 8)
                paperToggle(isOn: notificationsOn)
            }
            .padding(.vertical, 15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(notificationsOn || isRequesting)
        .opacity(isRequesting ? 0.6 : 1)
        .overlay(alignment: .bottom) { Rectangle().fill(PaperTokens.rule).frame(height: 1) }
        .padding(.horizontal, Spacing.pageMargin)
    }

    /// Printed-square toggle (README E3: "printed square toggles, filled seal = on,
    /// outlined = off") — a switch-shaped rectangle with a knob, matching the mock's
    /// 42×24 track / 18×18 knob proportions.
    private func paperToggle(isOn: Bool) -> some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Rectangle()
                .fill(isOn ? model.personaTint : Color.clear)
                .overlay(Rectangle().stroke(isOn ? Color.clear : PaperTokens.ruleStrong, lineWidth: 1))
            Rectangle()
                .fill(isOn ? PaperTokens.stock : PaperTokens.ruleStrong)
                .frame(width: 18, height: 18)
                .padding(3)
        }
        .frame(width: 42, height: 24)
    }

    // MARK: 偏好設定

    /// The mock's "這本書是為誰寫的" (structured per-field preferences display) doesn't
    /// exist anywhere in the app — see the type-level doc comment. What genuinely
    /// exists is the "redo the interview" action, restyled here under its own label
    /// rather than fabricated field rows.
    private var preferencesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("偏好設定")
                .padding(.top, Spacing.lg + 4)
            Button {
                model.onboardingRestartRequested = true
                dismiss()
            } label: {
                Text("重新設定偏好")
                    .font(.custom(sansName, size: 12.5))
                    .tracking(2.5) // .2em at 12.5pt
                    .foregroundStyle(PaperTokens.ink)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 13)
                    .overlay(Rectangle().stroke(PaperTokens.ruleStrong, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.pageMargin)
        .padding(.bottom, Spacing.lg)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.custom(sansName, size: 10))
            .tracking(4.2) // .42em at 10pt
            .foregroundStyle(model.personaTint)
    }

    // MARK: Imprint

    /// Seal square + `book_title` + versioning line, matching the mock's colophon
    /// footer. No persona display name exists anywhere in the app (only `copy_pack`/
    /// `tint` are fetched — see `AppModel.loadPersonaCopy`), so this omits the mock's
    /// "小當家 ·" prefix rather than hardcoding a persona name (persona discipline);
    /// the seal glyph already carries that identity, same as `AuthView.sealSquare`.
    /// "第 一 版" uses `chineseNumeral` (CounterView.swift) rather than a literal
    /// string, reused not reimplemented.
    private var imprint: some View {
        VStack(spacing: 12) {
            Text("當")
                .font(.custom(serifName, size: 13))
                .foregroundStyle(PaperTokens.stock)
                .frame(width: 28, height: 28)
                .background(model.personaTint)
            Text("\(bookTitle)\n為這個家寫的第 \(chineseNumeral(1)) 版")
                .font(.custom(sansName, size: 10.5))
                .tracking(2.1) // .2em at 10.5pt
                .lineSpacing(10.5) // lh 2
                .multilineTextAlignment(.center)
                .foregroundStyle(PaperTokens.inkDim)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Spacing.lg)
        .padding(.bottom, Spacing.pageMargin)
        .overlay(alignment: .top) { Rectangle().fill(PaperTokens.rule).frame(height: 1) }
        .padding(.horizontal, Spacing.pageMargin)
    }

    private func requestAndRegister() async {
        guard !notificationsOn, !isRequesting else { return }
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
