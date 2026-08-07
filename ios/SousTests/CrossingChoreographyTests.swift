import XCTest
@testable import Sous

final class CrossingChoreographyTests: XCTestCase {
    @MainActor
    func testSetInitialToStageShowsOnlyStage() {
        let choreography = CrossingChoreography()
        choreography.setInitial(showingStage: true)
        XCTAssertFalse(choreography.paperVisible)
        XCTAssertTrue(choreography.stageVisible)
        XCTAssertEqual(choreography.stageOpacity, 1)
        XCTAssertEqual(choreography.glowOpacity, 1)
    }

    @MainActor
    func testSetInitialToPaperShowsOnlyPaper() {
        let choreography = CrossingChoreography()
        choreography.setInitial(showingStage: false)
        XCTAssertTrue(choreography.paperVisible)
        XCTAssertFalse(choreography.stageVisible)
        XCTAssertEqual(choreography.stageOpacity, 0)
        XCTAssertEqual(choreography.glowOpacity, 0)
    }

    @MainActor
    func testCrossToStageDimsPaperImmediately() {
        let choreography = CrossingChoreography()
        choreography.setInitial(showingStage: false)
        choreography.crossToStage(reduceMotion: false)
        XCTAssertTrue(choreography.paperDimmed)
        XCTAssertTrue(choreography.paperVisible) // still visible under the dim, briefly
        XCTAssertTrue(choreography.stageVisible) // in the tree, still transparent
    }

    @MainActor
    func testCrossToStageEndsWithOnlyStageVisible() {
        let choreography = CrossingChoreography()
        choreography.setInitial(showingStage: false)
        let expectation = expectation(description: "crossing settles")
        choreography.crossToStage(reduceMotion: false) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
        XCTAssertFalse(choreography.paperVisible)
        XCTAssertTrue(choreography.stageVisible)
        XCTAssertEqual(choreography.stageOpacity, 1)
        XCTAssertEqual(choreography.glowOpacity, 1)
    }

    @MainActor
    func testCrossToPaperEndsWithOnlyPaperVisible() {
        let choreography = CrossingChoreography()
        choreography.setInitial(showingStage: true)
        let expectation = expectation(description: "crossing settles")
        choreography.crossToPaper(reduceMotion: false) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
        XCTAssertTrue(choreography.paperVisible)
        XCTAssertFalse(choreography.stageVisible)
        XCTAssertFalse(choreography.paperDimmed)
        XCTAssertEqual(choreography.stageOpacity, 0)
        XCTAssertEqual(choreography.glowOpacity, 0)
    }

    @MainActor
    func testReduceMotionSettlesImmediately() {
        let choreography = CrossingChoreography()
        choreography.setInitial(showingStage: false)
        choreography.crossToStage(reduceMotion: true)
        XCTAssertFalse(choreography.paperVisible)
        XCTAssertTrue(choreography.stageVisible)
        XCTAssertEqual(choreography.stageOpacity, 1)
    }
}
