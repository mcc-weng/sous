import XCTest
@testable import Sous

final class CookModeLogicTests: XCTestCase {
    func testChecklistIncompleteWhenAnyUnchecked() {
        XCTAssertFalse(isChecklistComplete([true, false, true]))
    }

    func testChecklistCompleteWhenAllChecked() {
        XCTAssertTrue(isChecklistComplete([true, true]))
    }

    func testChecklistIncompleteWhenEmpty() {
        XCTAssertFalse(isChecklistComplete([]))
    }

    func testClampedStepIndexStaysInLowerBound() {
        XCTAssertEqual(clampedStepIndex(-1, stepCount: 5), 0)
    }

    func testClampedStepIndexStaysInUpperBound() {
        XCTAssertEqual(clampedStepIndex(10, stepCount: 5), 4)
    }

    func testClampedStepIndexInBoundsUnchanged() {
        XCTAssertEqual(clampedStepIndex(2, stepCount: 5), 2)
    }

    func testClampedStepIndexWithNoStepsIsZero() {
        XCTAssertEqual(clampedStepIndex(3, stepCount: 0), 0)
    }

    func testVerdictPayloadNilWithoutPlanDay() {
        let payload = makeVerdictPayload(householdId: UUID(), planDayId: nil, rating: "不錯", note: nil)
        XCTAssertNil(payload)
    }

    func testVerdictPayloadBuiltWithPlanDay() {
        let household = UUID()
        let planDay = UUID()
        let payload = makeVerdictPayload(householdId: household, planDayId: planDay, rating: "神作", note: "好吃")
        XCTAssertEqual(payload, VerdictPayload(household_id: household, plan_day_id: planDay, rating: "神作", note: "好吃"))
    }
}
