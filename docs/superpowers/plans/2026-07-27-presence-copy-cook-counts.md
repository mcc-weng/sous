# Presence Copy Sweep + Per-Dish Cook Counts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route the presence header's hardcoded English copy through `copy_pack`, and
add a per-dish "cooked N times" count (recipe detail, cookbook grid, cook-mode
completion with milestone reactions), per
`docs/superpowers/specs/2026-07-27-presence-copy-cook-counts-design.md`.

**Architecture:** One copy_pack migration adds three keys (`presence_in`,
`presence_out`, `cook_milestone_reaction`). A new pure-logic file,
`CookHistoryLogic.swift`, derives cook counts and milestone status from `cook_sessions`
— no new tables, no cached/denormalized columns. `AppModel` gains one new `@Published`
array (`cookSessions`), fetched alongside `recipes` in the existing `loadCookbook()`
call, and calls `loadPersonaCopy()` from `loadAll()` so presence copy is ready the
moment `CounterView` first renders (not just inside `OnboardingView`, its only caller
today). Four views consume this: `CounterView` (presence label), `RecipeDetailView` and
`CookbookView` (plain count display), and `CookModeView` (plain count, or a persona
milestone reaction at 3rd/5th/every-10th).

**Tech Stack:** Swift 5 / SwiftUI (iOS 17+), `supabase-swift`, XcodeGen
(`ios/project.yml` → generated `ios/Sous.xcodeproj`), XCTest, PostgreSQL/Supabase
migrations.

## Global Constraints

- Next Postgres migration number is `0015` (last existing is `0014`).
- `copy_pack` migrations always merge (`copy_pack || jsonb_build_object(...)`), never
  overwrite — existing keys must survive (same rule as `0007`/`0013`).
- Every `copy_pack`-sourced string has a hardcoded Swift fallback (`?? "..."`) used if
  the key is missing or the fetch fails — matches the existing
  `model.personaCopy[key] ?? fallback` pattern (`OnboardingView.swift:17`). This is a
  resilience default, not a persona-voice decision, so it does not violate the "zero
  hardcoded persona strings" rule.
- No daily-streak/habit mechanic and no home-screen chip — both explicitly rejected
  during brainstorming in favor of per-dish counts shown only where a specific dish is
  already in view. Do not add anything to `CounterView.swift`'s `chipRow`.
- Milestone rule: `count == 3 || count == 5 || (count >= 10 && count % 10 == 0)`. One
  generic `{n}`-templated copy_pack key covers every milestone — no per-threshold keys.
- Plain (non-milestone) count displays are factual UI text, not persona voice — they do
  NOT go through `copy_pack` (matches how verdict ratings/relative dates are already
  shown as plain text in `RecipeDetailView.swift`).
- `AppModel` has no dedicated XCTest file (`ios/SousTests/` has no `AppModelTests.swift`)
  — it's straight network I/O with no branching logic to isolate, exercised via manual
  exit checks per existing convention, not unit tests. Tasks touching only `AppModel`
  verify via build success + the full existing suite still passing, not new tests.
- `ios/Sous.xcodeproj` is generated via `xcodegen generate` from `ios/project.yml` —
  never hand-edit `project.pbxproj`. New source files under `ios/Sous/` and
  `ios/SousTests/` are picked up automatically (both targets glob their whole directory
  in `project.yml`) — no `project.yml` edit needed for this plan.
- iOS build/test verification: `cd ios && xcodegen generate && xcodebuild -project
  Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=<SIM_NAME>'
  test` (same convention as every prior iOS plan in this repo — substitute a real
  booted simulator name, e.g. `iPhone 16 Pro`).

---

### Task 1: Migration — presence + milestone copy_pack keys

**Files:**
- Create: `supabase/migrations/0015_presence_cook_count_copy.sql`

**Interfaces:**
- Produces: three new `personas.copy_pack` keys — `presence_in`, `presence_out`,
  `cook_milestone_reaction` (contains a literal `{n}` placeholder). Task 4 (`CounterView`)
  depends on the first two; Task 7 (`CookModeView`) depends on the third.

- [ ] **Step 1: Write the migration**

