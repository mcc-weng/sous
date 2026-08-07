import SwiftUI
import UIKit

enum PaperTokens {
    static let stock = Color(red: 0xED / 255, green: 0xEA / 255, blue: 0xE2 / 255)
    static let stockAlt = Color(red: 0xE7 / 255, green: 0xE2 / 255, blue: 0xD8 / 255)
    static let slip = Color(red: 0xF7 / 255, green: 0xF4 / 255, blue: 0xEC / 255)
    static let ink = Color(red: 0x22 / 255, green: 0x20 / 255, blue: 0x1C / 255)
    static let inkDim = Color(red: 0x4E / 255, green: 0x4A / 255, blue: 0x42 / 255)
    static let inkFaint = Color(red: 0x5E / 255, green: 0x5A / 255, blue: 0x52 / 255)
    /// `paper.seal` (README design-tokens table) fallback only — the accent colour is
    /// persona-tintable and must come from `personas.tint` at runtime (`AppModel.
    /// personaTint`, parsed via `color(fromHex:)`), never baked in at compile time.
    /// This constant exists solely as the value `AppModel.personaTint` starts at
    /// before persona data loads, and what it falls back to if a persona's `tint` is
    /// missing or malformed. Views must read `model.personaTint`, not this token,
    /// for the seal/accent colour.
    static let sealFallback = Color(red: 0x9B / 255, green: 0x2C / 255, blue: 0x1E / 255)
    static let rule = ink.opacity(0.20)
    static let ruleStrong = ink.opacity(0.42)
    static let leader = ink.opacity(0.30)
}

/// 灶 · Stage — the dark half of 書與灶, reserved for exactly three screens per the
/// design handoff: cook-mode steps, timers, and 上菜 (`Sous App v2.dc.html` calls this
/// "if your hands are busy and something is counting, dark; everything else is paper").
/// Cook Mode (Pass 1c) is the first screen set to use this enum — Pass 1a only ever
/// built `PaperTokens`.
enum StageTokens {
    static let bg = Color(red: 0x0C / 255, green: 0x0A / 255, blue: 0x09 / 255)
    static let ink = Color(red: 0xF4 / 255, green: 0xEF / 255, blue: 0xE6 / 255)
    static let inkDim = Color(red: 0xA4 / 255, green: 0x9D / 255, blue: 0x93 / 255)
    static let brass = Color(red: 0xC9 / 255, green: 0x8A / 255, blue: 0x3E / 255)
    static let brassSoft = Color(red: 0xDC / 255, green: 0xC5 / 255, blue: 0x9C / 255)
    static let rule = ink.opacity(0.20)

    /// Anchored to the bottom edge, arrives last in the crossing (500ms) — "light comes
    /// on last, the way a gas ring does" (README §Motion).
    static var glow: some View {
        RadialGradient(
            colors: [brass.opacity(0.20), .clear],
            center: .center, startRadius: 0, endRadius: 160
        )
    }
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

/// Parses a `#RRGGBB` (leading `#` optional, case-insensitive) hex string — the shape
/// `personas.tint` is stored in — into a SwiftUI `Color`. Pure and side-effect free so
/// it's independently testable; returns `nil` rather than crashing on anything that
/// isn't exactly 6 hex digits, so a malformed or missing DB value can't take the app
/// down. Callers (`AppModel.loadPersonaCopy`) fall back to `PaperTokens.sealFallback`
/// when this returns `nil`.
func color(fromHex hex: String) -> Color? {
    var digits = hex
    if digits.hasPrefix("#") { digits.removeFirst() }
    guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
    let red = Double((value >> 16) & 0xFF) / 255
    let green = Double((value >> 8) & 0xFF) / 255
    let blue = Double(value & 0xFF) / 255
    return Color(red: red, green: green, blue: blue)
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
