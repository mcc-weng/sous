import Foundation

/// Pure day-sequencing decisions for `RitualSwipeSessionView`'s B1 swipe ritual —
/// mirrors `WeekBoardLogic.swift`'s free-function style so the day-advance / lock
/// state machine is unit-testable without SwiftUI or `AppModel`. Keyed on plain
/// `[String]` dates + `Set<String>` confirmed-dates rather than `SwipeDeckDay`/
/// `SwipeCandidate` — the decisions never actually look at candidate payloads, only
/// at which dates are confirmed, so the narrower shape keeps the logic (and its
/// tests) free of any model-layer dependency.

/// Index of the first day in `dates` (Monday-first order) that isn't yet confirmed.
/// Falls back to 0 if every day is already confirmed — a state the view should never
/// actually present a deck for (the lock card takes over first), but returning a
/// valid index keeps this a total function rather than one callers must unwrap.
func firstOpenDayIndex(dates: [String], confirmed: Set<String>) -> Int {
    dates.firstIndex(where: { !confirmed.contains($0) }) ?? 0
}

/// The next open (unconfirmed) day strictly after `currentIndex`, or nil if none
/// remain — nil means the caller should stay put (all remaining days, including the
/// current one, are already confirmed).
func nextOpenDayIndex(dates: [String], confirmed: Set<String>, after currentIndex: Int) -> Int? {
    dates.indices.dropFirst(currentIndex + 1).first(where: { !confirmed.contains(dates[$0]) })
}

/// What a swipe should do to the session's day cursor. `.like` confirms the current
/// day (the caller updates `confirmed` before calling this) and moves to the next
/// open day, or stays put if none remain — at which point `isWeekReadyToLock` takes
/// over on the next render. `.pass` and `.modify` never change the day: passing
/// cycles the deck to the next candidate on the same day, and modifying reinserts the
/// revised candidate into the same day's deck later.
func dayIndexAfterSwipe(direction: SwipeDirection, dates: [String],
                        confirmedAfterSwipe: Set<String>, currentIndex: Int) -> Int {
    guard direction == .like else { return currentIndex }
    return nextOpenDayIndex(dates: dates, confirmed: confirmedAfterSwipe, after: currentIndex)
        ?? currentIndex
}

/// True once every day in `dates` is confirmed and the week is a full 7 days — the
/// gate for showing the lock card instead of a card stack. A week that's
/// confirmed-but-short (e.g. mid-week join, dev/test data) is deliberately NOT
/// lock-eligible; the ritual always deals and locks whole weeks.
func isWeekReadyToLock(dayCount: Int, confirmedCount: Int) -> Bool {
    confirmedCount == dayCount && dayCount == 7
}
