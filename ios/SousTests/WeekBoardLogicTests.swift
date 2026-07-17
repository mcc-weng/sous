import XCTest
@testable import Sous

final class WeekBoardLogicTests: XCTestCase {
    private let sydney = TimeZone(identifier: "Australia/Sydney")!

    func testWeekMondayAnchorsThursdayToPriorMonday() {
        // 2026-07-16 is a Thursday
        let thursday = makeDate(2026, 7, 16, timezone: sydney)
        let monday = weekMonday(for: thursday, timezone: sydney)
        XCTAssertEqual(dateString(monday, timezone: sydney), "2026-07-13")
    }

    func testWeekMondayOnMondayIsSameDay() {
        let monday = makeDate(2026, 7, 20, timezone: sydney)
        let result = weekMonday(for: monday, timezone: sydney)
        XCTAssertEqual(dateString(result, timezone: sydney), "2026-07-20")
    }

    func testWeekMondayOnSundayGoesBackSixDays() {
        let sunday = makeDate(2026, 7, 19, timezone: sydney)
        let result = weekMonday(for: sunday, timezone: sydney)
        XCTAssertEqual(dateString(result, timezone: sydney), "2026-07-13")
    }

    func testNextWeekDisplayStateIsStartRitualWhenNoWeek() {
        XCTAssertEqual(nextWeekDisplayState(week: nil, days: []), .startRitual)
    }

    func testNextWeekDisplayStateIsInProgressWhenProposing() {
        let week = PlanWeek(id: UUID(), weekOf: "2026-07-20", status: "proposing", reasoning: nil)
        XCTAssertEqual(nextWeekDisplayState(week: week, days: []), .ritualInProgress)
    }

    func testNextWeekDisplayStateIsDaysWhenLocked() {
        let week = PlanWeek(id: UUID(), weekOf: "2026-07-20", status: "locked", reasoning: "summary")
        let day = PlanDay(id: UUID(), date: "2026-07-20", dish: "三杯雞", mode: "fast",
                          prepNote: nil, reasoning: nil, status: "planned")
        XCTAssertEqual(nextWeekDisplayState(week: week, days: [day]), .days([day]))
    }
}

private func makeDate(_ year: Int, _ month: Int, _ day: Int, timezone: TimeZone) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timezone
    let components = DateComponents(year: year, month: month, day: day, hour: 12)
    return calendar.date(from: components)!
}
