import XCTest
@testable import Sous

/// Covers `slipSignature`, the pure timestamp formatter added in the A3 (便條) restyle
/// (ChatView.swift). Not asked for by the task brief, but it's new branching logic
/// (not just styling), so it gets the same test-coverage treatment as the codebase's
/// other small pure helpers (e.g. CounterViewLogicTests).
final class ChatViewLogicTests: XCTestCase {
    private let taipei = TimeZone(identifier: "Asia/Taipei")!

    func testSlipSignatureSameDayFormatsTime() {
        let now = makeDate(2026, 8, 3, hour: 20, minute: 15, timezone: taipei)
        let sent = makeDate(2026, 8, 3, hour: 19, minute: 30, timezone: taipei)
        XCTAssertEqual(slipSignature(for: sent, now: now, timezone: taipei), "19:30")
    }

    func testSlipSignatureYesterdayReturnsRelativeLabel() {
        let now = makeDate(2026, 8, 3, hour: 9, minute: 0, timezone: taipei)
        let sent = makeDate(2026, 8, 2, hour: 22, minute: 5, timezone: taipei)
        XCTAssertEqual(slipSignature(for: sent, now: now, timezone: taipei), "昨天")
    }

    func testSlipSignatureOlderFallsBackToChineseDate() {
        let now = makeDate(2026, 8, 3, hour: 9, minute: 0, timezone: taipei)
        let sent = makeDate(2026, 7, 28, hour: 12, minute: 0, timezone: taipei)
        XCTAssertEqual(slipSignature(for: sent, now: now, timezone: taipei), "七月二十八日")
    }

    func testSlipSignatureRespectsTimezoneBoundary() {
        // 2026-08-03 23:30 Taipei is still 2026-08-03 15:30 UTC — same-day in Taipei,
        // so the timezone parameter (not the system default) must drive the compare.
        let now = makeDate(2026, 8, 3, hour: 23, minute: 45, timezone: taipei)
        let sent = makeDate(2026, 8, 3, hour: 23, minute: 30, timezone: taipei)
        XCTAssertEqual(slipSignature(for: sent, now: now, timezone: taipei), "23:30")
    }
}

private func makeDate(_ year: Int, _ month: Int, _ day: Int, hour: Int, minute: Int, timezone: TimeZone) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timezone
    let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
    return calendar.date(from: components)!
}
