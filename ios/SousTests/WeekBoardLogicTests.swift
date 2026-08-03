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

    // MARK: thinkingStageIndex (B2 waiting-card rotation, Task 7)

    func testThinkingStageIndexStartsAtFirstStage() {
        XCTAssertEqual(thinkingStageIndex(elapsed: 0, stageCount: 3), 0)
    }

    func testThinkingStageIndexAdvancesAtMidIntervalPoints() {
        // Default interval is 2.6s: 1.0s is still stage 0, 3.0s has crossed into stage
        // 1, 6.0s has crossed into stage 2.
        XCTAssertEqual(thinkingStageIndex(elapsed: 1.0, stageCount: 3), 0)
        XCTAssertEqual(thinkingStageIndex(elapsed: 3.0, stageCount: 3), 1)
        XCTAssertEqual(thinkingStageIndex(elapsed: 6.0, stageCount: 3), 2)
    }

    func testThinkingStageIndexClampsAtLastStageOnLongWait() {
        // Real ritual turns take 100-150s — this is the expected steady state, not an
        // edge case: the index must hold on the last stage, not overflow or wrap.
        XCTAssertEqual(thinkingStageIndex(elapsed: 130, stageCount: 3), 2)
    }

    func testThinkingStageIndexHandlesSingleStage() {
        XCTAssertEqual(thinkingStageIndex(elapsed: 50, stageCount: 1), 0)
    }

    func testThinkingStageIndexHandlesZeroStagesWithoutCrashing() {
        XCTAssertEqual(thinkingStageIndex(elapsed: 10, stageCount: 0), 0)
    }

    func testThinkingStageIndexHandlesNegativeElapsed() {
        XCTAssertEqual(thinkingStageIndex(elapsed: -5, stageCount: 3), 0)
    }

    func testThinkingStageIndexRespectsCustomInterval() {
        XCTAssertEqual(thinkingStageIndex(elapsed: 4, stageCount: 3, interval: 5), 0)
        XCTAssertEqual(thinkingStageIndex(elapsed: 6, stageCount: 3, interval: 5), 1)
    }
}

private func makeDate(_ year: Int, _ month: Int, _ day: Int, timezone: TimeZone) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timezone
    let components = DateComponents(year: year, month: month, day: day, hour: 12)
    return calendar.date(from: components)!
}
