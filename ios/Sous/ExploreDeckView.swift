import SwiftUI

/// D3 · 探索牌組 — Reference: design_handoff_sous_m3/README.md "D3 · 探索牌組".
/// Client-only: candidates come from already-loaded `model.recipes`, no brain job for
/// ordinary browsing (only swipe-up fires one — see the 但是… wiring below, which
/// reuses the exact same recipe_tweak job Task 7's Ritual Session uses, Task 5).
struct ExploreDeckView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var deck = SwipeDeckState(candidates: [], pendingReinserts: [])

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("探索牌組").font(.custom(serifFontName(bundled: FontBook.isSerifBundled), size: 17))
                Spacer()
                Button("關閉") { dismiss() }
                    .frame(minWidth: 44, minHeight: 44)
            }
            .padding(.horizontal, Spacing.pageMargin)
            .padding(.top, Spacing.md)

            if deck.candidates.isEmpty {
                Spacer()
                Text("這批牌先看完了").foregroundStyle(PaperTokens.inkDim)
                Spacer()
            } else {
                SwipeCardStack(
                    candidates: deck.candidates, dayLabel: nil,
                    progressFilled: nil, progressTotal: nil,
                    onSwipe: { candidate, direction in handleSwipe(candidate, direction) },
                    onModifyNote: { candidate, note in handleModify(candidate, note) }
                )
            }
        }
        .background(PaperTokens.stock)
        .task {
            let recentlyPassed = await model.recentPassedRecipeIds(context: "explore")
            deck.candidates = exploreCandidates(recipes: model.recipes, recentlyPassed: recentlyPassed)
        }
    }

    private func handleSwipe(_ candidate: SwipeCandidate, _ direction: SwipeDirection) {
        deck.advance()
        guard let recipeId = candidate.recipeId else { return }
        let action = direction == .like ? "like" : "pass"
        Task { await model.recordSwipe(recipeId: recipeId, dishText: nil, action: action,
                                       context: "explore", note: nil) }
    }

    private func handleModify(_ candidate: SwipeCandidate, _ note: String) {
        deck.advance()
        guard let recipeId = candidate.recipeId else { return }
        Task {
            await model.recordSwipe(recipeId: recipeId, dishText: nil, action: "modify",
                                    context: "explore", note: note)
            if let revised = await model.requestRecipeTweak(originRecipeId: recipeId,
                                                             originDishText: candidate.dishText,
                                                             note: note, context: "explore", date: nil) {
                deck.scheduleReinsert(revised)
            }
        }
    }
}

/// Pure — testable without a live `AppModel`. `recentlyPassed` excludes cards the
/// user already rejected today; the exact decay window is left to planning per the
/// design spec §9, same-day is a reasonable, cheap default.
func exploreCandidates(recipes: [Recipe], recentlyPassed: Set<UUID>) -> [SwipeCandidate] {
    recipes
        .filter { !recentlyPassed.contains($0.id) }
        .shuffled() // brief prose: candidates come from model.recipes "shuffled" — a
        // browse deck showing recipes in the same created_at DESC order every open
        // isn't really "explore." No test asserts order (both multi-element cases
        // reduce to ≤1 item after filtering), so this is safe to add.
        .map { SwipeCandidate(id: UUID(), recipeId: $0.id, dishText: $0.title,
                              mode: nil, meta: nil, pitch: nil, prepNote: nil) }
}
