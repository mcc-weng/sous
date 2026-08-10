import XCTest
@testable import Sous

final class ExploreDeckLogicTests: XCTestCase {
    private func makeRecipe(_ id: UUID, _ title: String) -> Recipe {
        Recipe(id: id, slug: title, title: title, sourceBlock: nil, bodyMd: "",
              ingredients: [], steps: [], createdAt: Date(), servings: 2)
    }

    func test_exploreCandidates_excludesRecentlyPassed() {
        let keep = UUID(); let dropped = UUID()
        let recipes = [makeRecipe(keep, "留下"), makeRecipe(dropped, "剔除")]
        let result = exploreCandidates(recipes: recipes, recentlyPassed: [dropped])
        XCTAssertEqual(result.map(\.recipeId), [keep])
    }

    func test_exploreCandidates_mapsRecipeFields() {
        let id = UUID()
        let result = exploreCandidates(recipes: [makeRecipe(id, "蔥油雞")], recentlyPassed: [])
        XCTAssertEqual(result.first?.recipeId, id)
        XCTAssertEqual(result.first?.dishText, "蔥油雞")
        XCTAssertNil(result.first?.mode) // Explore cards carry no day/mode context
    }

    func test_exploreCandidates_emptyWhenAllPassed() {
        let id = UUID()
        XCTAssertTrue(exploreCandidates(recipes: [makeRecipe(id, "X")], recentlyPassed: [id]).isEmpty)
    }
}