```sql
-- supabase/migrations/0015_presence_cook_count_copy.sql
-- Presence header (CounterView.swift) has shown hardcoded English "chef in"/"chef out"
-- since M1 — never routed through copy_pack, in letter conflict with the
-- persona-discipline rule (CLAUDE.md: "zero hardcoded persona strings in app or
-- prompts"). Separately, cook-mode completion gains a per-dish cook-count celebration
-- at milestone counts (docs/superpowers/specs/2026-07-27-presence-copy-cook-counts-design.md).
-- Merge rather than overwrite so existing keys survive, matching 0007/0013's pattern.
update personas set copy_pack = copy_pack || jsonb_build_object(
  'presence_in', '在廚房',
  'presence_out', '外出中',
  'cook_milestone_reaction', '哇,這是你第 {n} 次做這道菜了!越來越上手了呢 🔥'
);
```

- [ ] **Step 2: Apply locally and verify**

Run: `supabase db reset` (local stack) or, if the local stack is already running,
`supabase migration up`.

Then verify the keys landed:

```bash
cd /Users/mikeweng/Projects/sous
psql "$(supabase status -o env | grep DB_URL | cut -d= -f2 | tr -d '"')" -c \
  "select copy_pack->>'presence_in' as presence_in, \
   copy_pack->>'presence_out' as presence_out, \
   copy_pack->>'cook_milestone_reaction' as cook_milestone_reaction \
   from personas limit 1;"
```

Expected: one row, `presence_in` = `在廚房`, `presence_out` = `外出中`,
`cook_milestone_reaction` containing the literal substring `{n}`.

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/0015_presence_cook_count_copy.sql
git commit -m "feat(db): add presence and cook-milestone copy_pack keys"
```

---

### Task 2: `CookHistoryLogic.swift` — pure cook-count/milestone logic

**Files:**
- Create: `ios/Sous/CookHistoryLogic.swift`
- Test: `ios/SousTests/CookHistoryLogicTests.swift`

**Interfaces:**
- Consumes: `CookSession` (`Models.swift:129-141`, already exists — `id`, `recipeId`,
  `startedAt`, `completedAt: Date?`).
- Produces: `cookCount(sessions: [CookSession], recipeId: UUID) -> Int`,
  `isMilestone(_ count: Int) -> Bool`,
  `milestoneReactionText(count: Int, template: String?) -> String`. Tasks 5, 6, 7
  (RecipeDetailView, CookbookView, CookModeView) call these directly.

- [ ] **Step 1: Write the failing tests**

Create `ios/SousTests/CookHistoryLogicTests.swift`:

```swift
import XCTest
@testable import Sous

final class CookHistoryLogicTests: XCTestCase {
    private func makeSession(recipeId: UUID, completed: Bool) -> CookSession {
        CookSession(id: UUID(), recipeId: recipeId, startedAt: Date(),
                    completedAt: completed ? Date() : nil)
    }

    func testCookCountMatchesOnlyGivenRecipe() {
        let target = UUID()
        let other = UUID()
        let sessions = [
            makeSession(recipeId: target, completed: true),
            makeSession(recipeId: other, completed: true),
            makeSession(recipeId: target, completed: true),
        ]
        XCTAssertEqual(cookCount(sessions: sessions, recipeId: target), 2)
    }

    func testCookCountExcludesIncompleteSessions() {
        let target = UUID()
        let sessions = [
            makeSession(recipeId: target, completed: true),
            makeSession(recipeId: target, completed: false),
        ]
        XCTAssertEqual(cookCount(sessions: sessions, recipeId: target), 1)
    }

    func testCookCountZeroForNoMatches() {
        XCTAssertEqual(cookCount(sessions: [], recipeId: UUID()), 0)
    }

    func testIsMilestoneTrueAtEarlyThresholds() {
        XCTAssertTrue(isMilestone(3))
        XCTAssertTrue(isMilestone(5))
    }

    func testIsMilestoneTrueAtRoundTens() {
        XCTAssertTrue(isMilestone(10))
        XCTAssertTrue(isMilestone(20))
        XCTAssertTrue(isMilestone(30))
    }

