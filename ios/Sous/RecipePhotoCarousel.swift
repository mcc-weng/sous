// ios/Sous/RecipePhotoCarousel.swift
import SwiftUI

/// Tap-to-advance photo carousel for Recipe Detail (D1). Placeholder-only through Pass
/// 1b (`cook_sessions.photo_url` didn't exist yet — see
/// docs/superpowers/specs/2026-08-04-m3-visual-restyle-pass1b-recipe-detail-design.md);
/// Pass 1c wires it to real captured 上菜 photos via `photoPaths` (most-recent-first
/// object paths — `cookPhotoPaths` in `CookHistoryLogic.swift`) and `loadImage`
/// (`AppModel.downloadPhoto` — `cook-photos` is a private bucket, no plain public URL to
/// hand `AsyncImage`). Falls back to the original hatched placeholder when `photoPaths`
/// is empty — true for most recipes immediately after this ships, since it takes one
/// real cook to populate. Tap zones instead of swipe: swipe is reserved for the separate
/// swipe-ritual gesture elsewhere in the app.
struct RecipePhotoCarousel: View {
    let accentColor: Color
    let photoPaths: [String]
    let loadImage: (String) async -> Data?

    @State private var index = 0
    @State private var loadedImages: [String: UIImage] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ZStack {
                if let path = photoPaths[safe: index], let image = loadedImages[path] {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    placeholderFill
                }
            }
            .frame(height: 194)
            .clipped()
            .overlay(alignment: .topLeading) { progressSegments }
            .overlay(tapZones)

            captionText
        }
        .task(id: photoPaths) {
            for path in photoPaths where loadedImages[path] == nil {
                if let data = await loadImage(path), let image = UIImage(data: data) {
                    loadedImages[path] = image
                }
            }
        }
    }

    private var placeholderFill: some View {
        ZStack {
            Rectangle().fill(
                LinearGradient(colors: [PaperTokens.ink.opacity(0.06), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            Text("料理照片")
                .font(.system(size: 10, design: .monospaced))
                .tracking(2)
                .foregroundStyle(PaperTokens.inkFaint)
        }
    }

    private var captionText: some View {
        Text(photoPaths.isEmpty
             ? "圖 · 之後煮這道菜的照片會顯示在這裡。"
             : "圖 · 你拍的成品照。")
            .font(.system(size: 11.5))
            .italic()
            .foregroundStyle(PaperTokens.inkDim)
    }

    private var progressSegments: some View {
        HStack(spacing: 3) {
            ForEach(0..<max(photoPaths.count, 1), id: \.self) { i in
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
        let count = max(photoPaths.count, 1)
        let next = index + delta
        guard next >= 0, next < count else { return }
        index = next
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
