import SwiftUI

/// E2 · 本週 (week board) — Reference: design_handoff_sous_m3/README.md "E2 · 本週
/// (week board)" and `Sous App v2.dc.html` lines 683-717.
///
/// Container note: this screen moved off `List`/`Section` onto a plain
/// `ScrollView`/`VStack` composition, same call `ShoppingListView` already made and for
/// the same reason — `List`'s default row/section inset chrome fights the paper
/// design's precise "printed table" spacing, and this screen uses no `List`-only
/// feature (no swipe actions, no `.onDelete`) that the move would break. The existing
/// long-press-to-select-then-swap gesture (see `handleLongPress`'s own comment for why
/// it replaced drag-and-drop) is plain `onTapGesture`/`onLongPressGesture`, which is
/// container-agnostic and carries over unchanged.
///
/// Scope note — dual ritual entry: the README shows next week offering both ritual
/// models by name ("ink-filled 滑牌排 and outlined 用寫的"). Pass 1a has no swipe ritual
/// to link a second button to — that's Pass 2, a separate future plan — so this keeps
/// the single existing 開始本週儀式 entry point, restyled to the button language
/// (`PaperTokens.ink` fill, `PaperTokens.stock` text) but pointing at the same
/// `model.startRitual()` written ritual as before.
///
/// Scope note — cooked-day "verdict": the mock's 神作/普通 captions on cooked days are
/// real verdict text (the `verdicts` table, keyed by `plan_day_id`). `PlanDay` itself
/// carries no verdict field, and this task's scope is this file only with no new data
/// loading — fetching per-day verdicts would mean new `AppModel` queries, out of scope
/// for a restyle pass. Cooked/skipped days instead get the one verdict-adjacent value
/// actually on `PlanDay` today: `status`, via the existing `statusLabel` (已煮/skip).
///
/// Scope note — tonight's "開始" button: the mock's slip row for tonight includes a
/// 開始 button. `WeekBoardView` has no existing path into `CookModeView` (that lives on
/// `CounterView`, wired to `model.tonight`/`model.recipes`); adding one here would be
/// new navigation, which the brief's scope guard excludes from a restyle. Per the same
/// principle `RitualWaitingCard`'s doc comment already applies (no buttons promising
/// behavior the app doesn't have), this omits the button — the slip background,
/// seal-tint left border, and "今晚" caption still carry the "this is tonight" signal
/// without it.
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

    private var householdTimezone: TimeZone {
        guard let identifier = model.household?.timezone else { return .current }
        return TimeZone(identifier: identifier) ?? .current
    }

    /// Today's date as "YYYY-MM-DD" in household time — the sole test a day row needs
    /// to render as the page's one "slip" (tonight). Computed fresh per render rather
    /// than cached in `@State`: cheap, and avoids a stale value if the sheet is left
    /// open across midnight.
    private var todayString: String { dateString(Date(), timezone: householdTimezone) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                runningHead("這週")
                VStack(spacing: 0) {
                    ForEach(model.thisWeekDays) { day in dayRow(day) }
                }
                .padding(.top, 14)

                Text("長按兩天可對調")
                    .font(.custom(sansName, size: 10.5))
                    .tracking(1.47) // .14em at 10.5pt
                    .foregroundStyle(PaperTokens.inkFaint)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)

                nextWeekSection
            }
            .padding(.horizontal, Spacing.pageMargin)
            .padding(.top, Spacing.md)
            .padding(.bottom, Spacing.lg)
        }
        .background(PaperTokens.stock)
        .onChange(of: model.nextWeekDays) { _, _ in pendingSwapDates.removeAll(); selectedForSwap = nil }
        .onChange(of: model.thisWeekDays) { _, _ in pendingSwapDates.removeAll(); selectedForSwap = nil }
        .onChange(of: model.nextWeek) { old, new in
            if old?.status == "proposing", new?.status == "locked" {
                justLockedWeekOf = new?.weekOf
            }
        }
        .task { await model.loadWeekBoard() }
    }

    // MARK: Running heads

    /// Section running head — sans, tracked, `inkFaint`, with a hairline rule beneath.
    /// Mirrors the mock's "本週菜單"/"下週" label typography (README E2 top strip).
    private func runningHead(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.custom(sansName, size: 10))
                .tracking(3.4) // .34em at 10pt
                .foregroundStyle(PaperTokens.inkFaint)
            Rectangle()
                .fill(PaperTokens.rule)
                .frame(height: 1)
                .padding(.top, 10)
        }
    }

    private var nextWeekSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(PaperTokens.rule).frame(height: 1)
            Text("下週")
                .font(.custom(sansName, size: 10))
                .tracking(3.4) // .34em at 10pt
                .foregroundStyle(PaperTokens.inkFaint)
                .padding(.top, 20)
            nextWeekContent
                .padding(.top, 4)
        }
        .padding(.top, 26)
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
                startRitualPrompt
            }
        case .ritualInProgress:
            Text("本週儀式進行中 — 到聊天室繼續")
                .font(.custom(sansName, size: 12).weight(.light))
                .foregroundStyle(PaperTokens.inkFaint)
        case .days(let days):
            if justLockedWeekOf != nil, justLockedWeekOf == model.nextWeek?.weekOf {
                lockCelebration
            }
            VStack(spacing: 0) {
                ForEach(days) { day in dayRow(day) }
            }
        }
    }

    /// Single ritual entry point — the "還沒排 —— 現在排嗎?" prompt plus one ink-filled
    /// button, per the scope note above (no second, outlined 用寫的 button).
    private var startRitualPrompt: some View {
        VStack(spacing: 16) {
            Text("還沒排 —— 現在排嗎?")
                .font(.custom(serifName, size: 17))
                .lineSpacing(8.5) // lh 1.7 at 17pt: (1.7 - 1.2) * 17
                .foregroundStyle(PaperTokens.ink)
                .multilineTextAlignment(.center)

            Button {
                pendingRitualStart = true
                ritualWaitStartedAt = Date()
                Task { await model.startRitual() }
            } label: {
                Text("開始本週儀式")
                    .font(.custom(sansName, size: 12))
                    .fontWeight(.medium)
                    .tracking(2.4) // .2em at 12pt
                    .foregroundStyle(PaperTokens.stock)
                    .frame(maxWidth: .infinity)
                    .padding(13)
                    .background(PaperTokens.ink)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
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
        .listRowSeparator(.hidden) // inert outside List; left as Task 7 wrote it.
    }

    // MARK: Day rows

    @ViewBuilder
    private func dayRow(_ day: PlanDay) -> some View {
        if pendingSwapDates.contains(day.date) {
            pendingSwapRow(day)
        } else if day.date == todayString {
            tonightRow(day)
        } else {
            standardRow(day)
        }
    }

    /// A closed (cooked/skipped) or upcoming day — printed-table row: weekday glyph,
    /// dish, a trailing caption chosen by `rowCaption`, dimmed to 55% once the day's
    /// story is closed (README E2: "cooked days fade and keep their verdict").
    private func standardRow(_ day: PlanDay) -> some View {
        let closed = day.status == "cooked" || day.status == "skipped"
        let selected = selectedForSwap == day.date
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(weekdayGlyph(for: day.date))
                    .font(.custom(serifName, size: 15))
                    .foregroundStyle(selected ? model.personaTint : PaperTokens.ink)
                    .frame(width: 18, alignment: .leading)
                Text(day.dish)
                    .font(.custom(serifName, size: 14.5))
                    .foregroundStyle(PaperTokens.ink)
                Spacer(minLength: 8)
                if let caption = rowCaption(day) {
                    Text(caption.text)
                        .font(.custom(sansName, size: 10.5))
                        .tracking(1.05) // .1em at 10.5pt
                        .foregroundStyle(caption.color)
                        .lineLimit(1)
                }
            }
            if expandedDayID == day.id, let reasoning = day.reasoning {
                Text(reasoning)
                    .font(.custom(sansName, size: 11))
                    .foregroundStyle(PaperTokens.inkDim)
                    .padding(.leading, 32) // clears the weekday-glyph column above
            }
        }
        .padding(.vertical, 13)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) { Rectangle().fill(PaperTokens.rule).frame(height: 1) }
        .opacity(closed ? 0.55 : 1)
        .onTapGesture { expandedDayID = expandedDayID == day.id ? nil : day.id }
        .onLongPressGesture { handleLongPress(on: day.date) }
    }

    /// Tonight — the page's one "slip": slip background, seal-tint left border, and a
    /// tint caption. README E2: "tonight is the only slip on the page."
    private func tonightRow(_ day: PlanDay) -> some View {
        let selected = selectedForSwap == day.date
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 14) {
                Text(weekdayGlyph(for: day.date))
                    .font(.custom(serifName, size: 15))
                    .foregroundStyle(model.personaTint)
                    .frame(width: 18, alignment: .leading)
                VStack(alignment: .leading, spacing: 5) {
                    Text(day.dish)
                        .font(.custom(serifName, size: 15.5))
                        .foregroundStyle(PaperTokens.ink)
                    Text(tonightCaption(day))
                        .font(.custom(sansName, size: 10))
                        .tracking(2) // .2em at 10pt
                        .foregroundStyle(model.personaTint)
                }
                Spacer(minLength: 8)
                if selected {
                    Text("已選取")
                        .font(.custom(sansName, size: 10.5))
                        .tracking(1.05) // .1em at 10.5pt
                        .foregroundStyle(model.personaTint)
                }
            }
            if expandedDayID == day.id, let reasoning = day.reasoning {
                Text(reasoning)
                    .font(.custom(sansName, size: 11))
                    .foregroundStyle(PaperTokens.inkDim)
                    .padding(.leading, 32)
            }
        }
        .padding(.vertical, 15)
        .padding(.horizontal, 16)
        .background(PaperTokens.slip)
        .overlay(alignment: .leading) {
            Rectangle().fill(model.personaTint).frame(width: 2)
        }
        .contentShape(Rectangle())
        .onTapGesture { expandedDayID = expandedDayID == day.id ? nil : day.id }
        .onLongPressGesture { handleLongPress(on: day.date) }
    }

    /// "對調中…" — a pending swap, shown with a tint-colored spinner in place of the
    /// dish (README E2 caption: "the pending swap shimmers"). No tap/long-press: a day
    /// mid-swap isn't a valid target for another gesture.
    private func pendingSwapRow(_ day: PlanDay) -> some View {
        HStack(spacing: 14) {
            Text(weekdayGlyph(for: day.date))
                .font(.custom(serifName, size: 15))
                .foregroundStyle(PaperTokens.inkDim)
                .frame(width: 18, alignment: .leading)
            ProgressView()
                .tint(model.personaTint)
                .controlSize(.mini)
            Text("對調中…")
                .font(.custom(sansName, size: 12.5).weight(.light))
                .foregroundStyle(PaperTokens.inkDim)
            Spacer(minLength: 8)
        }
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) { Rectangle().fill(PaperTokens.rule).frame(height: 1) }
    }

    /// Trailing caption for a `standardRow`, in priority order: an in-progress swap
    /// selection (已選取, tint) beats a closed day's status (已煮/skip, `inkDim`) beats
    /// a real prep note, so the most decision-relevant fact always wins the one slot.
    /// No generic `day.mode` chip: the mock never renders the raw mode enum as a
    /// label (`fast`/`batch`/…), and there's no Chinese label for it anywhere else in
    /// the app to borrow — showing it here would be new, ungrounded vocabulary.
    private func rowCaption(_ day: PlanDay) -> (text: String, color: Color)? {
        if selectedForSwap == day.date {
            return ("已選取", model.personaTint)
        }
        if day.status == "cooked" || day.status == "skipped" {
            return (statusLabel(day.status), PaperTokens.inkDim)
        }
        if let prep = day.prepNote, !prep.isEmpty {
            return (prep, PaperTokens.inkDim)
        }
        return nil
    }

    private func tonightCaption(_ day: PlanDay) -> String {
        if let prep = day.prepNote, !prep.isEmpty { return "今晚 · \(prep)" }
        return "今晚"
    }

    private static let weekdayGlyphs = ["日", "一", "二", "三", "四", "五", "六"] // Calendar weekday: Sun=1...Sat=7

    /// Maps a `PlanDay.date` ("YYYY-MM-DD") to its Chinese weekday glyph, in household
    /// time — mirrors `weekMonday`'s Sun=1...Sat=7 convention (WeekBoardLogic.swift) so
    /// Monday always reads 一 regardless of device locale.
    private func weekdayGlyph(for dateStr: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = householdTimezone
        guard let date = formatter.date(from: dateStr) else { return "" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = householdTimezone
        let weekday = calendar.component(.weekday, from: date)
        return Self.weekdayGlyphs[weekday - 1]
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
