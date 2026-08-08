// ios/Sous/RecipeDetailView.swift
import SwiftUI

/// D1 · 食譜 (recipe — where 邊欄 lives) — Reference: design_handoff_sous_m3/README.md
/// "D1 · 食譜 (recipe — where 邊欄 lives)" and `Sous App v2.dc.html` lines 481-558,
/// **excluding** the 邊欄 exchange block (533-541 — `ChatMessage` has no `recipe_id`,
/// wiring it up is Pass 2 territory). The 份量 servings stepper + unit toggle (Task 9)
/// are wired: ingredient quantities are rescaled live via `displayQuantity(...)`
/// (`RecipeScalingLogic.swift`, Task 5). The photo slot uses `RecipePhotoCarousel`
/// (Task 7, tap-to-advance placeholder photos), and a 拷貝/列印 icon row (Task 10, new —
/// not in the mockup) copies/shares the current-serving ingredient list + steps as
/// plain text via `UIPasteboard`/`ShareLink`.
///
/// Scope note — running head left slot: the mock's left slot shows a fabricated
/// ingredient-based category (`家常 · 雞`) that doesn't exist anywhere in `Recipe`'s
/// schema — the same data gap `CookbookView` hit and resolved by omitting the
/// fabricated label (see that file's header note). This omits the left slot too,
/// showing only the folio, right-aligned.
///
/// Scope note — seal "第 X 道" numeral: reuses that *same* folio number — there's no
/// second, distinct "dish number" concept anywhere in the data model, so inventing one
/// would fabricate data the same way a chapter label would. Read cardinally via
/// `chineseNumeral` (`CounterView.swift`) rather than digit-by-digit like the folio
/// itself (`folioText`, Task 6).
///
/// Scope note — description text: `Recipe` has no separate description field. This
/// reuses `bodyMd` (free-text "整體心得/秘訣" content, the closest existing field),
/// shown only when non-empty.
///
/// Scope note — native nav bar: `CookbookView` already resolved the redundant
/// system-chrome-over-printed-page problem for itself with
/// `.toolbar(.hidden, for: .navigationBar)`; this view is pushed as a child of that
/// same `NavigationStack`, so it applies the same modifier and drops
/// `.navigationTitle(...)` — edge-swipe-to-pop still works with the bar hidden.
struct RecipeDetailView: View {
    let recipe: Recipe
    @EnvironmentObject private var model: AppModel
    @State private var verdicts: [Verdict] = []
    @State private var showCookMode = false
    @State private var currentServings: Int
    @State private var unitSystem: UnitSystem = .metric
    @State private var showCopyToast = false

    init(recipe: Recipe) {
        self.recipe = recipe
        _currentServings = State(initialValue: recipe.servings)
    }

    private var serifName: String { serifFontName(bundled: FontBook.isSerifBundled) }
    private var sansName: String { sansFontName(bundled: FontBook.isSansBundled) }

    /// 1-based position of `recipe` in the whole book, alphabetically ordered
    /// (Chinese-locale-aware) — same computation as `CookbookView.fullOrderedRecipes` /
    /// `folioByRecipeID`, so this recipe's folio always agrees with its row there.
    private var folio: Int {
        let ordered = model.recipes.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        return ordered.firstIndex { $0.id == recipe.id }.map { $0 + 1 } ?? 0
    }

