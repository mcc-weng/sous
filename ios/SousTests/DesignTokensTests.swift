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
