import XCTest
@testable import Sous

final class ModelsTests: XCTestCase {
    func testIngredientDecodesStructuredQuantityFields() throws {
        let json = """
        {"name": "雞胸肉", "qty": "300g", "qty_value": 300, "qty_unit": "g"}
        """.data(using: .utf8)!
        let ingredient = try JSONDecoder().decode(Ingredient.self, from: json)
        XCTAssertEqual(ingredient.name, "雞胸肉")
        XCTAssertEqual(ingredient.qty, "300g")
        XCTAssertEqual(ingredient.qtyValue, 300)
        XCTAssertEqual(ingredient.qtyUnit, "g")
    }

    func testIngredientDecodesWithoutStructuredQuantityFields() throws {
        let json = """
        {"name": "鹽", "qty": "一撮"}
        """.data(using: .utf8)!
        let ingredient = try JSONDecoder().decode(Ingredient.self, from: json)
        XCTAssertEqual(ingredient.name, "鹽")
        XCTAssertNil(ingredient.qtyValue)
        XCTAssertNil(ingredient.qtyUnit)
    }

    func testRecipeDecodesServingsField() throws {
        let json = """
        {"id": "\(UUID().uuidString)", "slug": "test", "title": "測試",
         "source_block": null, "body_md": "", "ingredients": [], "steps": [],
         "created_at": "2026-08-04T00:00:00Z", "servings": 4}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let recipe = try decoder.decode(Recipe.self, from: json)
        XCTAssertEqual(recipe.servings, 4)
    }
}
