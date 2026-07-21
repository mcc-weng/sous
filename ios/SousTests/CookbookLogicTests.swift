import XCTest
@testable import Sous

final class CookbookLogicTests: XCTestCase {
    private func makeRecipe(_ title: String) -> Recipe {
        Recipe(id: UUID(), slug: title, title: title, sourceBlock: nil, bodyMd: "",
               ingredients: [], steps: [], createdAt: Date())
    }

    func testFilteredRecipesReturnsAllWhenQueryEmpty() {
        let recipes = [makeRecipe("紅燒牛肉麵"), makeRecipe("三杯雞")]
        XCTAssertEqual(filteredRecipes(recipes, query: ""), recipes)
    }

    func testFilteredRecipesMatchesCaseInsensitiveSubstring() {
        let beef = makeRecipe("紅燒牛肉麵")
        let chicken = makeRecipe("三杯雞")
        let result = filteredRecipes([beef, chicken], query: "牛肉")
        XCTAssertEqual(result, [beef])
    }

    func testFilteredRecipesTrimsWhitespaceQuery() {
        let recipes = [makeRecipe("紅燒牛肉麵")]
        XCTAssertEqual(filteredRecipes(recipes, query: "   "), recipes)
    }

    func testFilteredRecipesReturnsEmptyWhenNoMatch() {
        let recipes = [makeRecipe("紅燒牛肉麵")]
        XCTAssertEqual(filteredRecipes(recipes, query: "咖哩"), [])
    }
}
