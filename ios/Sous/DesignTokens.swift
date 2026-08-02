import SwiftUI
import UIKit

enum PaperTokens {
    static let stock = Color(red: 0xED / 255, green: 0xEA / 255, blue: 0xE2 / 255)
    static let stockAlt = Color(red: 0xE7 / 255, green: 0xE2 / 255, blue: 0xD8 / 255)
    static let slip = Color(red: 0xF7 / 255, green: 0xF4 / 255, blue: 0xEC / 255)
    static let ink = Color(red: 0x22 / 255, green: 0x20 / 255, blue: 0x1C / 255)
    static let inkDim = Color(red: 0x4E / 255, green: 0x4A / 255, blue: 0x42 / 255)
    static let inkFaint = Color(red: 0x5E / 255, green: 0x5A / 255, blue: 0x52 / 255)
    static let rule = ink.opacity(0.20)
    static let ruleStrong = ink.opacity(0.42)
    static let leader = ink.opacity(0.30)
}

enum Spacing {
    static let pageMargin: CGFloat = 34
    static let deckMargin: CGFloat = 27
    static let sm: CGFloat = 8
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
}

/// `bundled` is injected (not read from the font registry internally) so this stays a
/// pure, testable function — call sites pass `FontBook.isSerifBundled` (Task 3).
func serifFontName(bundled: Bool) -> String {
    bundled ? "NotoSerifTC-Regular" : "STSongti-TC-Regular"
}

func sansFontName(bundled: Bool) -> String {
    bundled ? "NotoSansTC-Regular" : "PingFang TC"
}

/// Determines whether the bundled Noto faces are actually registered at runtime, by
/// checking `UIFont.familyNames` (populated from files + `UIAppFonts` in Info.plist).
/// Call sites pass this into `serifFontName(bundled:)` / `sansFontName(bundled:)`.
enum FontBook {
    static var isSerifBundled: Bool {
        UIFont.familyNames.contains { $0.contains("Noto Serif TC") }
    }
    static var isSansBundled: Bool {
        UIFont.familyNames.contains { $0.contains("Noto Sans TC") }
    }
}
