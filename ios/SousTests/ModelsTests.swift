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

    /// Regression test for the bug that shipped empty in production for two days:
    /// `AppModel.loadCookbook()` used to hand-maintain its PostgREST `select=` column
    /// list separately from `Recipe`'s fields, and silently dropped `servings` when that
    /// field was added — this decodes every field `Recipe.selectColumns` claims to fetch,
    /// proving the derived list is actually complete and decodable, not just present.
    func testSelectColumnsProduceADecodableRecipe() throws {
        let columns = Set(Recipe.selectColumns.split(separator: ",").map(String.init))
        XCTAssertEqual(columns, ["id", "slug", "title", "source_block", "body_md",
                                  "ingredients", "steps", "created_at", "servings"])
        let json = """
        {"id": "\(UUID().uuidString)", "slug": "test", "title": "測試",
         "source_block": null, "body_md": "", "ingredients": [], "steps": [],
         "created_at": "2026-08-04T00:00:00Z", "servings": 2}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertNoThrow(try decoder.decode(Recipe.self, from: json))
    }

    // MARK: - weekdayGlyph

    func testWeekdayGlyphOnMonday() throws {
        // 2026-08-17 is a Monday.
        XCTAssertEqual(weekdayGlyph(for: "2026-08-17", timezone: .current), "一")
    }

    func testWeekdayGlyphOnSunday() throws {
        // 2026-08-16 is a Sunday — glyph table wraps back to "日".
        XCTAssertEqual(weekdayGlyph(for: "2026-08-16", timezone: .current), "日")
    }

    func testWeekdayGlyphOnSaturday() throws {
        // 2026-08-22 is a Saturday, the last entry in the glyph table.
        XCTAssertEqual(weekdayGlyph(for: "2026-08-22", timezone: .current), "六")
    }

    func testWeekdayGlyphReturnsEmptyStringForMalformedDate() throws {
        XCTAssertEqual(weekdayGlyph(for: "not-a-date", timezone: .current), "")
    }
}
