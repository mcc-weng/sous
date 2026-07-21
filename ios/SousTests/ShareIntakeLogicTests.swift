import XCTest
@testable import Sous

final class ShareIntakeLogicTests: XCTestCase {
    func testMakeRecipeIntakeJobShapesPayload() {
        let household = UUID()
        let url = URL(string: "https://www.youtube.com/watch?v=NbmT_9oH1SY")!
        let job = makeRecipeIntakeJob(householdId: household, url: url)
        XCTAssertEqual(job, RecipeIntakeJob(
            household_id: household, kind: "recipe_intake",
            payload: .init(url: "https://www.youtube.com/watch?v=NbmT_9oH1SY", by: "mike")
        ))
    }
}
