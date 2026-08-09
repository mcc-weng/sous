import XCTest
@testable import Sous

final class SwipeDeckLogicTests: XCTestCase {
    func test_swipeDirection_belowThreshold_isNil() {
        XCTAssertNil(swipeDirection(dragWidth: 40, dragHeight: 0))
    }

    func test_swipeDirection_rightPastThreshold_isLike() {
        XCTAssertEqual(swipeDirection(dragWidth: 90, dragHeight: 0), .like)
    }

    func test_swipeDirection_leftPastThreshold_isPass() {
        XCTAssertEqual(swipeDirection(dragWidth: -90, dragHeight: 0), .pass)
    }

    func test_swipeDirection_upPastThreshold_isModify() {
        XCTAssertEqual(swipeDirection(dragWidth: 10, dragHeight: -90), .modify)
    }

    func test_swipeDirection_horizontalDominatesWhenBothPastThreshold() {
        // a diagonal drag that clears both thresholds resolves to the larger axis
        XCTAssertEqual(swipeDirection(dragWidth: 90, dragHeight: -85), .like)
    }

    func test_cardRotation_scalesWithDragWidth() {
        XCTAssertEqual(cardRotation(dragWidth: 100), 5.0, accuracy: 0.0001)
        XCTAssertEqual(cardRotation(dragWidth: -40), -2.0, accuracy: 0.0001)
    }

    func test_stampOpacity_clampsAtOne() {
        XCTAssertEqual(stampOpacity(dragWidth: 40), 0.5, accuracy: 0.0001)
        XCTAssertEqual(stampOpacity(dragWidth: 200), 1.0, accuracy: 0.0001)
    }

    private func makeCandidate(_ text: String) -> SwipeCandidate {
        SwipeCandidate(id: UUID(), recipeId: nil, dishText: text, mode: nil,
                       meta: nil, pitch: nil, prepNote: nil)
    }

    func test_advance_popsFrontCandidate() {
        var state = SwipeDeckState(candidates: [makeCandidate("A"), makeCandidate("B")],
                                    pendingReinserts: [])
        let popped = state.advance()
        XCTAssertEqual(popped?.dishText, "A")
        XCTAssertEqual(state.candidates.map(\.dishText), ["B"])
    }

    func test_scheduleReinsert_surfacesAfterNAdvances_taggedUpdated() {
        var state = SwipeDeckState(candidates: [makeCandidate("A"), makeCandidate("B")],
                                    pendingReinserts: [])
        state.scheduleReinsert(makeCandidate("Revised"), afterCards: 2)
        _ = state.advance() // consumes A, 1 card seen
        _ = state.advance() // consumes B, 2 cards seen — reinsert now due
        XCTAssertEqual(state.candidates.first?.dishText, "Revised")
        XCTAssertEqual(state.candidates.first?.isUpdated, true)
    }

    func test_scheduleReinsert_notDueBeforeThreshold() {
        var state = SwipeDeckState(candidates: [makeCandidate("A")], pendingReinserts: [])
        state.scheduleReinsert(makeCandidate("Revised"), afterCards: 3)
        _ = state.advance() // 1 card seen, not due yet
        XCTAssertFalse(state.candidates.contains { $0.dishText == "Revised" })
    }
}
