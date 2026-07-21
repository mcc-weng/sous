import Foundation

/// Client-side title search — case-insensitive substring match. No full-text search
/// infra needed at v1 recipe-count scale.
func filteredRecipes(_ recipes: [Recipe], query: String) -> [Recipe] {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return recipes }
    return recipes.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
}
