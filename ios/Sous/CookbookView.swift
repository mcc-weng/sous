// ios/Sous/CookbookView.swift
import SwiftUI

private let cookbookGridColumns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

struct CookbookView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: cookbookGridColumns, spacing: 12) {
                    ForEach(filteredRecipes(model.recipes, query: query)) { recipe in
                        NavigationLink(value: recipe) {
                            recipeCard(recipe)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .searchable(text: $query, prompt: "搜尋食譜")
            .navigationDestination(for: Recipe.self) { recipe in
                RecipeDetailView(recipe: recipe)
            }
            .navigationTitle("食譜本")
        }
        .task { await model.loadCookbook() }
    }

    private func recipeCard(_ recipe: Recipe) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(recipe.title).font(.headline).lineLimit(2)
            Text("\(recipe.ingredients.count) 項食材 · \(recipe.steps.count) 個步驟")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
