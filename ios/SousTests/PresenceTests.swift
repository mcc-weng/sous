import XCTest
@testable import Sous

final class PresenceTests: XCTestCase {
    func testNilSeenIsAway() {
        XCTAssertFalse(chefIsPresent(workerSeenAt: nil))
    }

    func testRecentSeenIsPresent() {
        XCTAssertTrue(chefIsPresent(workerSeenAt: Date().addingTimeInterval(-30)))
    }

    func testStaleSeenIsAway() {
        XCTAssertFalse(chefIsPresent(workerSeenAt: Date().addingTimeInterval(-120)))
    }
}
