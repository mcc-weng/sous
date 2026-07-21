# M2c2 — Recipe Pipeline iOS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the app share-sheet recipe intake (a real Xcode extension target that
inserts a `recipe_intake` job directly), a cookbook sheet (searchable card grid, recipe
detail, verdict history), and cook mode (備料 checklist → teleprompter → optional
verdict), closing the loop M2c1 opened on the backend.

**Architecture:** No worker/Python changes — M2c1's pipeline already handles
`recipe_intake` jobs end-to-end (cloud-verified). One backend migration adds
`recipe_intake` to the `jobs_write` RLS policy. On iOS: three new SwiftUI surfaces
following the codebase's existing `View`/`Logic`-file split (pure, testable logic in
one file; a thin view in another), plus a new `SousShareExtension` Xcode target added
via `project.yml` (XcodeGen — this project's `Sous.xcodeproj` is generated, never
hand-edited). The extension shares the main app's signed-in session via a Keychain
access group and a cached `household_id` in an App Group container, so it can insert
directly with no separate sign-in flow and no app hand-off.

**Tech Stack:** Swift 5 / SwiftUI (iOS 17+), `supabase-swift` 2.52.0 (already a
dependency), XcodeGen (already how `ios/Sous.xcodeproj` is generated from
`ios/project.yml`), XCTest for pure-logic unit tests, Postgres migration + RLS.

## Global Constraints

- No new `state_api` verbs. `cook_sessions` and `verdicts` already have full
  household-scoped RLS (`cook_rw`, `verdict_rw` in `supabase/migrations/0002_rls.sql`)
  — every cook-mode write is a direct client write, mirroring the shopping-checkbox
  precedent (`AppModel.toggleShoppingItem`).
- No push notifications, no step-aware chat rail, no real countdown timers, no recipe
  editing UI — all explicitly out of scope per
  `docs/superpowers/specs/2026-07-22-m2c2-recipe-pipeline-ios-design.md`.
- Household comes from the signed-in session / `AppModel.household`, never hardcoded —
  same rule the worker side already follows for `SOUS_HOUSEHOLD_ID`.
- Every new Postgres migration file follows the existing numbered convention
  (`supabase/migrations/000N_description.sql`); the next number is `0006`.
- `ios/Sous.xcodeproj` and `ios/DerivedData` are gitignored and regenerated via
  `xcodegen generate` — never edit `project.pbxproj` directly, edit `project.yml`.
- Build/test verification uses the existing project convention: `cd ios && xcodegen
  generate && xcodebuild -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS
  Simulator,name=<SIM_NAME>' test` (or `build`), same as every prior iOS task in this
  repo's plans.

---

### Task 1: RLS migration — allow `recipe_intake` jobs

**Files:**
- Create: `supabase/migrations/0006_jobs_allow_recipe_intake_kind.sql`

**Interfaces:**
- Produces: `jobs_write` policy on `jobs` now accepts `kind in ('chat', 'ritual',
  'recipe_intake')`. Every later task that inserts a `recipe_intake` job through the
  RLS-bound client path (Task 9) depends on this.

- [ ] **Step 1: Write the migration**

```sql
-- supabase/migrations/0006_jobs_allow_recipe_intake_kind.sql
-- jobs_write only allowed kind in ('chat', 'ritual') — recipe_intake (M2c1's job kind)
-- was never added despite the pipeline going live, because M2c1's own tests and cloud
-- exit check always used the worker's service-role connection (bypasses RLS entirely),
-- never the RLS-bound client path. Same class of bug 0005 fixed for 'ritual': it goes
-- unnoticed until a real client tries to insert one for real. M2c2's share extension
-- is the first thing that ever will.
alter policy jobs_write on jobs
  with check (is_member(household_id) and kind in ('chat', 'ritual', 'recipe_intake'));
```

- [ ] **Step 2: Apply locally and verify**

Run: `supabase db reset` (local stack) or, if the local stack is already running,
`supabase migration up`.

Then verify the policy text updated:

```bash
cd /Users/mikeweng/Projects/sous
psql "$(supabase status -o env | grep DB_URL | cut -d= -f2 | tr -d '\"')" -c \
  "select polname, pg_get_expr(polwithcheck, polrelid) from pg_policy where polname='jobs_write';"
```

Expected: the printed expression includes `'recipe_intake'::text` alongside `'chat'`
and `'ritual'`. (Full behavioral verification — a real anon-key client actually
inserting under this policy — happens in Task 10's exit check, not here; this step only
confirms the policy text is correct, matching how `0005` was verified.)

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/0006_jobs_allow_recipe_intake_kind.sql
git commit -m "fix(db): allow jobs.kind = 'recipe_intake' under RLS"
```

---

### Task 2: Recipe models + cookbook search logic

**Files:**
- Modify: `ios/Sous/Models.swift`
- Create: `ios/Sous/CookbookLogic.swift`
- Test: `ios/SousTests/CookbookLogicTests.swift`

**Interfaces:**
- Produces: `struct Recipe: Codable, Identifiable, Equatable, Hashable` (`id, slug,
  title, sourceBlock: String?, bodyMd, ingredients: [Ingredient], steps:
  [RecipeStep], createdAt`), `struct Ingredient` (`name, qty: String?`), `struct
  RecipeStep` (`text, stage: String?, durationSec: Int?, tip: String?`),
  `filteredRecipes(_:query:) -> [Recipe]`. Later tasks (3, 4, 5, 6) all consume these.

- [ ] **Step 1: Write the failing tests**

```swift
// ios/SousTests/CookbookLogicTests.swift
import XCTest
@testable import Sous

