import SwiftUI

/// B1 §滑牌儀式 / D3 §探索牌組 — the shared three-sheet swipeable card stack. The two
/// screens differ only in what's passed: Explore omits `dayLabel`/progress (README:
/// "distinguished by what is absent — no day chip, no progress rule, no lock").
struct SwipeCardStack: View {
    let candidates: [SwipeCandidate]
    let dayLabel: String?
    let progressFilled: Int?
    let progressTotal: Int?
    let onSwipe: (SwipeCandidate, SwipeDirection) -> Void
    let onModifyNote: (SwipeCandidate, String) -> Void

    @EnvironmentObject private var model: AppModel
    @GestureState private var dragOffset: CGSize = .zero
    @State private var showModifyPanel = false
    @State private var modifyText = ""

    private var serifName: String { serifFontName(bundled: FontBook.isSerifBundled) }
    private var sansName: String { sansFontName(bundled: FontBook.isSansBundled) }

    var body: some View {
        VStack(spacing: 0) {
            if let filled = progressFilled, let total = progressTotal {
                progressHeader(filled: filled, total: total)
            }
            ZStack {
                ForEach(Array(candidates.prefix(3).enumerated().reversed()), id: \.element.id) { index, candidate in
                    cardView(candidate)
                        .rotationEffect(.degrees(index == 0 ? cardRotation(dragWidth: dragOffset.width) : (index == 1 ? -0.9 : 1.5)))
                        .offset(index == 0 ? dragOffset : .zero)
                        .offset(y: index == 1 ? 3 : (index == 2 ? 7 : 0))
                        .zIndex(Double(3 - index))
                        .allowsHitTesting(index == 0)
                        .gesture(index == 0 ? dragGesture(for: candidate) : nil)
                }
            }
            .padding(.horizontal, Spacing.deckMargin)

            if showModifyPanel, let current = candidates.first {
                modifyPanel(current)
            } else {
                footerBar
            }
        }
    }

