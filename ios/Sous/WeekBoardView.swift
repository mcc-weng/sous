import SwiftUI

struct WeekBoardView: View {
    @EnvironmentObject private var model: AppModel
    @State private var expandedDayID: UUID?
    // No auto-clear on failure — matches the plan's "no client-side timeout" constraint.
    // Recovery is dismiss/reopen (resets @State) or the cancel-ritual escape hatch via chat.
    @State private var pendingRitualStart = false
    /// When the current ritual-bootstrap wait began — drives `RitualWaitingCard`'s
    /// stage rotation (B2). Set the instant the "開始本週儀式" button is tapped.
    @State private var ritualWaitStartedAt = Date()
    @State private var pendingSwapDates: Set<String> = []
    // Long-press-to-select-then-swap: a real-device exit check found List row-to-row
    // drag-and-drop unreliable with both onDrag/onDrop and draggable/dropDestination
    // (drop target never registered a hover or drop, with or without a competing tap
    // gesture) — this achieves the same swap outcome with plain, reliable gestures.
    @State private var selectedForSwap: String?
    /// Set when this view observes `model.nextWeek` transition proposing → locked
    /// (see the `.onChange` below) — drives the B3 lock celebration shown once at the
    /// top of the `.days` case. Deliberately session-scoped, not derived from
    /// `model.nextWeek.status` alone: a week that was *already* locked before this
    /// view loaded (e.g. app reopened after the ritual finished elsewhere) should not
    /// re-show the "just locked" moment — only an in-session transition should.
    @State private var justLockedWeekOf: String?

    private var serifName: String { serifFontName(bundled: FontBook.isSerifBundled) }
    private var sansName: String { sansFontName(bundled: FontBook.isSansBundled) }

    var body: some View {
        List {
            Section("這週") {
                ForEach(model.thisWeekDays) { day in
                    dayRow(day)
                }
            }
            Section("下週") {
                nextWeekContent
            }
        }
        .listStyle(.plain)
        .onChange(of: model.nextWeekDays) { _, _ in pendingSwapDates.removeAll(); selectedForSwap = nil }
        .onChange(of: model.thisWeekDays) { _, _ in pendingSwapDates.removeAll(); selectedForSwap = nil }
        .onChange(of: model.nextWeek) { old, new in
            if old?.status == "proposing", new?.status == "locked" {
                justLockedWeekOf = new?.weekOf
            }
        }
        .task { await model.loadWeekBoard() }
    }

    @ViewBuilder
    private var nextWeekContent: some View {
        switch nextWeekDisplayState(week: model.nextWeek, days: model.nextWeekDays) {
        case .startRitual:
            if pendingRitualStart {
                RitualWaitingCard(
                    stages: model.thinkingStages,
                    leaveOkText: model.personaCopy["wait_leave_ok"] ?? "你可以先去忙 —— 排好我會放進便條通知你。",
                    tint: model.personaTint,
                    startedAt: ritualWaitStartedAt
                )
            } else {
                Button("開始本週儀式") {
                    pendingRitualStart = true
                    ritualWaitStartedAt = Date()
                    Task { await model.startRitual() }
                }
            }
        case .ritualInProgress:
            Text("本週儀式進行中 — 到聊天室繼續")
                .font(.custom(sansName, size: 12).weight(.light))
                .foregroundStyle(PaperTokens.inkFaint)
        case .days(let days):
            if justLockedWeekOf != nil, justLockedWeekOf == model.nextWeek?.weekOf {
                lockCelebration
            }
            ForEach(days) { day in dayRow(day) }
        }
    }

