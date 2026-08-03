import Foundation

/// Anchors `date` to the Monday 00:00 of the week containing it, in `timezone`.
/// Mirrors the worker's `week_monday()` (sous_worker/context.py) so the client and
/// server agree on week boundaries — the M1 timezone bug was exactly this kind of
/// client/server date-math mismatch, fixed server-side; this keeps the client correct too.
func weekMonday(for date: Date, timezone: TimeZone) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timezone
    let weekday = calendar.component(.weekday, from: date)  // Sun=1...Sat=7
    let daysFromMonday = (weekday + 5) % 7
    let startOfDay = calendar.startOfDay(for: date)
    return calendar.date(byAdding: .day, value: -daysFromMonday, to: startOfDay)!
}

/// Formats `date` as "yyyy-MM-dd" in `timezone`, matching the postgres `date` columns'
/// string representation used throughout the app (PlanDay.date, PlanWeek.weekOf).
func dateString(_ date: Date, timezone: TimeZone) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = timezone
    return formatter.string(from: date)
}

enum NextWeekDisplayState: Equatable {
    case startRitual
    case ritualInProgress
    case days([PlanDay])
}

/// Given next week's `plan_weeks` row (or nil if none exists) and its `plan_days`,
/// derives which of the 3 Week-board states to show. No row → offer to start the
/// ritual; `status == "proposing"` → ritual bootstrapped, conversation continues in
/// chat; `status == "locked"` → show the real days.
func nextWeekDisplayState(week: PlanWeek?, days: [PlanDay]) -> NextWeekDisplayState {
    guard let week else { return .startRitual }
    switch week.status {
    case "proposing":
        return .ritualInProgress
    case "locked":
        return .days(days)
    default:
        return .startRitual
    }
}

/// Which stage index to display `elapsed` seconds into a wait, given `stageCount`
/// stages that rotate every `interval` seconds (README B2: ~2.6s, `thinking_stages`
/// copy_pack key). Clamps to the last index once elapsed exceeds the full rotation — a
/// turn that runs long holds on the final stage word instead of wrapping back to the
/// first, which would look like the chef restarted from scratch. Real cloud ritual
/// turns take 100-150s, so this is expected to clamp on every normal-length wait, not
/// just an edge case. Shared by the ritual-bootstrap wait (WeekBoardView) and the
/// in-chat wait (ChatView) — the same cloud round trip either way.
func thinkingStageIndex(elapsed: TimeInterval, stageCount: Int, interval: TimeInterval = 2.6) -> Int {
    guard stageCount > 0, elapsed > 0, interval > 0 else { return 0 }
    let index = Int(elapsed / interval)
    return min(index, stageCount - 1)
}
