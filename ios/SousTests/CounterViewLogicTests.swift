import XCTest
@testable import Sous

/// Covers the pure Chinese-numeral date formatting added in the A2 (Kitchen Counter)
/// restyle — `chineseDateString`/`chineseNumeral` in CounterView.swift, used for the
/// running-head date (e.g. `八月三日` for August 3rd). Not asked for by the task brief,
/// but it's new branching logic (not just styling), so it gets the same test-coverage
/// treatment as the codebase's other small pure helpers (e.g. WeekBoardLogicTests).
final class CounterViewLogicTests: XCTestCase {
    private let taipei = TimeZone(identifier: "Asia/Taipei")!

    func testChineseNumeralSingleDigits() {
        XCTAssertEqual(chineseNumeral(1), "一")
        XCTAssertEqual(chineseNumeral(8), "八")
        XCTAssertEqual(chineseNumeral(9), "九")
    }

    func testChineseNumeralTen() {
        XCTAssertEqual(chineseNumeral(10), "十")
    }

    func testChineseNumeralTeens() {
        XCTAssertEqual(chineseNumeral(11), "十一")
        XCTAssertEqual(chineseNumeral(19), "十九")
    }

    func testChineseNumeralTensRoundNumbers() {
        XCTAssertEqual(chineseNumeral(20), "二十")
        XCTAssertEqual(chineseNumeral(30), "三十")
    }

    func testChineseNumeralTensWithOnes() {
        XCTAssertEqual(chineseNumeral(23), "二十三")
        XCTAssertEqual(chineseNumeral(31), "三十一")
    }

    func testChineseDateStringFormatsMonthAndDay() {
        // 2026-08-03 (a single-digit month, single-digit day)
        let date = makeDate(2026, 8, 3, timezone: taipei)
        XCTAssertEqual(chineseDateString(date, timezone: taipei), "八月三日")
    }

    func testChineseDateStringHandlesTwoDigitDay() {
        // 2026-12-25 (two-digit month equivalent via day, exercises the tens branch)
        let date = makeDate(2026, 12, 25, timezone: taipei)
        XCTAssertEqual(chineseDateString(date, timezone: taipei), "十二月二十五日")
    }
}

private func makeDate(_ year: Int, _ month: Int, _ day: Int, timezone: TimeZone) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timezone
    let components = DateComponents(year: year, month: month, day: day, hour: 12)
    return calendar.date(from: components)!
}
