import Foundation

/// Counts completed cook sessions for a specific recipe — "cooked N times" (verdict
/// history's sibling stat). A session only counts once `completedAt` is set; an
/// in-progress or abandoned session (started but never finished) doesn't count.
func cookCount(sessions: [CookSession], recipeId: UUID) -> Int {
    sessions.filter { $0.recipeId == recipeId && $0.completedAt != nil }.count
}

/// True at the 3rd and 5th cook, then every 10th (10, 20, 30, ...) — the moments
/// worth a persona reaction instead of a plain count line.
func isMilestone(_ count: Int) -> Bool {
    count == 3 || count == 5 || (count >= 10 && count % 10 == 0)
}

/// Substitutes the cook count into the milestone reaction template — the first
/// placeholder-style copy_pack key in this codebase (existing keys are static
/// strings). Kept to this single `{n}` substitution rather than building general
/// templating machinery for one use.
func milestoneReactionText(count: Int, template: String?) -> String {
    let fallback = "哇,這是你第 {n} 次做這道菜了!越來越上手了呢 🔥"
    return (template ?? fallback).replacingOccurrences(of: "{n}", with: "\(count)")
}
