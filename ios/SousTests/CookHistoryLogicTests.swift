import XCTest
@testable import Sous

final class CookHistoryLogicTests: XCTestCase {
    private func makeSession(recipeId: UUID, completed: Bool) -> CookSession {
        CookSession(id: UUID(), recipeId: recipeId, startedAt: Date(),
                    completedAt: completed ? Date() : nil, photoUrl: nil)
    }

    func testCookCountMatchesOnlyGivenRecipe() {
        let target = UUID()
        let other = UUID()
        let sessions = [
            makeSession(recipeId: target, completed: true),
            makeSession(recipeId: other, completed: true),
            makeSession(recipeId: target, completed: true),
        ]
        XCTAssertEqual(cookCount(sessions: sessions, recipeId: target), 2)
    }

    func testCookCountExcludesIncompleteSessions() {
        let target = UUID()
        let sessions = [
            makeSession(recipeId: target, completed: true),
            makeSession(recipeId: target, completed: false),
        ]
        XCTAssertEqual(cookCount(sessions: sessions, recipeId: target), 1)
    }

    func testCookCountZeroForNoMatches() {
        XCTAssertEqual(cookCount(sessions: [], recipeId: UUID()), 0)
    }

    func testIsMilestoneTrueAtEarlyThresholds() {
        XCTAssertTrue(isMilestone(3))
        XCTAssertTrue(isMilestone(5))
    }

    func testIsMilestoneTrueAtRoundTens() {
        XCTAssertTrue(isMilestone(10))
        XCTAssertTrue(isMilestone(20))
        XCTAssertTrue(isMilestone(30))
    }

    func testIsMilestoneFalseElsewhere() {
        for n in [1, 2, 4, 6, 9, 11, 19, 21, 25] {
            XCTAssertFalse(isMilestone(n), "expected \(n) to not be a milestone")
        }
    }

    func testMilestoneReactionTextSubstitutesCount() {
        XCTAssertEqual(milestoneReactionText(count: 5, template: "第 {n} 次!"), "第 5 次!")
    }

    func testMilestoneReactionTextUsesFallbackWhenTemplateNil() {
        let result = milestoneReactionText(count: 3, template: nil)
        XCTAssertTrue(result.contains("3"))
    }

    private func session(recipeId: UUID, photoUrl: String?, startedAt: Date) -> CookSession {
        CookSession(id: UUID(), recipeId: recipeId, startedAt: startedAt,
                   completedAt: startedAt, photoUrl: photoUrl)
    }

    func testCookPhotoPathsFiltersToRecipeAndPresence() {
        let target = UUID()
        let other = UUID()
        let sessions = [
            session(recipeId: target, photoUrl: "a.jpg", startedAt: Date()),
            session(recipeId: target, photoUrl: nil, startedAt: Date()),
            session(recipeId: other, photoUrl: "b.jpg", startedAt: Date()),
        ]
        XCTAssertEqual(cookPhotoPaths(sessions: sessions, recipeId: target), ["a.jpg"])
    }

    func testCookPhotoPathsOrdersMostRecentFirst() {
        let recipeId = UUID()
        let older = session(recipeId: recipeId, photoUrl: "older.jpg",
                            startedAt: Date().addingTimeInterval(-3600))
        let newer = session(recipeId: recipeId, photoUrl: "newer.jpg", startedAt: Date())
        XCTAssertEqual(cookPhotoPaths(sessions: [older, newer], recipeId: recipeId),
                      ["newer.jpg", "older.jpg"])
    }

    func testCookPhotoPathsEmptyWhenNoneCaptured() {
        let recipeId = UUID()
        let sessions = [session(recipeId: recipeId, photoUrl: nil, startedAt: Date())]
        XCTAssertEqual(cookPhotoPaths(sessions: sessions, recipeId: recipeId), [])
    }
}