    private var cookedCount: Int {
        cookCount(sessions: model.cookSessions, recipeId: recipe.id)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                sealAndTitle
                iconRow
                RecipePhotoCarousel(
                    accentColor: model.personaTint,
                    photoPaths: cookPhotoPaths(sessions: model.cookSessions, recipeId: recipe.id),
                    loadImage: { path in await model.downloadPhoto(path: path) }
                )
                    .padding(.top, 24)
                servingsBand
                ingredientsSection
                stepsSection
                if !verdicts.isEmpty {
                    recordSection
                }
                if cookedCount > 0 {
                    Text("已煮 \(chineseNumeral(cookedCount)) 次")
                        .font(.custom(sansName, size: 10.5))
                        .foregroundStyle(PaperTokens.inkDim)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 22)
                }
            }
            .padding(.horizontal, Spacing.pageMargin)
            .padding(.top, Spacing.md)
        }
        .background(PaperTokens.stock)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom) { footer }
        .task { await loadVerdicts() }
        .fullScreenCover(isPresented: $showCookMode) {
            CookModeView(recipe: recipe, planDay: nil).environmentObject(model)
        }
        .overlay(alignment: .top) {
            if showCopyToast {
                Text("已拷貝")
                    .font(.custom(sansName, size: 11))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(PaperTokens.ink)
                    .foregroundStyle(PaperTokens.stock)
                    .padding(.top, 8)
                    .task {
                        try? await Task.sleep(for: .seconds(1.5))
                        showCopyToast = false
                    }
            }
        }
    }

    // MARK: Running head

    /// Folio only, right-aligned — see file-header scope note on omitting the
    /// fabricated left-slot category label. Mirrors `CookbookView.header`'s
    /// hairline-rule-below shape.
    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Text(folioText(folio))
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

    // MARK: Seal, title, rule, description

    private var sealAndTitle: some View {
        VStack(spacing: 0) {
            Text("第 \(chineseNumeral(folio)) 道")
                .font(.custom(sansName, size: 10))
                .tracking(5) // .5em at 10pt
                .foregroundStyle(model.personaTint)
            Text(recipe.title)
                .font(.custom(serifName, size: 31))
                .tracking(1.55) // .05em at 31pt
                .lineSpacing(6.8) // lh 1.42 at 31pt: (1.42 - 1.2) * 31
                .foregroundStyle(PaperTokens.ink)
                .multilineTextAlignment(.center)
                .padding(.top, 16)
            Rectangle()
                .fill(PaperTokens.ink.opacity(0.28))
                .frame(width: 22, height: 1)
                .padding(.top, 18)
            let body = recipe.bodyMd.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                Text(body)
                    .font(.custom(serifName, size: 13.5))
                    .lineSpacing(12.8) // lh 2.15 at 13.5pt: (2.15 - 1.2) * 13.5
                    .foregroundStyle(PaperTokens.inkDim)
                    .multilineTextAlignment(.center)
                    .padding(.top, 18)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 26)
    }

    // MARK: 拷貝 / 列印 icon row

    /// New, not in the mockup (design spec) — top-trailing of the title/description
    /// block, above the photo carousel, so it doesn't collide with any mocked element.
    /// Copies/shares the current-serving ingredient list + steps as plain text.
    private var iconRow: some View {
        HStack(spacing: 18) {
            Spacer()
            Button {
                UIPasteboard.general.string = formattedRecipeText()
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.success)
                showCopyToast = true
            } label: {
                Label("拷貝", systemImage: "doc.on.doc")
                    .font(.custom(sansName, size: 11))
                    .foregroundStyle(PaperTokens.inkDim)
            }
            .frame(minWidth: 44, minHeight: 44)
            ShareLink(item: formattedRecipeText()) {
                Label("列印", systemImage: "printer")
                    .font(.custom(sansName, size: 11))
                    .foregroundStyle(PaperTokens.inkDim)
            }
            .frame(minWidth: 44, minHeight: 44)
        }
        .padding(.top, 20)
    }

    /// Plain-text rendering of the current-serving ingredient list + steps, shared by
    /// both the 拷貝 (clipboard) and 列印 (`ShareLink`) actions — reuses
    /// `displayQuantity(...)` (Task 5) so the copied/shared text always matches what's
    /// on screen for the selected servings + unit system.
    private func formattedRecipeText() -> String {
        var lines = [recipe.title, ""]
        lines.append("食材（\(currentServings) 人份）")
        for ingredient in recipe.ingredients {
            let qty = displayQuantity(ingredient: ingredient, currentServings: currentServings,
                                      baseServings: recipe.servings, unitSystem: unitSystem)
            lines.append(qty.isEmpty ? ingredient.name : "\(ingredient.name)　\(qty)")
        }
        lines.append("")
        lines.append("作法")
        for (i, step) in recipe.steps.enumerated() {
            lines.append("\(i + 1). \(step.text)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: 份量 (servings stepper)

    /// Ruled band matching README D1's 份量 stepper shape — `−`/value/`+` with
    /// seal-tint buttons. View-local only: `currentServings` never writes back to the
    /// server, it just drives `displayQuantity(...)` below. Floors at 1 per the design
    /// spec's rescale rules never producing a value below that.
    private var servingsBand: some View {
        HStack(alignment: .center) {
            Text("份量")
                .font(.custom(sansName, size: 10))
                .tracking(3.2)
                .foregroundStyle(PaperTokens.inkFaint)
            Spacer()
            Button {
                if currentServings > 1 { currentServings -= 1 }
            } label: {
                Text("−").font(.system(size: 19)).foregroundStyle(model.personaTint)
            }
            .frame(minWidth: 44, minHeight: 44)
            Text("\(currentServings) 人份")
                .font(.custom(serifName, size: 16))
                .monospacedDigit()
                .frame(minWidth: 58)
            Button {
                currentServings += 1
            } label: {
                Text("+").font(.system(size: 19)).foregroundStyle(model.personaTint)
            }
            .frame(minWidth: 44, minHeight: 44)
        }
        .padding(.vertical, 14)
        .overlay(Rectangle().stroke(PaperTokens.rule, lineWidth: 1).frame(height: 1), alignment: .top)
        .overlay(Rectangle().stroke(PaperTokens.rule, lineWidth: 1).frame(height: 1), alignment: .bottom)
    }

    /// Small text toggle (公制/英制) — no mockup for this (design spec: designed
    /// fresh). Kept visually distinct from the 份量 band so that band still matches the
    /// mockup exactly; this sits beside the 食材 heading instead.
    private var unitToggle: some View {
        Button {
            unitSystem = (unitSystem == .metric) ? .imperial : .metric
        } label: {
            Text(unitSystem == .metric ? "公制" : "英制")
                .font(.custom(sansName, size: 10.5))
                .tracking(1.5)
                .foregroundStyle(PaperTokens.inkDim)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .overlay(Rectangle().stroke(PaperTokens.ink.opacity(0.24), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
    }

    // MARK: 食材 (ingredients)

    private var ingredientsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("食　材")
                .overlay(alignment: .trailing) { unitToggle }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(recipe.ingredients, id: \.name) { ingredient in
                    ingredientRow(ingredient)
                }
            }
            .padding(.top, 16)
        }
        .padding(.top, 24)
    }

    /// Name + dotted leader + rescaled/converted quantity — `displayQuantity(...)`
    /// (Task 5) applies the current servings + unit-system state per ingredient,
    /// falling back to the free-text `ingredient.qty` unchanged when there's no
    /// structured quantity to work with.
    private func ingredientRow(_ ingredient: Ingredient) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(ingredient.name)
                .font(.custom(serifName, size: 14))
                .foregroundStyle(PaperTokens.ink)
            dottedLeader
            Text(displayQuantity(ingredient: ingredient, currentServings: currentServings,
                                 baseServings: recipe.servings, unitSystem: unitSystem))
                .font(.custom(serifName, size: 14))
                .foregroundStyle(PaperTokens.inkDim)
                .monospacedDigit()
        }
        .padding(.top, 12)
    }

    private var dottedLeader: some View {
        GeometryReader { geo in
            Path { path in
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: geo.size.width, y: 0))
            }
            .stroke(PaperTokens.leader, style: StrokeStyle(lineWidth: 1, dash: [1, 3]))
        }
        .frame(height: 1)
    }

    // MARK: 作法 (steps)

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("作　法")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(recipe.steps.enumerated()), id: \.offset) { index, step in
                    stepRow(index: index, step: step)
                }
            }
            .padding(.top, 20)
        }
        .padding(.top, 28)
    }

    /// Seal-tint Chinese numeral + step text, with an inline 眉批 tip block (left
    /// border, seal-tint) and a duration line, each shown only when present.
    private func stepRow(index: Int, step: RecipeStep) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(chineseNumeral(index + 1))
                .font(.custom(serifName, size: 20))
                .foregroundStyle(model.personaTint)
                .frame(width: 20, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                Text(step.text)
                    .font(.custom(serifName, size: 14))
                    .lineSpacing(13.3) // lh 2.15 at 14pt: (2.15 - 1.2) * 14
                    .foregroundStyle(PaperTokens.ink)
                if let tip = step.tip, !tip.isEmpty {
                    tipBlock(tip)
                }
                if let duration = step.durationSec, duration > 0 {
                    Text(durationText(duration))
                        .font(.custom(sansName, size: 10))
                        .tracking(2.2) // .22em at 10pt
                        .foregroundStyle(PaperTokens.inkFaint)
                        .padding(.top, 9)
                }
            }
        }
        .padding(.bottom, 22)
    }

    /// Structural label matching the mock's persona-neutral "眉批" (margin note) —
    /// deliberately dropping the mock's literal "小當家眉批" wording so no persona name
    /// is hardcoded here, per the app's persona-discipline rule.
    private func tipBlock(_ tip: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("眉批")
                .font(.custom(sansName, size: 10))
                .tracking(2.8) // .28em at 10pt
                .foregroundStyle(model.personaTint)
            Text(tip)
                .font(.custom(serifName, size: 12.5))
                .italic()
                .lineSpacing(9.4) // lh 1.95 at 12.5pt: (1.95 - 1.2) * 12.5
                .foregroundStyle(PaperTokens.ink)
        }
        .padding(.leading, 14)
        .overlay(Rectangle().fill(model.personaTint).frame(width: 1), alignment: .leading)
        .padding(.top, 11)
    }

    /// Plain-digit format ("10 分鐘"/"45 秒") — matches `CookModeView.durationLabel`'s
    /// existing plain-digit precedent (`chineseNumeral` isn't used for durations
    /// anywhere else in the app).
    private func durationText(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds) 秒" : "\(seconds / 60) 分鐘"
    }

    // MARK: 這一頁的紀錄 (this page's record)

    private var recordSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(PaperTokens.rule)
                .frame(height: 1)
            Text("這一頁的紀錄")
                .font(.custom(sansName, size: 10))
                .tracking(4.2) // .42em at 10pt
                .foregroundStyle(PaperTokens.inkFaint)
                .padding(.top, 16)
            VStack(alignment: .leading, spacing: 11) {
                ForEach(Array(verdicts.enumerated()), id: \.element.id) { index, verdict in
                    verdictRow(verdict, attempt: verdicts.count - index, isLatest: index == 0)
                }
            }
            .padding(.top, 14)
        }
        .padding(.top, 24)
    }

    /// Seal Chinese numeral bullet (attempt count, newest first — `verdicts` is already
    /// ordered `created_at desc` by `loadVerdicts()`) + relative date + rating.
    private func verdictRow(_ verdict: Verdict, attempt: Int, isLatest: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(chineseNumeral(attempt))
                .font(.custom(serifName, size: 15))
                .foregroundStyle(isLatest ? model.personaTint : PaperTokens.inkFaint)
            Text(relativeDateString(verdict.createdAt))
                .foregroundStyle(isLatest ? PaperTokens.ink : PaperTokens.inkDim)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(verdict.rating)
                .foregroundStyle(PaperTokens.inkDim)
        }
        .font(.custom(serifName, size: 13.5))
    }

    // MARK: Shared label style

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.custom(sansName, size: 10))
            .tracking(5) // .5em at 10pt
            .foregroundStyle(PaperTokens.inkFaint)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: Sticky footer

    /// Ink-filled `開始做菜` only — the mock's sticky footer also holds an ask-field
    /// entry point into the 邊欄 exchange, which is out of scope here (see file-header
    /// scope note). Mirrors `WeekBoardView`'s ink-filled-button treatment, sized to
    /// this mock's own spec (13.5pt / .34em / 16pt padding) over a fade-to-`stock`
    /// gradient matching the mock's `position:sticky` footer.
    private var footer: some View {
        VStack(spacing: 0) {
            Button {
                showCookMode = true
            } label: {
                Text("開始做菜")
                    .font(.custom(sansName, size: 13.5))
                    .fontWeight(.medium)
                    .tracking(4.6) // .34em at 13.5pt
                    .foregroundStyle(PaperTokens.stock)
                    .frame(maxWidth: .infinity)
                    .padding(16)
                    .background(PaperTokens.ink)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.pageMargin)
        .padding(.top, 24)
        .padding(.bottom, 40)
        .background(
            LinearGradient(
                colors: [PaperTokens.stock.opacity(0), PaperTokens.stock],
                startPoint: .top, endPoint: .bottom
            )
        )
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
