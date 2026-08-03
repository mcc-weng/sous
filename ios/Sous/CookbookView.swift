// ios/Sous/CookbookView.swift
import SwiftUI

/// D2 · 食譜本 (cookbook) — Reference: design_handoff_sous_m3/README.md "D2 · 食譜本
/// (cookbook)" and `Sous App v2.dc.html` lines 560-594.
///
/// "A table of contents, not a card grid" — the mock's core reframe. Search field,
/// filter chips, then rows: folio number + dish name (serif) + a meta line, in place
/// of the old `LazyVGrid` card layout. Still driven by the same `filteredRecipes`
/// (CookbookLogic.swift, untouched) and the same `NavigationLink(value:)` →
/// `.navigationDestination(for: Recipe.self)` push to `RecipeDetailView` (also
/// untouched) — this is a different `View` body over the same data and navigation,
/// not new logic.
///
/// Scope note — chapter grouping: the mock groups rows into ingredient-based chapters
/// (家常 · 雞, 家常 · 豆腐, 麵 · 飯 — seal-tint labels). `Recipe` (Models.swift) carries
/// no structured category/tag/cuisine field anywhere in the schema — `ingredients` is
/// freeform text parsed from whatever a shared recipe link/photo contained, not a
/// curated taxonomy, and nothing else classifies a recipe by dish type. Inventing
/// chapter labels here would mean fabricating data that doesn't exist. This instead
/// renders a flat table of contents — still folio-numbered, still row-per-recipe —
/// ordered alphabetically (Chinese-locale-aware) for a stable "book order" rather than
/// raw fetch order. That's the "grouping by nothing" simplification the task brief
/// names as acceptable when no real grouping key exists.
///
/// Scope note — filter chips: the mock shows 全部/神作/三十分內/還沒煮過 as tappable
/// chips, and the task brief's acceptance criteria names "filter chips" as a required
/// visual element, so this renders all four. But only one is honestly wireable: 神作
/// needs verdict data, and this screen has none loaded across the whole book —
/// `RecipeDetailView` only fetches verdicts for one recipe at a time (a
/// `plan_days`-joined query), and repeating that per row here would be an N+1 fetch
/// across the whole list, i.e. new data-fetching, out of a restyle's scope. 三十分內
/// needs a prep-duration field `Recipe` doesn't have at all — no amount of local
/// computation can derive it. 還沒煮過 (cookCount == 0) *is* derivable from data
/// already loaded here, but wiring only one of four chips live would be a worse,
/// inconsistent affordance than wiring none — three dead taps next to one live one,
/// with no visual distinction between them. So the whole row stays decorative this
/// pass: visually matches the mock, but no chip changes the list on tap yet.
///
/// Scope note — row meta line: the mock's second column reads "attempts · verdict"
/// (e.g. `五次 · 神作`). Verdict text isn't available at this screen for the reason
/// above, so the meta line here is cook-count only — `N次` from `cookCount` (existing,
/// `model.cookSessions`, already loaded by `loadCookbook`), or `還沒煮` at zero. No
/// fabricated verdict suffix.
///
/// Scope note — closing line: the mock's footer reads "頁碼是這本書自己長出來的 ——
/// 你煮過的菜,我就替你編一頁。" — persona-voice flavour text, not present in
/// `copy_pack` (the brief's two new keys for this task are `book_title` and
/// `empty_book` only; `book_title` doesn't appear anywhere in this canvas section — the
/// live `Sous App v2.dc.html` D2 header is a plain `食譜本 / 十四 道` label — so it isn't
/// used here). Adding a new copy_pack key/migration is backend work outside a view
/// restyle, and hardcoding persona-voice prose directly would violate the persona
/// discipline rule (voice must flow through `copy_pack`). This omits the closing line
/// rather than fabricate it.
struct CookbookView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""

    private var serifName: String { serifFontName(bundled: FontBook.isSerifBundled) }
    private var sansName: String { sansFontName(bundled: FontBook.isSansBundled) }

    /// The whole book, alphabetically ordered (Chinese-locale-aware) — the "grouping
    /// by nothing" fallback documented above. Folio numbers are drawn from *this* full
    /// list, not the search-filtered one, so a recipe's page number is a fixed fact
    /// about the book and doesn't renumber just because a search narrows the visible
    /// rows (mirrors the mock's folios reading as a persistent page reference, reused
    /// on C4's verdict screen per the README).
    private var fullOrderedRecipes: [Recipe] {
        model.recipes.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// `recipe.id` → 1-based folio position in `fullOrderedRecipes`.
    private var folioByRecipeID: [Recipe.ID: Int] {
        Dictionary(uniqueKeysWithValues: fullOrderedRecipes.enumerated().map { ($1.id, $0 + 1) })
    }

    /// The rows actually displayed — search-filtered (via the existing, unchanged
    /// `filteredRecipes`), same alphabetical order as the full book.
    private var orderedRecipes: [Recipe] {
        filteredRecipes(model.recipes, query: query)
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    searchField
                    filterChips
                    contents
                }
                .padding(.horizontal, Spacing.pageMargin)
                .padding(.top, Spacing.md)
                .padding(.bottom, Spacing.lg)
            }
            .background(PaperTokens.stock)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Recipe.self) { recipe in
                RecipeDetailView(recipe: recipe)
            }
        }
        .task { await model.loadCookbook() }
    }

    // MARK: Running head

    /// "食譜本 / 十四 道" — mirrors `WeekBoardView.runningHead`'s label + hairline-rule
    /// shape. The count is the whole book (`model.recipes`), not the search-filtered
    /// count, matching the mock (the count sits above the search field).
    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("食譜本")
                Spacer()
                Text("\(chineseNumeral(model.recipes.count)) 道")
            }
            .font(.custom(sansName, size: 10))
            .tracking(3.4) // .34em at 10pt
            .foregroundStyle(PaperTokens.inkFaint)
            Rectangle()
                .fill(PaperTokens.rule)
                .frame(height: 1)
                .padding(.top, 10)
        }
    }

    // MARK: Search

    /// Replaces the old `.searchable` system search bar with an in-content bordered
    /// field matching the mock's plain box — same `$query` binding into
    /// `filteredRecipes`, purely a presentation change.
    private var searchField: some View {
        TextField("搜尋食譜", text: $query)
            .textFieldStyle(.plain)
            .font(.custom(sansName, size: 12.5).weight(.light))
            .foregroundStyle(PaperTokens.ink)
            .padding(.vertical, 11)
            .padding(.horizontal, 15)
            .overlay(Rectangle().stroke(PaperTokens.ink.opacity(0.26), lineWidth: 1))
            .padding(.top, 18)
    }

    // MARK: Filter chips (decorative — see file-header scope note)

    private var filterChips: some View {
        HStack(spacing: 7) {
            filterChip("全部", selected: true)
            filterChip("神作", selected: false)
            filterChip("三十分內", selected: false)
            filterChip("還沒煮過", selected: false)
        }
        .padding(.top, 14)
    }

    private func filterChip(_ label: String, selected: Bool) -> some View {
        Text(label)
            .font(.custom(sansName, size: 11))
            .tracking(0.66) // .06em at 11pt
            .foregroundStyle(selected ? PaperTokens.stock : PaperTokens.inkDim)
            .padding(.vertical, selected ? 7 : 6)
            .padding(.horizontal, selected ? 12 : 11)
            .background {
                if selected {
                    Rectangle().fill(PaperTokens.ink)
                } else {
                    Rectangle().stroke(PaperTokens.ink.opacity(0.24), lineWidth: 1)
                }
            }
    }

    // MARK: Table of contents

    @ViewBuilder
    private var contents: some View {
        if model.recipes.isEmpty {
            emptyState(model.personaCopy["empty_book"] ?? "這本書還沒有第一道菜")
        } else if orderedRecipes.isEmpty {
            // A search with no matches — distinct from an empty book. Plain neutral UI
            // copy (not persona voice), same precedent as the hardcoded "搜尋食譜"
            // placeholder above.
            emptyState("沒有符合的食譜")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(orderedRecipes) { recipe in
                    NavigationLink(value: recipe) {
                        recipeRow(recipe, folio: folioByRecipeID[recipe.id] ?? 0)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 20)
        }
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.custom(serifName, size: 14))
            .foregroundStyle(PaperTokens.inkDim)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 40)
    }

    /// One row: folio number (seal/persona-tint, 24pt column) + dish name (serif) +
    /// meta line (trailing, `inkDim`). Mirrors the mock's flex row exactly, minus the
    /// chapter grouping it sits under there (see file-header scope note).
    private func recipeRow(_ recipe: Recipe, folio: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(folioText(folio))
                .font(.custom(sansName, size: 11))
                .foregroundStyle(model.personaTint)
                .frame(width: 24, alignment: .leading)
            Text(recipe.title)
                .font(.custom(serifName, size: 15))
                .foregroundStyle(PaperTokens.ink)
                .lineLimit(2)
            Spacer(minLength: 8)
            Text(rowMeta(recipe))
                .font(.custom(sansName, size: 10.5))
                .foregroundStyle(PaperTokens.inkDim)
                .lineLimit(1)
        }
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }

    /// Cook-count only — see file-header scope note on why the verdict half of the
    /// mock's "五次 · 神作" meta line isn't reproduced.
    private func rowMeta(_ recipe: Recipe) -> String {
        let count = cookCount(sessions: model.cookSessions, recipeId: recipe.id)
        return count > 0 ? "\(chineseNumeral(count))次" : "還沒煮"
    }

    private static let folioDigits = ["〇", "一", "二", "三", "四", "五", "六", "七", "八", "九"]

    /// Folios read like page numbers — digit-by-digit ("二三" for 23) — not the
    /// cardinal grammar `chineseNumeral` (CounterView.swift) uses for spoken counts
    /// like dates or the header's "十四 道" ("fourteen dishes"). Matches the mock's own
    /// folio style (二三/二七/三一/四二/四五) and keeps every folio a fixed
    /// glyph-per-digit width, so it can't overflow the 24pt folio column the way a
    /// 3-glyph cardinal reading ("二十三") could for any recipe count ≥ 20.
    private func folioText(_ n: Int) -> String {
        guard n > 0 else { return "\(n)" }
        return String(n).compactMap { $0.wholeNumberValue.map { Self.folioDigits[$0] } }.joined()
    }
}