final class CookbookLogicTests: XCTestCase {
    private func makeRecipe(_ title: String) -> Recipe {
        Recipe(id: UUID(), slug: title, title: title, sourceBlock: nil, bodyMd: "",
               ingredients: [], steps: [], createdAt: Date())
    }

    func testFilteredRecipesReturnsAllWhenQueryEmpty() {
        let recipes = [makeRecipe("紅燒牛肉麵"), makeRecipe("三杯雞")]
        XCTAssertEqual(filteredRecipes(recipes, query: ""), recipes)
    }

    func testFilteredRecipesMatchesCaseInsensitiveSubstring() {
        let beef = makeRecipe("紅燒牛肉麵")
        let chicken = makeRecipe("三杯雞")
        let result = filteredRecipes([beef, chicken], query: "牛肉")
        XCTAssertEqual(result, [beef])
    }

    func testFilteredRecipesTrimsWhitespaceQuery() {
        let recipes = [makeRecipe("紅燒牛肉麵")]
        XCTAssertEqual(filteredRecipes(recipes, query: "   "), recipes)
    }

    func testFilteredRecipesReturnsEmptyWhenNoMatch() {
        let recipes = [makeRecipe("紅燒牛肉麵")]
        XCTAssertEqual(filteredRecipes(recipes, query: "咖哩"), [])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ios && xcodegen generate && xcodebuild -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=<SIM_NAME>' test`
Expected: FAIL — `Recipe`/`filteredRecipes` not defined.

- [ ] **Step 3: Add the models to Models.swift**

Append to `ios/Sous/Models.swift`:

```swift
struct Ingredient: Codable, Equatable, Hashable {
    let name: String
    let qty: String?
}

struct RecipeStep: Codable, Equatable, Hashable {
    let text: String
    let stage: String?
    let durationSec: Int?
    let tip: String?

    enum CodingKeys: String, CodingKey {
        case text, stage, tip
        case durationSec = "duration_sec"
    }
}

struct Recipe: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    let slug: String
    let title: String
    let sourceBlock: String?
    let bodyMd: String
    let ingredients: [Ingredient]
    let steps: [RecipeStep]
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, slug, title, ingredients, steps
        case sourceBlock = "source_block"
        case bodyMd = "body_md"
        case createdAt = "created_at"
    }
}
```

- [ ] **Step 4: Write CookbookLogic.swift**

```swift
// ios/Sous/CookbookLogic.swift
import Foundation

/// Client-side title search — case-insensitive substring match. No full-text search
/// infra needed at v1 recipe-count scale.
func filteredRecipes(_ recipes: [Recipe], query: String) -> [Recipe] {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return recipes }
    return recipes.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd ios && xcodegen generate && xcodebuild -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=<SIM_NAME>' test`
Expected: PASS, all 4 `CookbookLogicTests`.

- [ ] **Step 6: Commit**

```bash
git add ios/Sous/Models.swift ios/Sous/CookbookLogic.swift ios/SousTests/CookbookLogicTests.swift
git commit -m "feat(ios): Recipe models + cookbook search logic"
```

---

### Task 3: Cook session/verdict models + cook mode logic

**Files:**
- Modify: `ios/Sous/Models.swift`
- Create: `ios/Sous/CookModeLogic.swift`
- Test: `ios/SousTests/CookModeLogicTests.swift`

**Interfaces:**
- Consumes: nothing new from Task 2.
- Produces: `struct CookSession: Codable, Identifiable, Equatable` (`id, recipeId,
  startedAt, completedAt: Date?`), `struct Verdict: Codable, Identifiable, Equatable`
  (`id, rating, note: String?, createdAt`), `isChecklistComplete(_:) -> Bool`,
  `clampedStepIndex(_:stepCount:) -> Int`, `struct VerdictPayload: Encodable, Equatable`
  (`household_id, plan_day_id, rating, note: String?`), `makeVerdictPayload(householdId:planDayId:rating:note:)
  -> VerdictPayload?` (nil when `planDayId` is nil). Task 4 (`CookModeView`) consumes
  all of these directly.

- [ ] **Step 1: Write the failing tests**

```swift
// ios/SousTests/CookModeLogicTests.swift
import XCTest
@testable import Sous

final class CookModeLogicTests: XCTestCase {
    func testChecklistIncompleteWhenAnyUnchecked() {
        XCTAssertFalse(isChecklistComplete([true, false, true]))
    }

    func testChecklistCompleteWhenAllChecked() {
        XCTAssertTrue(isChecklistComplete([true, true]))
    }

    func testChecklistIncompleteWhenEmpty() {
        XCTAssertFalse(isChecklistComplete([]))
    }

    func testClampedStepIndexStaysInLowerBound() {
        XCTAssertEqual(clampedStepIndex(-1, stepCount: 5), 0)
    }

    func testClampedStepIndexStaysInUpperBound() {
        XCTAssertEqual(clampedStepIndex(10, stepCount: 5), 4)
    }

    func testClampedStepIndexInBoundsUnchanged() {
        XCTAssertEqual(clampedStepIndex(2, stepCount: 5), 2)
    }

    func testClampedStepIndexWithNoStepsIsZero() {
        XCTAssertEqual(clampedStepIndex(3, stepCount: 0), 0)
    }

    func testVerdictPayloadNilWithoutPlanDay() {
        let payload = makeVerdictPayload(householdId: UUID(), planDayId: nil, rating: "不錯", note: nil)
        XCTAssertNil(payload)
    }

    func testVerdictPayloadBuiltWithPlanDay() {
        let household = UUID()
        let planDay = UUID()
        let payload = makeVerdictPayload(householdId: household, planDayId: planDay, rating: "神作", note: "好吃")
        XCTAssertEqual(payload, VerdictPayload(household_id: household, plan_day_id: planDay, rating: "神作", note: "好吃"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ios && xcodegen generate && xcodebuild -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=<SIM_NAME>' test`
Expected: FAIL — symbols not defined.

- [ ] **Step 3: Add the models to Models.swift**

Append to `ios/Sous/Models.swift`:

```swift
struct CookSession: Codable, Identifiable, Equatable {
    let id: UUID
    let recipeId: UUID
    let startedAt: Date
    let completedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case recipeId = "recipe_id"
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }
}

struct Verdict: Codable, Identifiable, Equatable {
    let id: UUID
    let rating: String
    let note: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, rating, note
        case createdAt = "created_at"
    }
}
```

- [ ] **Step 4: Write CookModeLogic.swift**

```swift
// ios/Sous/CookModeLogic.swift
import Foundation

/// True once every ingredient in the 備料 (mise en place) gate has been checked off.
/// The gate is intentionally skippable in the UI — this only drives the "ready to
/// cook" affordance, not a hard block.
func isChecklistComplete(_ checked: [Bool]) -> Bool {
    !checked.isEmpty && checked.allSatisfy { $0 }
}

/// Clamps a step index into `steps`' bounds — shared by swipe-advance and the
/// step-list jump affordance so neither can navigate past the ends.
func clampedStepIndex(_ index: Int, stepCount: Int) -> Int {
    guard stepCount > 0 else { return 0 }
    return min(max(index, 0), stepCount - 1)
}

struct VerdictPayload: Encodable, Equatable {
    let household_id: UUID
    let plan_day_id: UUID
    let rating: String
    let note: String?
}

/// `planDayId` is nil when cook mode was launched from the cookbook (not tied to a
/// specific day on the plan) — there's nothing to rate against, so no payload is built.
func makeVerdictPayload(householdId: UUID, planDayId: UUID?, rating: String, note: String?) -> VerdictPayload? {
    guard let planDayId else { return nil }
    return VerdictPayload(household_id: householdId, plan_day_id: planDayId, rating: rating, note: note)
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd ios && xcodegen generate && xcodebuild -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=<SIM_NAME>' test`
Expected: PASS, all 9 `CookModeLogicTests`.

- [ ] **Step 6: Commit**

```bash
git add ios/Sous/Models.swift ios/Sous/CookModeLogic.swift ios/SousTests/CookModeLogicTests.swift
git commit -m "feat(ios): cook session/verdict models + cook mode logic"
```

---

### Task 4: CookModeView (checklist → teleprompter → verdict)

**Files:**
- Create: `ios/Sous/CookModeView.swift`

**Interfaces:**
- Consumes: `Recipe`, `PlanDay?`, `CookSession`, `Verdict`, `VerdictPayload`,
  `isChecklistComplete`, `clampedStepIndex`, `makeVerdictPayload` (Tasks 2–3);
  `AppModel.client`, `AppModel.household` (existing).
- Produces: `struct CookModeView: View`, `init(recipe: Recipe, planDay: PlanDay?)`.
  Tasks 5 and 6 present this via `.fullScreenCover` from the recipe detail view and the
  Tonight card respectively.

This view has no caller yet (Tasks 5/6 wire it up) — its "test" for this task is a
successful build, since it's a full-screen UI with no automated coverage beyond the
pure logic already tested in Task 3, matching how UI-only tasks in this codebase's
prior plans (M2b2) were verified: build success now, real behavior at the final
real-device exit check (Task 10).

- [ ] **Step 1: Write CookModeView.swift**

```swift
// ios/Sous/CookModeView.swift
import SwiftUI

struct CookModeView: View {
    let recipe: Recipe
    let planDay: PlanDay?
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var checked: [Bool]
    @State private var phase: Phase = .prep
    @State private var stepIndex = 0
    @State private var showStepList = false
    @State private var sessionId: UUID?
    @State private var rating: String?
    @State private var note = ""

    private enum Phase { case prep, cooking, verdict, done }

    init(recipe: Recipe, planDay: PlanDay?) {
        self.recipe = recipe
        self.planDay = planDay
        _checked = State(initialValue: Array(repeating: false, count: recipe.ingredients.count))
    }

    var body: some View {
        VStack {
            switch phase {
            case .prep: prepChecklist
            case .cooking: teleprompter
            case .verdict: verdictPrompt
            case .done: doneView
            }
        }
        .padding()
        .task { await startSession() }
    }

    private var prepChecklist: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("備料").font(.title2.bold())
            ForEach(recipe.ingredients.indices, id: \.self) { i in
                Button {
                    checked[i].toggle()
                } label: {
                    HStack {
                        Image(systemName: checked[i] ? "checkmark.circle.fill" : "circle")
                        Text(recipe.ingredients[i].name)
                        Spacer()
                        if let qty = recipe.ingredients[i].qty {
                            Text(qty).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
            HStack {
                Button("略過") { phase = .cooking }
                Spacer()
                Button("開始烹飪") { phase = .cooking }
                    .buttonStyle(.borderedProminent)
                    .disabled(!recipe.ingredients.isEmpty && !isChecklistComplete(checked))
            }
        }
    }

    private var teleprompter: some View {
        VStack(spacing: 24) {
            HStack {
                Text("\(stepIndex + 1) / \(recipe.steps.count)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("步驟列表") { showStepList = true }
            }
            Spacer()
            Text(recipe.steps[stepIndex].text)
                .font(.title.bold())
                .multilineTextAlignment(.center)
            if let tip = recipe.steps[stepIndex].tip {
                Text(tip).font(.body).foregroundStyle(.secondary)
            }
            if let duration = recipe.steps[stepIndex].durationSec {
                Text(durationLabel(duration)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                Button("上一步") {
                    stepIndex = clampedStepIndex(stepIndex - 1, stepCount: recipe.steps.count)
                }
                .disabled(stepIndex == 0)
                Spacer()
                if stepIndex == recipe.steps.count - 1 {
                    Button("完成") { Task { await finishCooking() } }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("下一步") {
                        stepIndex = clampedStepIndex(stepIndex + 1, stepCount: recipe.steps.count)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .sheet(isPresented: $showStepList) {
            List(recipe.steps.indices, id: \.self) { i in
                Button(recipe.steps[i].text) {
                    stepIndex = i
                    showStepList = false
                }
            }
        }
    }

    private var verdictPrompt: some View {
        VStack(spacing: 16) {
            Text("這頓煮得怎麼樣?").font(.title2.bold())
            ForEach(["神作", "不錯", "普通", "翻車"], id: \.self) { option in
                // A ternary can't unify two different ButtonStyle-conforming
                // concrete types (.borderedProminent vs .bordered), so the whole
                // Button branches instead of just the style argument.
                if rating == option {
                    Button(option) { rating = option }.buttonStyle(.borderedProminent)
                } else {
                    Button(option) { rating = option }.buttonStyle(.bordered)
                }
            }
            TextField("備註(選填)", text: $note)
                .textFieldStyle(.roundedBorder)
            Button("送出") { Task { await submitVerdict() } }
                .buttonStyle(.borderedProminent)
                .disabled(rating == nil)
            Button("略過") { phase = .done }
        }
    }

    private var doneView: some View {
        VStack(spacing: 16) {
            Label("煮好了!", systemImage: "checkmark.seal.fill")
                .font(.title.bold())
                .foregroundStyle(.green)
            Button("關閉") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
    }

    private func durationLabel(_ seconds: Int) -> String {
        seconds < 60 ? "約 \(seconds) 秒" : "約 \(seconds / 60) 分鐘"
    }

    /// Optimistic and best-effort — a failed insert doesn't block cooking, matching
    /// the shopping checkbox's precedent of never gating a mechanical action on a
    /// network round-trip.
    private func startSession() async {
        struct NewSession: Encodable { let recipe_id: UUID }
        do {
            let inserted: CookSession = try await model.client.from("cook_sessions")
                .insert(NewSession(recipe_id: recipe.id))
                .select("id,recipe_id,started_at,completed_at").single().execute().value
            sessionId = inserted.id
        } catch { print("start cook session: \(error)") }
    }

    private func finishCooking() async {
        if let sessionId {
            struct Complete: Encodable { let completed_at: String; let step_ticks: [Int] }
            let nowISO = ISO8601DateFormatter().string(from: Date())
            do {
                try await model.client.from("cook_sessions")
                    .update(Complete(completed_at: nowISO, step_ticks: Array(recipe.steps.indices)))
                    .eq("id", value: sessionId)
                    .execute()
            } catch { print("complete cook session: \(error)") }
        }
        phase = planDay != nil ? .verdict : .done
    }

    private func submitVerdict() async {
        guard let household = model.household, let rating,
              let payload = makeVerdictPayload(householdId: household.id, planDayId: planDay?.id,
                                                rating: rating, note: note.isEmpty ? nil : note) else {
            phase = .done
            return
        }
        do {
            try await model.client.from("verdicts").insert(payload).execute()
        } catch { print("submit verdict: \(error)") }
        phase = .done
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `cd ios && xcodegen generate && xcodebuild -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=<SIM_NAME>' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add ios/Sous/CookModeView.swift
git commit -m "feat(ios): CookModeView — checklist, teleprompter, verdict prompt"
```

---

### Task 5: Cookbook sheet + recipe detail view

**Files:**
- Modify: `ios/Sous/AppModel.swift`
- Modify: `ios/Sous/CounterView.swift`
- Create: `ios/Sous/CookbookView.swift`
- Create: `ios/Sous/RecipeDetailView.swift`

**Interfaces:**
- Consumes: `Recipe`, `filteredRecipes` (Task 2), `Verdict` (Task 3), `CookModeView`
  (Task 4), `AppModel.client`.
- Produces: `AppModel.recipes: [Recipe]`, `AppModel.loadCookbook() async`, `struct
  CookbookView: View`, `struct RecipeDetailView: View` (`init(recipe: Recipe)`). Task 6
  adds the Tonight-card entry point alongside this sheet.

- [ ] **Step 1: Add cookbook loading to AppModel**

In `ios/Sous/AppModel.swift`, add a published property near the other `@Published`
declarations:

```swift
@Published var recipes: [Recipe] = []
```

Add a loader near the other `loadX()` methods (after `loadShoppingItems()`):

```swift
func loadCookbook() async {
    do {
        recipes = try await client.from("recipes")
            .select("id,slug,title,source_block,body_md,ingredients,steps,created_at")
            .order("created_at", ascending: false)
            .execute().value
    } catch { print("cookbook load: \(error)") }
}
```

Do **not** add this to `loadAll()` — the user may never open the cookbook in a
session; it loads lazily when the sheet appears, same as `WeekBoardView`/
`ShoppingListView`'s `.task` pattern.

- [ ] **Step 2: Write CookbookView.swift**

```swift
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
```

- [ ] **Step 3: Write RecipeDetailView.swift**

```swift
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
```

- [ ] **Step 4: Wire the cookbook sheet into CounterView**

In `ios/Sous/CounterView.swift`, add a new `@State` alongside the existing two:

```swift
@State private var showCookbook = false
```

Add a new `.sheet` modifier alongside the existing two (inside `body`, after the
`showShoppingList` sheet):

```swift
.sheet(isPresented: $showCookbook) {
    CookbookView().environmentObject(model)
}
```

Add a button to `chipRow`, alongside the existing week/shopping buttons:

```swift
Button {
    showCookbook = true
} label: {
    Label("食譜本", systemImage: "book.closed")
}
```

- [ ] **Step 5: Build to verify it compiles**

Run: `cd ios && xcodegen generate && xcodebuild -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=<SIM_NAME>' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add ios/Sous/AppModel.swift ios/Sous/CounterView.swift ios/Sous/CookbookView.swift ios/Sous/RecipeDetailView.swift
git commit -m "feat(ios): cookbook sheet + recipe detail with verdict history"
```

---

### Task 6: Cook mode entry point from Tonight card

**Files:**
- Modify: `ios/Sous/CounterView.swift`

**Interfaces:**
- Consumes: `CookModeView` (Task 4), `AppModel.tonight: PlanDay?` (existing),
  `model.recipes` (Task 5) — needs the `Recipe` matching tonight's dish, looked up by
  `PlanDay`'s `dish` text since `PlanDay` doesn't carry a `recipe_id` in the client
  model today.

Tonight's `PlanDay` doesn't currently decode a `recipe_id` column (the design spec's
original schema description mentions `plan_days.recipe_id?` exists, but
`AppModel.loadTonight()`'s select list omits it and `PlanDay` doesn't model it). Adding
a full recipe-linking column is out of scope here — the pragmatic v1 approach: only
show the "開始煮" button on the Tonight card when a cookbook recipe's title exactly
matches `tonight.dish`, and pass that matched `Recipe` into `CookModeView`. If tonight's
dish was never intake'd as a recipe (most week-plan dishes won't be, since most are
brain-improvised, not intake'd from a shared link), there's simply no button — this is
consistent with cook mode only ever being meaningfully usable for intake'd recipes,
which is the entire point of this phase.

- [ ] **Step 1: Add a recipe-matching helper and wire the button**

In `ios/Sous/CounterView.swift`, add a computed property and `@State` near the top of
`CounterView`:

```swift
@State private var showCookModeForTonight = false

private var tonightRecipe: Recipe? {
    guard let dish = model.tonight?.dish else { return nil }
    return model.recipes.first { $0.title == dish }
}
```

Modify `tonightCard` to add the button conditionally (only append this inside the
existing `VStack` in `tonightCard`, after the existing `HStack` block, don't rewrite
the whole view):

```swift
if let recipe = tonightRecipe {
    Button("開始煮") { showCookModeForTonight = true }
        .buttonStyle(.borderedProminent)
        .padding(.top, 4)
        .fullScreenCover(isPresented: $showCookModeForTonight) {
            CookModeView(recipe: recipe, planDay: model.tonight).environmentObject(model)
        }
}
```

Add a `.task` to `CounterView.body` (alongside the existing `.sheet` modifiers) so
`model.recipes` is populated even without opening the cookbook sheet first — reuse
`loadCookbook()`:

```swift
.task { await model.loadCookbook() }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `cd ios && xcodegen generate && xcodebuild -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=<SIM_NAME>' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add ios/Sous/CounterView.swift
git commit -m "feat(ios): cook mode entry point from the Tonight card"
```

---

### Task 7: Shared Supabase client (Keychain access group + App Group)

**Files:**
- Create: `ios/Sous/SupabaseClientFactory.swift`
- Modify: `ios/Sous/AppModel.swift`
- Modify: `ios/Sous/Sous.entitlements`
- Modify: `ios/project.yml`

**Interfaces:**
- Produces: `enum SupabaseClientFactory { static func make() -> SupabaseClient }`,
  App Group `group.com.mikeweng.sous`, Keychain access group
  `9D37X3YV25.com.mikeweng.sous.shared`. Tasks 8–9 (the share extension) depend on
  both the entitlement values and this factory function to construct an identically
  configured client in the extension target.

**Known, expected side effect:** this changes where `supabase-swift` stores the
session in the Keychain (adding an explicit access group where none was configured
before). Any existing signed-in session on a test device will not be found under the
new configuration — **this requires signing in again once** after this change lands.
This is expected, not a bug; confirm it in Step 3 below rather than being surprised by
it later.

- [ ] **Step 1: Write SupabaseClientFactory.swift**

```swift
// ios/Sous/SupabaseClientFactory.swift
import Foundation
import Supabase

enum SupabaseClientFactory {
    /// Shared between the main app and the share extension via a Keychain access
    /// group under the App Group `group.com.mikeweng.sous`, so a session created in
    /// one is usable in the other with no separate sign-in flow. `$(AppIdentifierPrefix)`
    /// in the .entitlements file resolves to the team ID at build time; runtime Swift
    /// code has to spell that resolved value out directly, since string interpolation
    /// doesn't happen in entitlements-adjacent build variables.
    static func make() -> SupabaseClient {
        SupabaseClient(
            supabaseURL: Config.supabaseURL,
            supabaseKey: Config.supabaseAnonKey,
            options: SupabaseClientOptions(
                auth: .init(
                    storage: KeychainLocalStorage(accessGroup: "9D37X3YV25.com.mikeweng.sous.shared")
                )
            )
        )
    }
}
```

- [ ] **Step 2: Use the factory in AppModel and add household_id caching**

In `ios/Sous/AppModel.swift`, replace:

```swift
let client = SupabaseClient(
    supabaseURL: Config.supabaseURL,
    supabaseKey: Config.supabaseAnonKey
)
```

with:

```swift
let client = SupabaseClientFactory.make()
```

In `refreshHousehold()`, cache the household id for the extension to read (add this
inside the `do` block, right after `household = rows.first`):

```swift
func refreshHousehold() async {
    do {
        let rows: [Household] = try await client.from("households")
            .select("id,name,worker_seen_at,timezone").execute().value
        household = rows.first
        if let id = household?.id {
            UserDefaults(suiteName: "group.com.mikeweng.sous")?.set(id.uuidString, forKey: "household_id")
        }
    } catch { print("household load: \(error)") }
}
```

- [ ] **Step 3: Add entitlements**

In `ios/Sous/Sous.entitlements`, add the two new keys (keep the existing
`com.apple.developer.applesignin`):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.developer.applesignin</key>
	<array>
		<string>Default</string>
	</array>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>group.com.mikeweng.sous</string>
	</array>
	<key>keychain-access-groups</key>
	<array>
		<string>$(AppIdentifierPrefix)com.mikeweng.sous.shared</string>
	</array>
</dict>
</plist>
```

- [ ] **Step 4: Update project.yml's entitlement properties to match**

In `ios/project.yml`, the `Sous` target's `entitlements.properties` currently only
lists `com.apple.developer.applesignin`. XcodeGen merges `properties` into whatever the
`path`-referenced file already has, so since Step 3 already added the new keys
directly to the physical file, no `project.yml` change is required for this target —
confirm this by re-reading the generated entitlements after `xcodegen generate` in
Step 5 (below) rather than duplicating the keys in both places.

- [ ] **Step 5: Build and manually verify re-auth**

Run: `cd ios && xcodegen generate && xcodebuild -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=<SIM_NAME>' build`
Expected: BUILD SUCCEEDED.

On a real device or simulator with a prior signed-in session: launch the app, confirm
it drops to `AuthView` (session not found under the new Keychain config — expected per
the note above), sign in with Apple again, confirm `loadAll()` succeeds and the app
works normally afterward.

- [ ] **Step 6: Commit**

```bash
git add ios/Sous/SupabaseClientFactory.swift ios/Sous/AppModel.swift ios/Sous/Sous.entitlements
git commit -m "feat(ios): shared Keychain access group + App Group for share extension"
```

---

### Task 8: Share extension target scaffold

**Files:**
- Modify: `ios/project.yml`
- Create: `ios/SousShareExtension/Info.plist`
- Create: `ios/SousShareExtension/SousShareExtension.entitlements`
- Create: `ios/SousShareExtension/ShareViewController.swift`

**Interfaces:**
- Produces: a buildable, embeddable `SousShareExtension` target with bundle id
  `com.mikeweng.sous.SousShareExtension`, activated for shared URLs. Task 9 replaces
  the placeholder `ShareViewController` body with the real SwiftUI-hosted flow.

- [ ] **Step 1: Add the target to project.yml**

In `ios/project.yml`, add a new target under `targets:` (alongside `Sous` and
`SousTests`):

```yaml
  SousShareExtension:
    type: app-extension
    platform: iOS
    sources:
      - SousShareExtension
      - path: Sous/Config.swift
      - path: Sous/SupabaseClientFactory.swift
    dependencies:
      - package: Supabase
        product: Supabase
    entitlements:
      path: SousShareExtension/SousShareExtension.entitlements
    info:
      path: SousShareExtension/Info.plist
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.mikeweng.sous.SousShareExtension
        CODE_SIGN_STYLE: Automatic
        DEVELOPMENT_TEAM: 9D37X3YV25
```

Add it as an embedded dependency of the `Sous` target — modify the `Sous` target's
existing `dependencies:` list:

```yaml
    dependencies:
      - package: Supabase
        product: Supabase
      - target: SousShareExtension
        embed: true
```

- [ ] **Step 2: Write the extension's entitlements**

```xml
<!-- ios/SousShareExtension/SousShareExtension.entitlements -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>group.com.mikeweng.sous</string>
	</array>
	<key>keychain-access-groups</key>
	<array>
		<string>$(AppIdentifierPrefix)com.mikeweng.sous.shared</string>
	</array>
</dict>
</plist>
```

- [ ] **Step 3: Write the extension's Info.plist**

```xml
<!-- ios/SousShareExtension/Info.plist -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>$(DEVELOPMENT_LANGUAGE)</string>
	<key>CFBundleDisplayName</key>
	<string>小當家</string>
	<key>CFBundleExecutable</key>
	<string>$(EXECUTABLE_NAME)</string>
	<key>CFBundleIdentifier</key>
	<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$(PRODUCT_NAME)</string>
	<key>CFBundlePackageType</key>
	<string>XPC!</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>NSExtension</key>
	<dict>
		<key>NSExtensionAttributes</key>
		<dict>
			<key>NSExtensionActivationRule</key>
			<dict>
				<key>NSExtensionActivationSupportsWebURLWithMaxCount</key>
				<integer>1</integer>
			</dict>
		</dict>
		<key>NSExtensionPrincipalClass</key>
		<string>$(PRODUCT_MODULE_NAME).ShareViewController</string>
		<key>NSExtensionPointIdentifier</key>
		<string>com.apple.share-services</string>
	</dict>
</dict>
</plist>
```

- [ ] **Step 4: Write a placeholder ShareViewController**

```swift
// ios/SousShareExtension/ShareViewController.swift
import UIKit

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let label = UILabel()
        label.text = "小當家"
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}
```

- [ ] **Step 5: Build and manually verify the extension appears**

Run: `cd ios && xcodegen generate && xcodebuild -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=<SIM_NAME>' build`
Expected: BUILD SUCCEEDED, `SousShareExtension.appex` embedded in the built `.app`.

On a real device (share extensions don't reliably activate for Safari/third-party
apps in the simulator): install the app, open Safari on any page, tap Share, confirm
"小當家" appears in the share sheet's app row and opens the placeholder view.

- [ ] **Step 6: Commit**

```bash
git add ios/project.yml ios/SousShareExtension/
git commit -m "feat(ios): SousShareExtension target scaffold"
```

---

### Task 9: Share extension intake logic + real UI

**Files:**
- Create: `ios/Sous/ShareIntakeLogic.swift`
- Test: `ios/SousTests/ShareIntakeLogicTests.swift`
- Modify: `ios/project.yml`
- Modify: `ios/SousShareExtension/ShareViewController.swift`
- Create: `ios/SousShareExtension/ShareIntakeView.swift`

**Interfaces:**
- Consumes: `SupabaseClientFactory.make()` (Task 7).
- Produces: `struct RecipeIntakeJob: Encodable, Equatable` (`household_id, kind,
  payload: Payload { url, by }`), `makeRecipeIntakeJob(householdId:url:) ->
  RecipeIntakeJob`. Consumed only by `ShareIntakeView` in this task.

`ShareIntakeLogic.swift` lives in `ios/Sous/` (not `ios/SousShareExtension/`) so it
compiles into the main `Sous` target too and is unit-testable via `@testable import
Sous` in `SousTests`, exactly like `CookbookLogic.swift`/`CookModeLogic.swift`. The
extension target lists it as an individual-file source, same as `Config.swift`.

- [ ] **Step 1: Write the failing test**

```swift
// ios/SousTests/ShareIntakeLogicTests.swift
import XCTest
@testable import Sous

final class ShareIntakeLogicTests: XCTestCase {
    func testMakeRecipeIntakeJobShapesPayload() {
        let household = UUID()
        let url = URL(string: "https://www.youtube.com/watch?v=NbmT_9oH1SY")!
        let job = makeRecipeIntakeJob(householdId: household, url: url)
        XCTAssertEqual(job, RecipeIntakeJob(
            household_id: household, kind: "recipe_intake",
            payload: .init(url: "https://www.youtube.com/watch?v=NbmT_9oH1SY", by: "mike")
        ))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios && xcodegen generate && xcodebuild -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=<SIM_NAME>' test`
Expected: FAIL — `RecipeIntakeJob`/`makeRecipeIntakeJob` not defined.

- [ ] **Step 3: Write ShareIntakeLogic.swift**

```swift
// ios/Sous/ShareIntakeLogic.swift
import Foundation

struct RecipeIntakeJob: Encodable, Equatable {
    let household_id: UUID
    let kind: String
    let payload: Payload

    struct Payload: Encodable, Equatable {
        let url: String
        let by: String
    }
}

func makeRecipeIntakeJob(householdId: UUID, url: URL) -> RecipeIntakeJob {
    RecipeIntakeJob(household_id: householdId, kind: "recipe_intake",
                     payload: .init(url: url.absoluteString, by: "mike"))
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ios && xcodegen generate && xcodebuild -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=<SIM_NAME>' test`
Expected: PASS.

- [ ] **Step 5: Add the shared file to the extension target's sources in project.yml**

In `ios/project.yml`, add one more `path:` entry to `SousShareExtension`'s `sources:`
list (from Task 8):

```yaml
    sources:
      - SousShareExtension
      - path: Sous/Config.swift
      - path: Sous/SupabaseClientFactory.swift
      - path: Sous/ShareIntakeLogic.swift
```

- [ ] **Step 6: Write ShareIntakeView.swift**

```swift
// ios/SousShareExtension/ShareIntakeView.swift
import SwiftUI
import UniformTypeIdentifiers
import Supabase

private let appGroupID = "group.com.mikeweng.sous"

private enum ShareIntakeState: Equatable {
    case loadingURL
    case ready(URL)
    case sending
    case sent
    case noSession
    case error(String)
}

struct ShareIntakeView: View {
    weak var extensionContext: NSExtensionContext?
    @State private var state: ShareIntakeState = .loadingURL
    private let client = SupabaseClientFactory.make()

    var body: some View {
        VStack(spacing: 16) {
            switch state {
            case .loadingURL:
                ProgressView()
            case .ready(let url):
                Text(url.absoluteString).font(.caption).lineLimit(2)
                Button("送到小當家的廚房") { Task { await send(url) } }
                    .buttonStyle(.borderedProminent)
            case .sending:
                ProgressView("送出中…")
            case .sent:
                Label("已送到小當家的廚房!", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .noSession:
                Text("先打開小當家登入").foregroundStyle(.secondary)
            case .error(let message):
                Text(message).foregroundStyle(.red)
            }
            Button("關閉") { dismiss() }
        }
        .padding()
        .task { await loadSharedURL() }
    }

    private func loadSharedURL() async {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let provider = item.attachments?.first,
              provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) else {
            state = .error("找不到連結")
            return
        }
        let loaded: NSSecureCoding? = await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                continuation.resume(returning: item)
            }
        }
        guard let url = loaded as? URL else {
            state = .error("找不到連結")
            return
        }
        state = .ready(url)
    }

    private func send(_ url: URL) async {
        state = .sending
        guard (try? await client.auth.session) != nil else {
            state = .noSession
            return
        }
        guard let idString = UserDefaults(suiteName: appGroupID)?.string(forKey: "household_id"),
              let householdId = UUID(uuidString: idString) else {
            state = .noSession
            return
        }
        do {
            try await client.from("jobs")
                .insert(makeRecipeIntakeJob(householdId: householdId, url: url))
                .execute()
            state = .sent
        } catch {
            state = .error("送出失敗,請稍後再試")
        }
    }

    private func dismiss() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
```

- [ ] **Step 7: Replace the placeholder ShareViewController**

```swift
// ios/SousShareExtension/ShareViewController.swift
import UIKit
import SwiftUI

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let hosting = UIHostingController(rootView: ShareIntakeView(extensionContext: extensionContext))
        addChild(hosting)
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
    }
}
```

- [ ] **Step 8: Build to verify it compiles**

Run: `cd ios && xcodegen generate && xcodebuild -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=<SIM_NAME>' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 9: Commit**

```bash
git add ios/Sous/ShareIntakeLogic.swift ios/SousTests/ShareIntakeLogicTests.swift \
        ios/project.yml ios/SousShareExtension/ShareViewController.swift \
        ios/SousShareExtension/ShareIntakeView.swift
git commit -m "feat(ios): share extension inserts recipe_intake jobs directly"
```

---

### Task 10: Real-device exit check

**Files:** none (verification only, following the M2b2/M2c1 precedent — a real-device
check documented in this plan file, not a new automated test).

- [ ] **Step 1: Install on a real device**

Cloud project `sous` (`ftobrcxtbtdjgrrkavzb`) should already be the active
`SOUS_DB_URL` target (worker daemon left running from the M2c1 exit check). Put the
real `DEVELOPMENT_TEAM` (`9D37X3YV25`, already in `project.yml`) — build and run on a
real iPhone via Xcode (`ios/Sous.xcodeproj`, scheme `Sous`).

- [ ] **Step 2: Confirm re-auth (expected from Task 7)**

Sign in with Apple again if prompted (expected — the Keychain storage config changed).
Confirm the app loads tonight/week board/shopping/chat normally afterward.

- [ ] **Step 3: Share a real recipe URL end-to-end**

From Safari or YouTube's native app, share a real recipe video URL via the system
share sheet, tap "小當家", confirm "已送到小當家的廚房!" appears. Wait for the worker to
process it (watch `chat_messages` for the chef's announcement, or just wait ~2-3
minutes based on the M2c1 exit check's observed timing).

- [ ] **Step 4: Browse the cookbook**

Open the 食譜本 sheet from the Kitchen Counter, confirm the new recipe card appears
(may need to pull to reopen the sheet if it was already loaded before the job
finished — no realtime, matches the rest of the app). Search for it by title, confirm
the filter works. Open the detail view, confirm `source_block`, ingredients, and steps
render correctly.

- [ ] **Step 5: Cook it from the cookbook (planDay == nil path)**

Tap "開始煮" from the recipe detail view. Complete the 備料 checklist (check every
ingredient, confirm "開始烹飪" becomes enabled — or tap "略過" to bypass). Step through
the teleprompter using both "下一步" and the "步驟列表" jump. Tap "完成" on the last
step. Confirm it goes straight to "煮好了!" with **no** verdict prompt (no plan day to
rate against). Confirm a `cook_sessions` row was created with a non-null
`completed_at`.

- [ ] **Step 6: Cook it from the Tonight card (planDay != nil path)**

This requires tonight's plan-day dish to exactly match an intake'd recipe's title —
if it doesn't naturally, temporarily update `plan_days.dish` for today's row (in the
cloud sandbox household) to match the intake'd recipe's title, confirm the "開始煮"
button appears on the Tonight card, and repeat the checklist → teleprompter → "完成"
flow. This time, confirm the verdict prompt **does** appear; submit a rating (e.g.
"不錯") with a note, confirm a `verdicts` row lands with the correct `plan_day_id`, and
confirm it now shows up under "上次煮" on the recipe's detail view.

- [ ] **Step 7: Document and close out**

Append a `## M2c2 exit verification` section to this plan file (mirroring the M2c1
plan's `## M2c1 cloud exit verification` section) with pass/fail notes per check.
Commit as `docs: M2c2 exit verification notes`, and update the
`sous-project-status`/`MEMORY.md` project memory to mark M2c2 done.

---

## Out of scope for M2c2 (tracked for later)

- Push notification on `recipe_intake` job completion — M3 (APNs soul pass).
- Step-aware chat rail during cook mode — needs new backend context-rendering work,
  deferred alongside the M3 quick-reply-buttons work already tracked in project memory.
- Real countdown timers with local notifications for steps with `duration_sec` — v1
  only displays the duration as text.
- Recipe editing UI (fixing bad extractions) — no backend `update-recipe` verb exists.
- A `plan_days.recipe_id` column/decode path so any plan-day dish can be linked to a
  cookbook recipe generically — v1's Tonight-card entry point matches by exact dish
  title text instead, which only works for dishes that came from a recipe intake.
- The WebFetch fallback path for plain (non-video) recipe URLs — carried over from
  M2c1, never exercised end-to-end; the share extension hands off whatever URL type is
  shared, but a plain-web-recipe test is still an open gap.
