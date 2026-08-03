import UIKit
import XCTest
@testable import Sous

final class DesignTokensTests: XCTestCase {
    func testSerifFontNameUsesBundledFaceWhenAvailable() {
        XCTAssertEqual(serifFontName(bundled: true), "NotoSerifTC-Regular")
    }

    func testSerifFontNameFallsBackToSystemSerifWhenNotBundled() {
        // Songti TC (PostScript name STSongti-TC-Regular) is iOS's built-in
        // Traditional Chinese serif — a real fallback, not a sans substitute, since
        // the serif/sans split carries real meaning (小當家's voice vs. interface
        // chrome) and a sans fallback would silently erase that distinction everywhere
        // at once.
        XCTAssertEqual(serifFontName(bundled: false), "STSongti-TC-Regular")
    }

    func testSansFontNameUsesBundledFaceWhenAvailable() {
        XCTAssertEqual(sansFontName(bundled: true), "NotoSansTC-Regular")
    }

    func testSansFontNameFallsBackToSystemSansWhenNotBundled() {
        XCTAssertEqual(sansFontName(bundled: false), "PingFang TC")
    }
}

extension DesignTokensTests {
    func testFontBookDetectsBundledSerifWhenRegistered() {
        // UIFont.familyNames only includes fonts actually present in the bundle +
        // registered via Info.plist UIAppFonts, so this exercises the real path
        // rather than a mock.
        let isBundled = UIFont.familyNames.contains { $0.contains("Noto Serif TC") }
        XCTAssertEqual(FontBook.isSerifBundled, isBundled)
    }
}

/// `color(fromHex:)` is what turns `personas.tint` (read at runtime from the DB) into
/// a renderable `Color`, so the persona accent colour is data, not a compile-time
/// constant. These tests exercise the pure parsing function directly — no network,
/// no AppModel — matching `PaperTokens.sealFallback`'s known #9B2C1E value so a
/// regression here would silently break dynamic persona tinting app-wide.
final class ColorFromHexTests: XCTestCase {
    func testParsesSixDigitHexWithLeadingHash() {
        XCTAssertEqual(color(fromHex: "#9B2C1E"), PaperTokens.sealFallback)
    }

    func testParsesSixDigitHexWithoutLeadingHash() {
        XCTAssertEqual(color(fromHex: "9B2C1E"), PaperTokens.sealFallback)
    }

    func testParsingIsCaseInsensitive() {
        XCTAssertEqual(color(fromHex: "#9b2c1e"), PaperTokens.sealFallback)
    }

    func testReturnsNilForMalformedInput() {
        XCTAssertNil(color(fromHex: "not-a-color"))
        XCTAssertNil(color(fromHex: "#12345"))    // too short
        XCTAssertNil(color(fromHex: "#1234567"))  // too long
        XCTAssertNil(color(fromHex: "#GGGGGG"))   // non-hex digits
        XCTAssertNil(color(fromHex: ""))          // empty
    }
}

/// Regression coverage for a real bug found while building the B2 waiting-state UI
/// (M3 visual restyle, Task 7): `copy_pack` is `jsonb` and almost every key is
/// string-valued, but migration 0016 added `thinking_stages` as a JSON *array*.
/// Decoding it into a `[String: String]` dictionary throws `DecodingError.typeMismatch`
/// — and because Codable dictionary decode is all-or-nothing, that one array-valued
/// key fails the ENTIRE `copy_pack` dictionary, not just itself. `AppModel.
/// loadPersonaCopy()`'s `catch { print(...) }` swallows the throw, so `personaCopy`
/// silently never loads at all once a persona's copy_pack contains this key — which it
/// already does (migration 0016 is seeded). This went unnoticed because every
/// call site's hardcoded fallback (e.g. ChatView's `personaCopy["inbox_title"] ??
/// "與小當家的往來"`) happens to equal the seeded value, so nothing visibly looked broken.
final class PersonaCopyRowDecodingTests: XCTestCase {
    private let migration0016ShapedJSON = """
    {"copy_pack": {"inbox_title": "與小當家的往來", "thinking_stages": ["看菜單…", "配菜…", "寫清單…"]}, "tint": "#9B2C1E"}
    """.data(using: .utf8)!

    func testDecodesStringAndArrayValuedKeysTogether() throws {
        let row = try JSONDecoder().decode(PersonaCopyRow.self, from: migration0016ShapedJSON)
        XCTAssertEqual(row.copyPack["inbox_title"], "與小當家的往來")
        XCTAssertEqual(row.thinkingStages, ["看菜單…", "配菜…", "寫清單…"])
        XCTAssertEqual(row.tint, "#9B2C1E")
    }

    func testThinkingStagesKeyDoesNotLeakIntoStringCopyPack() throws {
        let row = try JSONDecoder().decode(PersonaCopyRow.self, from: migration0016ShapedJSON)
        XCTAssertNil(row.copyPack["thinking_stages"])
    }

    func testMissingThinkingStagesFallsBackToEmptyArray() throws {
        let json = """
        {"copy_pack": {"inbox_title": "與小當家的往來"}, "tint": null}
        """.data(using: .utf8)!
        let row = try JSONDecoder().decode(PersonaCopyRow.self, from: json)
        XCTAssertEqual(row.thinkingStages, [])
        XCTAssertNil(row.tint)
    }

    func testUnknownValueTypeIsDroppedNotThrown() throws {
        // A future copy_pack key of some other JSON type (bool/number/object) must not
        // resurrect this bug — AnyJSON-backed decoding drops what it can't stringify
        // instead of failing the whole dictionary the way [String: String] did.
        let json = """
        {"copy_pack": {"inbox_title": "與小當家的往來", "some_flag": true, "some_count": 3}, "tint": "#9B2C1E"}
        """.data(using: .utf8)!
        let row = try JSONDecoder().decode(PersonaCopyRow.self, from: json)
        XCTAssertEqual(row.copyPack["inbox_title"], "與小當家的往來")
        XCTAssertNil(row.copyPack["some_flag"])
        XCTAssertNil(row.copyPack["some_count"])
    }
}