    /// B3 · 鎖定 (lock) — Reference: design_handoff_sous_m3/README.md "B3 · 鎖定 (lock)"
    /// and `Sous App v2.dc.html` lines 282-321.
    ///
    /// The mock is a dedicated full-screen celebration: a printed table-of-contents of
    /// the week's days, a quote, and "看採買清單"/"回廚房" navigation buttons. No such
    /// screen (or anything resembling it — no dedicated view, no special chat-message
    /// rendering) exists anywhere in the app today; the actual current "lock" moment is
    /// this silent `.ritualInProgress` → `.days` state transition, with zero
    /// acknowledgement that the week just finished being planned. Building the mock's
    /// full page would mean new screen architecture (day-by-day layout distinct from
    /// `dayRow`, shopping-list navigation) — out of this restyle-scoped task per the
    /// brief. This instead gives the actual transition the one missing beat: the
    /// `lock_hero`/`lock_signoff` copy and paper styling, applied to a banner at the
    /// top of the days list rather than a new screen.
    ///
    /// Known limitation: this only fires if `WeekBoardView` is alive to observe the
    /// `model.nextWeek` transition (see `justLockedWeekOf`'s `.onChange` above) — if
    /// the lock lands while the user is in `ChatView` and this tab was never
    /// instantiated this session, the celebration is missed. Acceptable for a restyle
    /// pass; a real fix would need app-level state, which is out of scope here.
    private var lockCelebration: some View {
        VStack(spacing: 10) {
            Text("已　鎖　定")
                .font(.custom(sansName, size: 10))
                .tracking(5) // .5em at 10pt
                .foregroundStyle(model.personaTint)
            Text(model.personaCopy["lock_hero"] ?? "這一週,我來安排")
                .font(.custom(serifName, size: 19))
                .foregroundStyle(PaperTokens.ink)
                .multilineTextAlignment(.center)
            Text("「\(model.personaCopy["lock_signoff"] ?? "放心去過你的一週")」")
                .font(.custom(serifName, size: 14).italic())
                .foregroundStyle(PaperTokens.inkDim)
                .multilineTextAlignment(.center)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private func dayRow(_ day: PlanDay) -> some View {
        if pendingSwapDates.contains(day.date) {
            pendingRow(text: "對調中…")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(day.dish)
                    Text(day.mode).font(.caption).foregroundStyle(.secondary)
                    if day.status != "planned" {
                        Text(statusLabel(day.status)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if selectedForSwap == day.date {
                        Image(systemName: "arrow.left.arrow.right.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                    if let prep = day.prepNote {
                        Text(prep).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if expandedDayID == day.id, let reasoning = day.reasoning {
                    Text(reasoning).font(.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .listRowBackground(selectedForSwap == day.date ? Color.accentColor.opacity(0.15) : nil)
            .onTapGesture {
                expandedDayID = expandedDayID == day.id ? nil : day.id
            }
            .onLongPressGesture {
                handleLongPress(on: day.date)
            }
        }
    }

    private func handleLongPress(on date: String) {
        guard let selected = selectedForSwap else {
            selectedForSwap = date
            return
        }
        if selected == date {
            selectedForSwap = nil // long-press the same day again to cancel
            return
        }
        pendingSwapDates.insert(selected)
        pendingSwapDates.insert(date)
        selectedForSwap = nil
        Task { await model.requestSwap(dateA: selected, dateB: date) }
    }

    private func pendingRow(text: String) -> some View {
        HStack {
            ProgressView()
            Text(text).foregroundStyle(.secondary)
        }
    }

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "cooked": return "已煮"
        case "skipped": return "skip"
        default: return status
        }
    }
}

/// B2 · 對話版 · 等待 (written-ritual waiting state) — Reference: design_handoff_sous_m3/
/// README.md "B2 · 對話版 (written ritual — ships today)" and `Sous App v2.dc.html`
/// lines 237-281.
///
/// Shared between `WeekBoardView` (the ritual-bootstrap wait, before the first chef
/// reply appears in chat) and `ChatView` (every wait during a brain turn — the design
/// doesn't distinguish "ritual wait" from "ordinary chat wait", both are the same
/// cloud round trip). Not a bare spinner: real ritual turns take 100-150s, and a
/// screen that looks frozen that long reads as broken, so this narrates progress via
/// `thinking_stages` and is honest about the wait via `wait_leave_ok`.
///
/// The mock's "先離開,好了通知我" button is intentionally omitted, not wired to a
/// no-op — same reasoning `ChatView`'s file-header comment gives for skipping the
/// mock's `關閉` affordance: the app has no notify-on-completion mechanism distinct
/// from simply leaving the screen (backgrounding/navigating away already works), so a
/// button promising specific behavior that doesn't exist would misrepresent the app.
struct RitualWaitingCard: View {
    /// `thinking_stages` copy_pack key, already decoded to `[String]` by
    /// `PersonaCopyRow` (Models.swift) — the one copy_pack value that's a JSON array
    /// rather than a string.
    let stages: [String]
    /// `wait_leave_ok` copy_pack key.
    let leaveOkText: String
    let tint: Color
    /// When this particular wait began. The stage shown is derived from elapsed time
    /// since this instant (via `TimelineView`), not a manually-ticked counter, so
    /// rotation survives view re-renders with no extra timer plumbing.
    let startedAt: Date

    private var serifName: String { serifFontName(bundled: FontBook.isSerifBundled) }
    private var sansName: String { sansFontName(bundled: FontBook.isSansBundled) }

    /// Neutral, non-persona placeholder for the brief window before `thinking_stages`
    /// has loaded — never a hardcoded persona phrase (that's what `AppModel.
    /// thinkingStages`'s empty default exists to avoid).
    private var safeStages: [String] { stages.isEmpty ? ["…"] : stages }

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let elapsed = context.date.timeIntervalSince(startedAt)
            let stageIndex = thinkingStageIndex(elapsed: elapsed, stageCount: safeStages.count)
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 11) {
                    ProgressView()
                        .tint(tint)
                        .controlSize(.mini)
                    Text(safeStages[stageIndex])
                        .font(.custom(serifName, size: 16))
                        .foregroundStyle(PaperTokens.ink)
                        .animation(.default, value: stageIndex)
                }
                HStack(spacing: 6) {
                    ForEach(0..<safeStages.count, id: \.self) { index in
                        Rectangle()
                            .fill(index <= stageIndex ? tint : PaperTokens.rule)
                            .frame(height: 1)
                    }
                }
                .animation(.default, value: stageIndex)
                Text(leaveOkText)
                    .font(.custom(sansName, size: 11.5).weight(.light))
                    .lineSpacing(8.63) // lh 1.95 at 11.5pt: (1.95 - 1.2) * 11.5
                    .foregroundStyle(PaperTokens.inkDim)
            }
            .padding(18)
            .overlay(Rectangle().stroke(PaperTokens.ink.opacity(0.26), lineWidth: 1))
        }
    }
}
