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
