import Foundation

/// Client-side title search — case-insensitive substring match. No full-text search
/// infra needed at v1 recipe-count scale.
func filteredRecipes(_ recipes: [Recipe], query: String) -> [Recipe] {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return recipes }
    return recipes.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
}

private let folioDigits = ["〇", "一", "二", "三", "四", "五", "六", "七", "八", "九"]

/// Folios read like page numbers — digit-by-digit ("二三" for 23), not the cardinal
/// grammar `chineseNumeral` (CounterView.swift) uses for spoken counts. Shared between
/// `CookbookView` (D2, every row) and `RecipeDetailView` (D1, the one recipe it shows).
func folioText(_ n: Int) -> String {
    guard n > 0 else { return "\(n)" }
    return String(n).compactMap { $0.wholeNumberValue.map { folioDigits[$0] } }.joined()
}