    private func progressHeader(filled: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("已排 \(filled) / \(total) 天")
                Spacer()
                Text("還剩 \(total - filled) 天")
            }
            .font(.custom(sansName, size: 10.5))
            .tracking(2.52) // .24em at 10.5pt
            .foregroundStyle(PaperTokens.inkDim)
            GeometryReader { geo in
                let fraction: CGFloat = total > 0 ? CGFloat(filled) / CGFloat(total) : 0
                ZStack(alignment: .leading) {
                    Rectangle().fill(PaperTokens.rule).frame(height: 1)
                    Rectangle().fill(model.personaTint)
                        .frame(width: geo.size.width * fraction, height: 1)
                        .animation(.easeOut(duration: 0.3), value: filled)
                }
            }
            .frame(height: 1)
        }
        .padding(.horizontal, Spacing.deckMargin)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.sm)
    }

    @ViewBuilder
    private func cardView(_ candidate: SwipeCandidate) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let dayLabel {
                    Text(dayLabel)
                        .font(.custom(sansName, size: 10))
                        .tracking(4.2) // .42em at 10pt
                        .foregroundStyle(model.personaTint)
                }
                Spacer()
                if candidate.isUpdated {
                    Text("已依「\(candidate.modifyNote ?? "你的要求")」改過")
                        .font(.custom(sansName, size: 9.5))
                        .foregroundStyle(PaperTokens.inkDim)
                }
            }
            Rectangle()
                .fill(PaperTokens.stockAlt)
                .frame(height: 130) // photo plate — hatched placeholder per handoff Assets note
                .overlay(Text("料理照片").font(.custom(sansName, size: 10)).foregroundStyle(PaperTokens.inkFaint))
                .padding(.top, dayLabel == nil ? 0 : 10)
            Text(candidate.dishText)
                .font(.custom(serifName, size: 28))
                .foregroundStyle(PaperTokens.ink)
                .padding(.top, 14)
            if let meta = candidate.meta {
                Text(meta)
                    .font(.custom(sansName, size: 10.5))
                    .tracking(2.1)
                    .foregroundStyle(PaperTokens.inkDim)
                    .padding(.top, 4)
            }
            Rectangle().fill(PaperTokens.rule).frame(height: 1).padding(.vertical, 12)
            if let pitch = candidate.pitch {
                Text(pitch)
                    .font(.custom(serifName, size: 13.5).italic())
                    .lineSpacing(13.5) // lh 2.0
                    .foregroundStyle(PaperTokens.inkDim)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PaperTokens.slip)
        .overlay(stampOverlay)
    }

    @ViewBuilder
    private var stampOverlay: some View {
        let opacity = stampOpacity(dragWidth: dragOffset.width)
        if dragOffset.width > 8 {
            stamp("排入", color: model.personaTint).opacity(opacity)
        } else if dragOffset.width < -8 {
            stamp("換道", color: PaperTokens.ink).opacity(opacity)
        }
    }

    private func stamp(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.custom(sansName, size: 22))
            .foregroundStyle(color)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .overlay(Rectangle().stroke(color, lineWidth: 2))
            .rotationEffect(.degrees(color == model.personaTint ? -12 : 12))
    }

    private func dragGesture(for candidate: SwipeCandidate) -> some Gesture {
        DragGesture()
            .updating($dragOffset) { value, state, _ in state = value.translation }
            .onEnded { value in
                guard let direction = swipeDirection(dragWidth: value.translation.width,
                                                     dragHeight: value.translation.height) else { return }
                if direction == .modify {
                    showModifyPanel = true
                } else {
                    onSwipe(candidate, direction)
                }
            }
    }

    private var footerBar: some View {
        HStack(spacing: 0) {
            footerButton("換一道") {
                if let current = candidates.first { onSwipe(current, .pass) }
            }
            Rectangle().fill(PaperTokens.rule).frame(width: 1)
            footerButton("但是…") { showModifyPanel = true }
                .frame(width: 78)
            Rectangle().fill(PaperTokens.rule).frame(width: 1)
            footerButton("排入這天", emphasized: true) {
                if let current = candidates.first { onSwipe(current, .like) }
            }
        }
        .frame(height: 50)
        .overlay(Rectangle().stroke(PaperTokens.rule, lineWidth: 1))
        .padding(.horizontal, Spacing.deckMargin)
        .padding(.vertical, Spacing.md)
    }

    private func footerButton(_ title: String, emphasized: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.custom(sansName, size: 12.5))
                .fontWeight(emphasized ? .semibold : .regular)
                .foregroundStyle(emphasized ? model.personaTint : PaperTokens.ink)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
    }

    private func modifyPanel(_ candidate: SwipeCandidate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("但是…")
                .font(.custom(serifName, size: 15))
                .foregroundStyle(model.personaTint)
            TextField("像是「沒有蝦」「想要辣一點」", text: $modifyText)
                .font(.custom(sansName, size: 13.5))
                .padding(.bottom, 6)
                .overlay(Rectangle().fill(PaperTokens.ink.opacity(0.34)).frame(height: 1), alignment: .bottom)
            Text("不用等 —— 牌繼續發,改好了它會再出現一次。")
                .font(.custom(sansName, size: 10.5).weight(.light))
                .foregroundStyle(PaperTokens.inkDim)
            HStack {
                Button("取消") { showModifyPanel = false; modifyText = "" }
                    .font(.custom(sansName, size: 12.5))
                    .frame(minHeight: 44)
                Spacer()
                Button("交給小當家改") {
                    guard !modifyText.isEmpty else { return }
                    onModifyNote(candidate, modifyText)
                    showModifyPanel = false
                    modifyText = ""
                }
                .font(.custom(sansName, size: 12.5)).fontWeight(.semibold)
                .foregroundStyle(model.personaTint)
                .frame(minHeight: 44)
            }
        }
        .padding(16)
        .background(PaperTokens.stock)
        .overlay(Rectangle().fill(model.personaTint).frame(height: 2), alignment: .top)
        .padding(.horizontal, Spacing.deckMargin)
        .padding(.bottom, Spacing.md)
    }
}