    func testIsMilestoneFalseElsewhere() {
        for n in [1, 2, 4, 6, 9, 11, 19, 21, 25] {
            XCTAssertFalse(isMilestone(n), "expected \(n) to not be a milestone")
        }
    }

    func testMilestoneReactionTextSubstitutesCount() {
        XCTAssertEqual(milestoneReactionText(count: 5, template: "第 {n} 次!"), "第 5 次!")
    }

    func testMilestoneReactionTextUsesFallbackWhenTemplateNil() {
        let result = milestoneReactionText(count: 3, template: nil)
        XCTAssertTrue(result.contains("3"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ios && xcodegen generate && xcodebuild -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=<SIM_NAME>' test`
Expected: FAIL — build error, `cookCount`/`isMilestone`/`milestoneReactionText` not
defined.

- [ ] **Step 3: Write the implementation**

Create `ios/Sous/CookHistoryLogic.swift`:

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ios && xcodegen generate && xcodebuild -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=<SIM_NAME>' test`
Expected: PASS, all `CookHistoryLogicTests` green.

- [ ] **Step 5: Commit**

```bash
git add ios/Sous/CookHistoryLogic.swift ios/SousTests/CookHistoryLogicTests.swift
git commit -m "feat(ios): add cook-count and milestone pure logic"
```

---

### Task 3: `AppModel` — load `cook_sessions` and persona copy up front

**Files:**
- Modify: `ios/Sous/AppModel.swift:17` (new published property)
- Modify: `ios/Sous/AppModel.swift:67-73` (`loadAll()`)
- Modify: `ios/Sous/AppModel.swift:183-190` (`loadCookbook()`)

**Interfaces:**
- Consumes: `CookSession` (`Models.swift`), existing `loadPersonaCopy()`
  (`AppModel.swift:160-167`, unchanged).
- Produces: `@Published var cookSessions: [CookSession]`, populated by `loadCookbook()`.
  `loadAll()` now also populates `personaCopy` before the household is first shown.
  Tasks 4-7 all read `model.cookSessions` / `model.personaCopy`.

- [ ] **Step 1: Add the published property**

Old (`ios/Sous/AppModel.swift:17`):
```swift
    @Published var recipes: [Recipe] = []
```

New:
```swift
    @Published var recipes: [Recipe] = []
    @Published var cookSessions: [CookSession] = []
```

- [ ] **Step 2: Fetch `cook_sessions` inside `loadCookbook()`**

Old (`ios/Sous/AppModel.swift:183-190`):
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

New:
```swift
    func loadCookbook() async {
        do {
            recipes = try await client.from("recipes")
                .select("id,slug,title,source_block,body_md,ingredients,steps,created_at")
                .order("created_at", ascending: false)
                .execute().value
            cookSessions = try await client.from("cook_sessions")
                .select("id,recipe_id,started_at,completed_at")
                .execute().value
        } catch { print("cookbook load: \(error)") }
    }
```

- [ ] **Step 3: Load persona copy as part of the standard startup sequence**

`personaCopy` today is only fetched by `OnboardingView`'s own `.task`
(`OnboardingView.swift:44`) — but the presence header on `CounterView` needs it too,
and that view has no such `.task`. Fetch it in `loadAll()` instead, right after
`refreshHousehold()` sets `household.personaId` (leave `OnboardingView`'s own fetch in
place — harmless re-fetch, not worth touching for this change).

Old (`ios/Sous/AppModel.swift:67-73`):
```swift
    func loadAll() async {
        await refreshHousehold()
        await loadTonight()
        await loadMessages()
        await loadWeekBoard()
        await loadShoppingItems()
    }
```

New:
```swift
    func loadAll() async {
        await refreshHousehold()
        await loadPersonaCopy()
        await loadTonight()
        await loadMessages()
        await loadWeekBoard()
        await loadShoppingItems()
    }
```

- [ ] **Step 4: Build and run the full suite to verify no regression**

Run: `cd ios && xcodegen generate && xcodebuild -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=<SIM_NAME>' test`
Expected: build succeeds, all existing tests still pass (no new tests in this task —
see the Global Constraints note on `AppModel` having no dedicated test file).

- [ ] **Step 5: Commit**

```bash
git add ios/Sous/AppModel.swift
git commit -m "feat(ios): load cook_sessions and persona copy on startup"
```

---

### Task 4: `CounterView` — presence copy_pack sweep

**Files:**
- Modify: `ios/Sous/CounterView.swift:82-94` (`header`)

**Interfaces:**
- Consumes: `model.personaCopy["presence_in"|"presence_out"]` (Task 1 migration, Task 3
  load path). `chefIsPresent` (`Models.swift:88-92`) is unchanged.

- [ ] **Step 1: Replace the hardcoded strings**

Old (`ios/Sous/CounterView.swift:82-94`):
```swift
    private var header: some View {
        HStack {
            Text(model.household?.name ?? "…").font(.headline)
            Spacer()
            let present = chefIsPresent(workerSeenAt: model.household?.workerSeenAt)
            Label(present ? "chef in" : "chef out",
                  systemImage: present ? "flame.fill" : "moon.zzz")
                .font(.caption)
                .foregroundStyle(present ? .orange : .secondary)
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }
```

New:
```swift
    private var header: some View {
        HStack {
            Text(model.household?.name ?? "…").font(.headline)
            Spacer()
            let present = chefIsPresent(workerSeenAt: model.household?.workerSeenAt)
            let presenceLabel = present
                ? (model.personaCopy["presence_in"] ?? "chef in")
                : (model.personaCopy["presence_out"] ?? "chef out")
            Label(presenceLabel, systemImage: present ? "flame.fill" : "moon.zzz")
                .font(.caption)
                .foregroundStyle(present ? .orange : .secondary)
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `cd ios && xcodegen generate && xcodebuild -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=<SIM_NAME>' build`
Expected: build succeeds. (No new unit test — this is a two-branch string pick inline
in a view, same un-extracted pattern as `OnboardingView`'s own `copy(_:fallback:)`
helper, which isn't unit tested either. `chefIsPresent` itself, which IS tested via
`PresenceTests.swift`, is untouched.)

- [ ] **Step 3: Commit**

```bash
git add ios/Sous/CounterView.swift
git commit -m "feat(ios): route presence header through copy_pack"
```

---

### Task 5: `RecipeDetailView` — cook count line

**Files:**
- Modify: `ios/Sous/RecipeDetailView.swift:40-55`

**Interfaces:**
- Consumes: `cookCount(sessions:recipeId:)` (Task 2), `model.cookSessions` (Task 3).

- [ ] **Step 1: Add the count line before the "開始煮" button**

Old (`ios/Sous/RecipeDetailView.swift:40-55`):
```swift
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
```

New:
```swift
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
```

- [ ] **Step 2: Build to verify it compiles**

Run: `cd ios && xcodegen generate && xcodebuild -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=<SIM_NAME>' build`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add ios/Sous/RecipeDetailView.swift
git commit -m "feat(ios): show cook count on recipe detail"
```

---

### Task 6: `CookbookView` — cook count badge on grid cards

**Files:**
- Modify: `ios/Sous/CookbookView.swift:32-41` (`recipeCard`)

**Interfaces:**
- Consumes: `cookCount(sessions:recipeId:)` (Task 2), `model.cookSessions` (Task 3).

- [ ] **Step 1: Add the badge line**

Old (`ios/Sous/CookbookView.swift:32-41`):
```swift
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
```

New:
```swift
    private func recipeCard(_ recipe: Recipe) -> some View {
        let cookedCount = cookCount(sessions: model.cookSessions, recipeId: recipe.id)
        return VStack(alignment: .leading, spacing: 4) {
            Text(recipe.title).font(.headline).lineLimit(2)
            Text("\(recipe.ingredients.count) 項食材 · \(recipe.steps.count) 個步驟")
                .font(.caption2).foregroundStyle(.secondary)
            if cookedCount > 0 {
                Text("已煮 \(cookedCount) 次")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
```

Note the explicit `return`: adding the `let cookedCount = ...` statement before the
`VStack` means the function body is no longer a single expression, so Swift's implicit
single-expression return no longer applies.

- [ ] **Step 2: Build to verify it compiles**

Run: `cd ios && xcodegen generate && xcodebuild -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=<SIM_NAME>' build`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add ios/Sous/CookbookView.swift
git commit -m "feat(ios): show cook count badge on cookbook grid cards"
```

---

### Task 7: `CookModeView` — completion count + milestone reaction

**Files:**
- Modify: `ios/Sous/CookModeView.swift:133-141` (`doneView`)
- Modify: `ios/Sous/CookModeView.swift:161-173` (`finishCooking()`)

**Interfaces:**
- Consumes: `cookCount`, `isMilestone`, `milestoneReactionText` (Task 2),
  `model.cookSessions` / `model.personaCopy` (Task 3).

- [ ] **Step 1: Refresh `cookSessions` right after the session is marked complete**

Old (`ios/Sous/CookModeView.swift:161-173`):
```swift
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
```

New:
```swift
    private func finishCooking() async {
        if let sessionId {
            struct Complete: Encodable { let completed_at: String; let step_ticks: [Int] }
            let nowISO = ISO8601DateFormatter().string(from: Date())
            do {
                try await model.client.from("cook_sessions")
                    .update(Complete(completed_at: nowISO, step_ticks: Array(recipe.steps.indices)))
                    .eq("id", value: sessionId)
                    .execute()
                await model.loadCookbook()
            } catch { print("complete cook session: \(error)") }
        }
        phase = planDay != nil ? .verdict : .done
    }
```

`loadCookbook()` only runs after the update succeeds — on failure, `model.cookSessions`
stays as whatever was last loaded, and `doneView` (Step 2) simply won't count this
session, matching `startSession()`'s existing "best-effort, non-blocking" precedent
documented right above it in the file.

- [ ] **Step 2: Show the count or milestone reaction on the completion screen**

Old (`ios/Sous/CookModeView.swift:133-141`):
```swift
    private var doneView: some View {
        VStack(spacing: 16) {
            Label("煮好了!", systemImage: "checkmark.seal.fill")
                .font(.title.bold())
                .foregroundStyle(.green)
            Button("關閉") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
    }
```

New:
```swift
    private var doneView: some View {
        let count = cookCount(sessions: model.cookSessions, recipeId: recipe.id)
        return VStack(spacing: 16) {
            Label("煮好了!", systemImage: "checkmark.seal.fill")
                .font(.title.bold())
                .foregroundStyle(.green)
            if isMilestone(count) {
                Text(milestoneReactionText(count: count, template: model.personaCopy["cook_milestone_reaction"]))
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
            } else if count > 0 {
                Text("已煮 \(count) 次")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Button("關閉") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
    }
```

Same explicit-`return` note as Task 6: the added `let count = ...` statement breaks
implicit single-expression return.

- [ ] **Step 3: Build and run the full suite to verify no regression**

Run: `cd ios && xcodegen generate && xcodebuild -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=<SIM_NAME>' test`
Expected: build succeeds, all tests (including Task 2's new `CookHistoryLogicTests`)
pass.

- [ ] **Step 4: Commit**

```bash
git add ios/Sous/CookModeView.swift
git commit -m "feat(ios): show cook-count milestone reaction on cook-mode completion"
```

---

## Real-use exit check

Per household rule (verify via real use, not sandboxes), run this on a real device or
simulator against the local (or cloud, once merged) stack after all 7 tasks land:

- [ ] Launch the app: confirm the header shows 在廚房/外出中 (not "chef in"/"chef out")
  depending on whether the worker daemon's heartbeat is recent.
- [ ] Open the cookbook: confirm any recipe with prior `cook_sessions` shows a "已煮 N
  次" badge on its grid card, and recipes never cooked show no badge.
- [ ] Open that recipe's detail view: confirm the same count appears near the verdict
  history.
- [ ] Cook a recipe end-to-end (prep → teleprompter → finish). If its new count lands on
  3, 5, or a multiple of 10, confirm the milestone reaction line appears instead of the
  plain count; otherwise confirm the plain "已煮 N 次" line appears.
- [ ] Confirm the cookbook/recipe-detail counts reflect the just-finished session
  immediately (no relaunch needed) once back out of cook mode.
