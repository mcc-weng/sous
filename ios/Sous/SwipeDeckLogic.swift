import Foundation

/// One swipeable candidate — an Explore Deck recipe, a ritual day's proposal, or a
/// recipe_tweak re-entry. `id` is ephemeral client-session state, not a DB row id.
struct SwipeCandidate: Identifiable, Equatable {
    let id: UUID
    let recipeId: UUID?
    let dishText: String
    let mode: String?
    let meta: String?
    let pitch: String?
    let prepNote: String?
    var shoppingItems: [SwipeShoppingItem] = []
    var isUpdated: Bool = false
    /// The 但是… note this candidate was revised with, set by whoever reinserts it
    /// (Tasks 4/7) so `SwipeCardStack`'s "已依「...」改過" badge can display the actual
    /// note instead of falling back to generic text or leaking another candidate's
    /// in-progress, unsaved `modifyText`.
    var modifyNote: String? = nil
}

/// Mirrors `ShoppingItem`'s name/qty/section shape minus `id`/`checked`, which don't
/// exist until `set-plan` actually inserts a row — see `state_api.set_plan`'s
/// `--shopping-items` JSON shape, which this maps onto directly at lock (Task 7).
struct SwipeShoppingItem: Codable, Equatable {
    let name: String
    let qty: String?
    let section: String?
}

enum SwipeDirection: Equatable {
    case like, pass, modify
}

/// README B1: "Release past ±80pt commits; otherwise springs back." Diagonal drags
/// resolve to whichever axis is furthest past its own threshold, so a mostly-vertical
/// drag with a little horizontal drift still reads as modify, and vice versa.
func swipeDirection(dragWidth: CGFloat, dragHeight: CGFloat,
                    commitThreshold: CGFloat = 80) -> SwipeDirection? {
    let horizontalPast = abs(dragWidth) - commitThreshold
    let verticalPast = (-dragHeight) - commitThreshold // up is negative dragHeight
    guard horizontalPast > 0 || verticalPast > 0 else { return nil }
    if horizontalPast >= verticalPast {
        return dragWidth > 0 ? .like : .pass
    }
    return .modify
}

/// README B1: "rotate(dx × 0.05deg)".
func cardRotation(dragWidth: CGFloat) -> Double {
    Double(dragWidth) * 0.05
}

/// README B1: stamp "opacity bound to |dx| / 80".
func stampOpacity(dragWidth: CGFloat, commitThreshold: CGFloat = 80) -> Double {
    min(abs(Double(dragWidth)) / Double(commitThreshold), 1)
}

/// Deck session state — held in a view's `@State`, mutated by swipe actions.
/// `pendingReinserts` models mechanics spec §2.3: a swipe-up note never blocks the
/// deck; the revised card surfaces a few cards later, tagged `isUpdated`.
struct SwipeDeckState {
    var candidates: [SwipeCandidate]
    private(set) var pendingReinserts: [(afterCount: Int, candidate: SwipeCandidate)]
    private var advancedCount = 0

    init(candidates: [SwipeCandidate], pendingReinserts: [(afterCount: Int, candidate: SwipeCandidate)]) {
        self.candidates = candidates
        self.pendingReinserts = pendingReinserts
    }

    var current: SwipeCandidate? { candidates.first }

    @discardableResult
    mutating func advance() -> SwipeCandidate? {
        guard !candidates.isEmpty else { return nil }
        let popped = candidates.removeFirst()
        advancedCount += 1
        let due = pendingReinserts.filter { $0.afterCount <= advancedCount }
        pendingReinserts.removeAll { $0.afterCount <= advancedCount }
        for entry in due {
            var tagged = entry.candidate
            tagged.isUpdated = true
            candidates.insert(tagged, at: 0)
        }
        return popped
    }

    mutating func scheduleReinsert(_ candidate: SwipeCandidate, afterCards: Int = 3) {
        pendingReinserts.append((afterCount: advancedCount + afterCards, candidate: candidate))
    }
}
