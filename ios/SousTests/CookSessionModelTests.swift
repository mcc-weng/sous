import XCTest
@testable import Sous

final class CookSessionModelTests: XCTestCase {
    func testCookSessionDecodesPhotoUrl() throws {
        let json = """
        {"id": "\(UUID().uuidString)", "recipe_id": "\(UUID().uuidString)",
         "started_at": "2026-08-07T00:00:00Z", "completed_at": null,
         "photo_url": "abc/def.jpg"}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(CookSession.self, from: json)
        XCTAssertEqual(session.photoUrl, "abc/def.jpg")
    }

    func testCookSessionDecodesWithoutPhotoUrl() throws {
        let json = """
        {"id": "\(UUID().uuidString)", "recipe_id": "\(UUID().uuidString)",
         "started_at": "2026-08-07T00:00:00Z", "completed_at": null}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(CookSession.self, from: json)
        XCTAssertNil(session.photoUrl)
    }

    func testCookSessionSelectColumnsIncludesPhotoUrl() {
        XCTAssertEqual(CookSession.selectColumns, "id,recipe_id,started_at,completed_at,photo_url")
    }
}
