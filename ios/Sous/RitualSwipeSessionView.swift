import SwiftUI

/// B1 · 滑牌儀式 — a full-week deck generated once, then resolved locally one day
/// at a time. Passing stays on the same day; liking advances to the next day.
struct RitualSwipeSessionView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var days: [AppModel.SwipeDeckDay] = []
    @State private var dayIndex = 0
    @State private var deck = SwipeDeckState(candidates: [], pendingReinserts: [])
    @State private var confirmed: [String: SwipeCandidate] = [:]
    @State private var phase: Phase = .loading
    @State private var waitingStartedAt = Date()

    private enum Phase { case loading, dealing, locking, failed }
    private var serifName: String { serifFontName(bundled: FontBook.isSerifBundled) }
    private var sansName: String { sansFontName(bundled: FontBook.isSansBundled) }
    private var timezone: TimeZone {
        model.household.flatMap { TimeZone(identifier: $0.timezone) } ?? .current
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            switch phase {
            case .loading:
                waitingView
            case .failed:
                failureView
            case .locking:
                lockCard(showProgress: true)
            case .dealing:
                if isWeekReadyToLock(dayCount: days.count, confirmedCount: confirmed.count) {
                    lockCard(showProgress: false)
                } else if let day = days[safe: dayIndex] {
                    if deck.candidates.isEmpty {
                        exhaustedView(for: day)
                    } else {
                        SwipeCardStack(
                            candidates: deck.candidates,
                            dayLabel: "週　\(weekdayGlyph(for: day.date, timezone: timezone))",
                            progressFilled: confirmed.count,
                            progressTotal: days.count,
                            onSwipe: { handleSwipe($0, $1, day: day) },
                            onModifyNote: { handleModify($0, note: $1, day: day) }
                        )
                    }
                } else {
                    failureView
                }
            }
        }
        .background(PaperTokens.stock.ignoresSafeArea())
        .interactiveDismissDisabled(phase == .locking)
        .accessibilityAction(.escape) { if phase != .locking { dismiss() } }
        .task { await loadDeck() }
    }

    private var header: some View {
        HStack {
            Text("滑牌儀式").font(.custom(serifName, size: 17))
            Spacer()
            Button("關閉") { dismiss() }
                .font(.custom(sansName, size: 13))
                .frame(minWidth: 44, minHeight: 44)
                .disabled(phase == .locking)
        }
        .foregroundStyle(PaperTokens.ink)
        .padding(.horizontal, Spacing.pageMargin)
        .padding(.top, Spacing.sm)
    }

    private var waitingView: some View {
        VStack {
            Spacer()
            RitualWaitingCard(
                stages: model.thinkingStages,
                leaveOkText: model.personaCopy["wait_leave_ok"] ?? "你可以先去忙 —— 排好我會放進便條通知你。",
                tint: model.personaTint,
                startedAt: waitingStartedAt
            )
            .padding(.horizontal, Spacing.pageMargin)
            Spacer()
        }
    }

    private var failureView: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("這副牌沒發好")
                .font(.custom(serifName, size: 20))
                .foregroundStyle(PaperTokens.ink)
            Text("再試一次,或先回本週頁面。")
                .font(.custom(sansName, size: 12))
                .foregroundStyle(PaperTokens.inkDim)
            Button("重新發牌") { Task { await loadDeck() } }
                .font(.custom(sansName, size: 13).weight(.medium))
                .foregroundStyle(PaperTokens.stock)
                .frame(minWidth: 160, minHeight: 50)
                .background(PaperTokens.ink)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func exhaustedView(for day: AppModel.SwipeDeckDay) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Text("週\(weekdayGlyph(for: day.date, timezone: timezone))的牌看完了")
                .font(.custom(serifName, size: 20))
                .foregroundStyle(PaperTokens.ink)
            Text("重新發一副牌,已排好的日子會保留。")
                .font(.custom(sansName, size: 12))
                .foregroundStyle(PaperTokens.inkDim)
            Button("重新發牌") { Task { await reloadOpenDay() } }
                .font(.custom(sansName, size: 13).weight(.medium))
                .foregroundStyle(PaperTokens.stock)
                .frame(minWidth: 160, minHeight: 50)
                .background(PaperTokens.ink)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func lockCard(showProgress: Bool) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Text("七天都排好了")
                .font(.custom(sansName, size: 10)).tracking(2)
                .foregroundStyle(model.personaTint)
            Text("這一週 / 交給我")
                .font(.custom(serifName, size: 24))
                .multilineTextAlignment(.center)
                .foregroundStyle(PaperTokens.ink)
            if showProgress {
                ProgressView().tint(model.personaTint)
            } else {
                Button("鎖　定") { Task { await lockWeek() } }
                    .font(.custom(sansName, size: 13).weight(.medium))
                    .foregroundStyle(PaperTokens.stock)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(PaperTokens.ink)
                    .padding(.horizontal, Spacing.pageMargin)
            }
            Spacer()
        }
    }

    private func loadDeck() async {
        waitingStartedAt = Date()
        phase = .loading
        guard let jobId = await model.startSwipeRitual(),
              let result = await model.pollRitualDeck(jobId: jobId) else {
            phase = .failed
            return
        }
        days = result
        dayIndex = firstOpenDayIndex(dates: result.map(\.date), confirmed: Set(confirmed.keys))
        deck = SwipeDeckState(candidates: result[dayIndex].candidates, pendingReinserts: [])
        phase = .dealing
    }

    private func reloadOpenDay() async {
        waitingStartedAt = Date()
        phase = .loading
        guard let jobId = await model.startSwipeRitual(),
              let replacement = await model.pollRitualDeck(jobId: jobId),
              let currentDate = days[safe: dayIndex]?.date,
              let replacementDay = replacement.first(where: { $0.date == currentDate }) else {
            phase = .failed
            return
        }
        deck = SwipeDeckState(candidates: replacementDay.candidates, pendingReinserts: [])
        phase = .dealing
    }

    private func handleSwipe(_ candidate: SwipeCandidate, _ direction: SwipeDirection,
                             day: AppModel.SwipeDeckDay) {
        guard direction != .modify else { return }
        deck.advance()
        Task {
            await model.recordSwipe(recipeId: candidate.recipeId, dishText: candidate.dishText,
                                    action: direction == .like ? "like" : "pass",
                                    context: "ritual", note: nil)
        }
        if direction == .like {
            confirmed[day.date] = candidate
        }
        let nextIndex = dayIndexAfterSwipe(direction: direction, dates: days.map(\.date),
                                           confirmedAfterSwipe: Set(confirmed.keys), currentIndex: dayIndex)
        if nextIndex != dayIndex {
            dayIndex = nextIndex
            deck = SwipeDeckState(candidates: days[nextIndex].candidates, pendingReinserts: [])
        }
    }

    private func handleModify(_ candidate: SwipeCandidate, note: String,
                              day: AppModel.SwipeDeckDay) {
        deck.advance()
        Task {
            await model.recordSwipe(recipeId: candidate.recipeId, dishText: candidate.dishText,
                                    action: "modify", context: "ritual", note: note)
            guard let revised = await model.requestRecipeTweak(
                originRecipeId: candidate.recipeId, originDishText: candidate.dishText,
                note: note, context: "ritual", date: day.date
            ), days[safe: dayIndex]?.date == day.date else { return }
            reinsert(revised)
        }
    }

    private func reinsert(_ candidate: SwipeCandidate) {
        if deck.candidates.isEmpty {
            var tagged = candidate
            tagged.isUpdated = true
            deck.candidates.append(tagged)
        } else {
            deck.scheduleReinsert(candidate, afterCards: min(3, deck.candidates.count))
        }
    }

    private func lockWeek() async {
        phase = .locking
        let payload = days.compactMap { day -> AppModel.SwipeLockDayPayload? in
            guard let chosen = confirmed[day.date] else { return nil }
            return .init(date: day.date, dish: chosen.dishText,
                         mode: chosen.mode ?? "fast", prep_note: chosen.prepNote)
        }
        let shopping = days.compactMap { confirmed[$0.date] }.flatMap(\.shoppingItems)
        if await model.submitSwipeLock(days: payload, shoppingItems: shopping) {
            dismiss()
        } else {
            phase = .dealing
        }
    }
}
