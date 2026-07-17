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
