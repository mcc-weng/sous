// ios/Sous/RecipeDetailView.swift
import SwiftUI

struct RecipeDetailView: View {
    let recipe: Recipe
    @EnvironmentObject private var model: AppModel
    @State private var verdicts: [Verdict] = []
    @State private var showCookMode = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let sourceBlock = recipe.sourceBlock {
                    GroupBox("📌 原始食譜") {
                        Text(sourceBlock).font(.caption)
                    }
                }
                GroupBox("食材") {
                    ForEach(recipe.ingredients, id: \.name) { ingredient in
                        HStack {
                            Text(ingredient.name)
                            Spacer()
                            if let qty = ingredient.qty {
                                Text(qty).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                GroupBox("步驟") {
                    ForEach(Array(recipe.steps.enumerated()), id: \.offset) { index, step in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(index + 1). \(step.text)")
                            if let tip = step.tip {
                                Text(tip).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                if let latest = verdicts.first {
                    GroupBox("上次煮 · \(relativeDateString(latest.createdAt))") {
                        ForEach(verdicts) { verdict in
                            HStack {
                                Text(verdict.rating)
                                if let note = verdict.note {
                                    Text(note).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(relativeDateString(verdict.createdAt))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                let cookedCount = cookCount(sessions: model.cookSessions, recipeId: recipe.id)
                if cookedCount > 0 {
                    Text("已煮 \(cookedCount) 次")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("開始煮") { showCookMode = true }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            }
            .padding()
        }
        .navigationTitle(recipe.title)
        .task { await loadVerdicts() }
        .fullScreenCover(isPresented: $showCookMode) {
            CookModeView(recipe: recipe, planDay: nil).environmentObject(model)
        }
    }

    private func loadVerdicts() async {
        struct VerdictRow: Decodable {
            let id: UUID
            let rating: String
            let note: String?
            let createdAt: Date
            enum CodingKeys: String, CodingKey {
                case id, rating, note
                case createdAt = "created_at"
            }
        }
        do {
            // Verdicts reference plan_day_id, not recipe_id — this is a PostgREST
            // embedded-resource filter joining through plan_days.recipe_id.
            let rows: [VerdictRow] = try await model.client.from("verdicts")
                .select("id,rating,note,created_at,plan_days!inner(recipe_id)")
                .eq("plan_days.recipe_id", value: recipe.id)
                .order("created_at", ascending: false)
                .execute().value
            verdicts = rows.map { Verdict(id: $0.id, rating: $0.rating, note: $0.note, createdAt: $0.createdAt) }
        } catch { print("verdict history load: \(error)") }
    }
}

func relativeDateString(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = Locale(identifier: "zh_Hant")
    return formatter.localizedString(for: date, relativeTo: Date())
}
