import XCTest
@testable import Sous

final class RitualSwipeSessionLogicTests: XCTestCase {
    private let week = ["2026-08-17", "2026-08-18", "2026-08-19", "2026-08-20",
                        "2026-08-21", "2026-08-22", "2026-08-23"]

    // MARK: - firstOpenDayIndex

    func testFirstOpenDayIndexWithNoneConfirmedIsZero() {
        XCTAssertEqual(firstOpenDayIndex(dates: week, confirmed: []), 0)
    }

    func testFirstOpenDayIndexSkipsConfirmedLeadingDays() {
        let confirmed: Set<String> = ["2026-08-17", "2026-08-18"]
        XCTAssertEqual(firstOpenDayIndex(dates: week, confirmed: confirmed), 2)
    }

    func testFirstOpenDayIndexFallsBackToZeroWhenAllConfirmed() {
        XCTAssertEqual(firstOpenDayIndex(dates: week, confirmed: Set(week)), 0)
    }

    // MARK: - nextOpenDayIndex

    func testNextOpenDayIndexFindsNextUnconfirmedDay() {
        let confirmed: Set<String> = ["2026-08-18"]  // index 1 is confirmed, so skip to 2
        XCTAssertEqual(nextOpenDayIndex(dates: week, confirmed: confirmed, after: 0), 2)
    }

    func testNextOpenDayIndexSkipsOverConfirmedDays() {
        let confirmed: Set<String> = ["2026-08-18", "2026-08-19"]
        XCTAssertEqual(nextOpenDayIndex(dates: week, confirmed: confirmed, after: 0), 3)
    }

    func testNextOpenDayIndexReturnsNilWhenNoneRemain() {
        let confirmed = Set(week.dropFirst())  // everything after index 0 confirmed
        XCTAssertNil(nextOpenDayIndex(dates: week, confirmed: confirmed, after: 0))
    }

    func testNextOpenDayIndexReturnsNilAtLastDay() {
        XCTAssertNil(nextOpenDayIndex(dates: week, confirmed: [], after: week.count - 1))
    }

    // MARK: - dayIndexAfterSwipe

    func testLikeAdvancesToNextOpenDay() {
        let confirmedAfter: Set<String> = ["2026-08-17"]  // just confirmed by this swipe
        let next = dayIndexAfterSwipe(direction: .like, dates: week,
                                      confirmedAfterSwipe: confirmedAfter, currentIndex: 0)
        XCTAssertEqual(next, 1)
    }

    func testLikeOnLastOpenDayStaysPut() {
        // Every day but the current one (index 0) is already confirmed; liking the
        // last one leaves nothing to advance to.
        var confirmedAfter = Set(week.dropFirst())
        confirmedAfter.insert(week[0])
        let next = dayIndexAfterSwipe(direction: .like, dates: week,
                                      confirmedAfterSwipe: confirmedAfter, currentIndex: 0)
        XCTAssertEqual(next, 0)
    }

    func testPassStaysOnSameDay() {
        let next = dayIndexAfterSwipe(direction: .pass, dates: week,
                                      confirmedAfterSwipe: [], currentIndex: 2)
        XCTAssertEqual(next, 2)
    }

    func testModifyStaysOnSameDay() {
        let next = dayIndexAfterSwipe(direction: .modify, dates: week,
                                      confirmedAfterSwipe: [], currentIndex: 4)
        XCTAssertEqual(next, 4)
    }

    func testLikeSkipsOverAlreadyConfirmedMiddleDay() {
        // Day 0 just confirmed by this swipe; day 1 was confirmed earlier (e.g. a
        // stale reload); the cursor should land on day 2, not day 1.
        let confirmedAfter: Set<String> = ["2026-08-17", "2026-08-18"]
        let next = dayIndexAfterSwipe(direction: .like, dates: week,
                                      confirmedAfterSwipe: confirmedAfter, currentIndex: 0)
        XCTAssertEqual(next, 2)
    }

    // MARK: - isWeekReadyToLock

    func testWeekReadyToLockWhenAllSevenConfirmed() {
        XCTAssertTrue(isWeekReadyToLock(dayCount: 7, confirmedCount: 7))
    }

    func testWeekNotReadyWhenSomeDaysUnconfirmed() {
        XCTAssertFalse(isWeekReadyToLock(dayCount: 7, confirmedCount: 6))
    }

    func testWeekNotReadyWhenShortOfSevenDaysEvenIfAllConfirmed() {
        // Guards against a dev/test week with fewer than 7 days looking "ready".
        XCTAssertFalse(isWeekReadyToLock(dayCount: 3, confirmedCount: 3))
    }
}
