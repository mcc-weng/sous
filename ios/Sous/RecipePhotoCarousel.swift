// ios/Sous/RecipePhotoCarousel.swift
import SwiftUI

/// Tap-to-advance photo carousel for Recipe Detail (D1) — placeholder-only in Pass 1b
/// (see docs/superpowers/specs/2026-08-04-m3-visual-restyle-pass1b-recipe-detail-design.md
/// "Scope decisions"): `cook_sessions.photo_url` doesn't exist until Pass 1c, so there's
/// no real photo data to query yet. Tap zones instead of swipe because swipe is reserved
/// for the separate swipe-ritual gesture elsewhere in the app.
struct RecipePhotoCarousel: View {
    let accentColor: Color
    private let placeholderCount = 2
    @State private var index = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ZStack {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [PaperTokens.ink.opacity(0.06), .clear],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                Text("料理照片")
                    .font(.system(size: 10, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(PaperTokens.inkFaint)
            }
            .frame(height: 194)
            .overlay(alignment: .topLeading) { progressSegments }
            .overlay(tapZones)

            Text("圖 · 之後煮這道菜的照片會顯示在這裡。")
                .font(.system(size: 11.5))
                .italic()
                .foregroundStyle(PaperTokens.inkDim)
        }
    }

    private var progressSegments: some View {
        HStack(spacing: 3) {
            ForEach(0..<placeholderCount, id: \.self) { i in
                Rectangle()
                    .fill(i == index ? accentColor : PaperTokens.ink.opacity(0.18))
                    .frame(height: 2)
            }
        }
        .padding(8)
    }

    private var tapZones: some View {
        HStack(spacing: 0) {
            Color.clear.contentShape(Rectangle()).onTapGesture { advance(by: -1) }
            Color.clear.contentShape(Rectangle()).onTapGesture { advance(by: 1) }
        }
    }

    private func advance(by delta: Int) {
        let next = index + delta
        guard next >= 0, next < placeholderCount else { return }
        index = next
    }
}
