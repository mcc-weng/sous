# M3 Pass 2a — Swipe Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the shared swipe-card interaction, the Explore Deck (D3), the Ritual
Swipe Session (B1, replacing the guided Q&A as a second entry point alongside it), the
swipe-up modification loop, and the ritual cadence Settings UI — per
`docs/superpowers/specs/2026-08-09-m3-pass2-swipe-judge-design.md` §7 "Pass 2a".

**Architecture:** A pure-logic `SwipeDeckLogic.swift` (drag math, commit thresholds,
deck-advance/reinsert state machine) drives a shared `SwipeCardView` + stack, consumed
by two screens: `ExploreDeckView` (client-only — candidates come from already-loaded
`model.recipes`, swipes write directly to `recipe_swipes`, never touches the plan) and
`RitualSwipeSessionView` (candidates come from a brain-generated weekly deck). The
ritual side needed one real correction found during this plan's own research: a live
brain turn takes 100–150s, so per-card or per-rejection brain calls are a non-starter —
the `ritual` job's existing `chat`/`ritual` kind gains a `mode` payload discriminator
(mirroring `notif_generate`'s existing `notif_kind` pattern) with two new sub-modes:
`swipe_deal` (one brain turn, generates 2–3 candidates for all 7 days up front, written
to `jobs.result` — a column that exists today but no handler has ever used) and
`swipe_lock` (a mechanical pass-through to the existing, already-validated `set-plan`
verb once all 7 days are confirmed by swiping — no re-deciding). The client polls the
specific job row it created (`jobs.status`/`result`) rather than waiting on a chat
reply, consistent with the app's established polling-not-realtime pattern
(`AppModel.waitForReply`'s doc comment: realtime `postgres_changes` confirmed
non-functional here on 2026-07-19). Swipe-up (但是…) fires a new `recipe_tweak` job
kind, same polling contract, producing one revised candidate reinserted into the local
deck a few cards later.

**Tech Stack:** SwiftUI (iOS 17+), XCTest, Supabase Postgres migration (SQL), Python
worker (existing `sous_worker` package, `state_api.py`). No new package dependencies.

## Global Constraints

- **No border radius on paper** — cards are square-cornered per every existing screen;
  the only exception anywhere in 書與灶 is the Cook Mode timer ring, not touched here.
- **Persona-tintable**: any seal/accent colour is `model.personaTint`, never a
  hardcoded hex.
- **Traditional Chinese primary**: `serifFontName(bundled: FontBook.isSerifBundled)` /
  `sansFontName(bundled: FontBook.isSansBundled)` (`DesignTokens.swift`) for all text.
- **copy_pack discipline applies to persona voice, not generic UI chrome** (established
  Pass 1b precedent). Card footer labels (換一道/但是…/排入這天/下一張/收藏) are
  hardcoded Chinese UI chrome, not new copy_pack keys — they're button labels, not
  持久's voice.
- Minimum touch target 44pt.
- **Real device target**: iPhone 13 mini, 375pt logical width.
- **Migration must reach production, not just local** — `supabase db push --linked`
  required before any real-device exit check, per
  `[[feedback-real-device-check-needs-cloud-migrations]]`.
- **Client polling interval: 2s** — matches `AppModel.waitForReply`'s existing
  precedent exactly (not the worker's 3s poll, which is a different loop).
- **New client-insertable job kinds need an RLS policy update** — `jobs_write` only
  ever allows an explicit kind allowlist (`0002_rls.sql`, extended by
  `0005_jobs_allow_ritual_kind.sql`/`0006_jobs_allow_recipe_intake_kind.sql`); adding
  `recipe_tweak` follows that exact pattern (Task 5).
- Design reference: `design_handoff_sous_m3/README.md` §B1, §D3, §A2 ("想吃什麼"
  section), §E3 (儀式節奏), §Motion, §Accessibility.
- Build/test command shape (iOS): `cd ios && xcodegen generate && xcodebuild test -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' 2>&1 | tail -30`
- Build/test command shape (worker): `cd worker && .venv/bin/python -m pytest tests/ -x -q`
- Build/test command shape (SQL): `supabase db reset` (local), verified with
  `docker exec -it $(docker ps -qf "name=supabase_db") psql -U postgres -c "..."`.

---

## Shared data shapes (referenced by Tasks 2, 5, 6, 7)

Every card — whether from the Explore Deck's client-side pool, a brain-generated
ritual candidate, or a `recipe_tweak` result — has the same shape. Defined once here so
task Interfaces blocks can cite it by name without redefining it per task.

```swift
/// One swipeable candidate. `recipeId` is nil for a ritual-only free-text proposal
/// (today's guided ritual never calls save-recipe for most dishes — see design spec
/// §4's "Ritual deck delivery" correction); Explore Deck candidates always have one.
struct SwipeCandidate: Identifiable, Equatable {
    let id: UUID // client-generated (UUID()) — not a DB row id, this is ephemeral session state
    let recipeId: UUID?
    let dishText: String       // display name — either the recipe's title or the free-text proposal
    let mode: String?          // fast/batch/leftover/play — ritual context only, nil for Explore
    let meta: String?          // "~25分 · 快手 · 蛋白質60g" — ritual context only
    let pitch: String?         // his one-line hook, ritual context only
    let prepNote: String?
    // Ritual context only (always [] for Explore, which never touches the plan).
    // Carried per-candidate rather than computed at lock time because lock has no
    // brain turn to ask (Task 6's swipe_lock is a mechanical pass-through) — the
    // ingredients for whichever candidate ends up confirmed must already be on the
    // card when it's dealt.
    var shoppingItems: [SwipeShoppingItem] = []
    var isUpdated: Bool = false // true when this card is a recipe_tweak re-entry — drives the 已更新 tag
}

/// Mirrors `ShoppingItem`'s name/qty/section shape minus `id`/`checked`, which don't
/// exist until `set-plan` actually inserts a row — see `state_api.set_plan`'s
/// `--shopping-items` JSON shape, which this maps onto directly at lock (Task 7).
struct SwipeShoppingItem: Codable, Equatable {
    let name: String
    let qty: String?
    let section: String?
}
```

Ritual `swipe_deal` result JSON (`jobs.result`, worker-written):

```json
{
  "mode": "swipe_deal",
  "days": [
    {"date": "2026-08-17", "candidates": [
      {"recipe_id": null, "dish_text": "三杯雞", "dish_mode": "fast",
       "meta": "~25分 · 快手 · 蛋白質58g", "pitch": "冰箱雞腿正好用掉,鹹香下飯",
       "prep_note": "雞腿前一晚醃",
       "shopping_items": [{"name": "chicken thigh fillets", "qty": "4", "section": "meat"},
                          {"name": "basil", "qty": "1 bunch", "section": "produce"}]},
      {"recipe_id": null, "dish_text": "番茄炒蛋", "dish_mode": "fast",
       "meta": "~15分 · 快手 · 蛋白質22g", "pitch": "十分鐘搞定,配一碗白飯剛好",
       "prep_note": null,
       "shopping_items": [{"name": "tomatoes", "qty": "3", "section": "produce"},
                          {"name": "eggs", "qty": "4", "section": "dairy"}]}
    ]}
  ]
}
```

`recipe_tweak` result JSON (same single-candidate shape, no `days` wrapper):

```json
{"recipe_id": null, "dish_text": "無蝦味噌湯", "dish_mode": "fast",
 "meta": "~10分 · 快手", "pitch": "拿掉蝦,豆腐蔥花照樣鮮甜",
 "prep_note": null,
 "shopping_items": [{"name": "miso paste", "qty": "2 tbsp", "section": "pantry"},
                    {"name": "tofu", "qty": "1 block", "section": "dairy"}]}
```

---

## Task 1: Migration — `recipe_swipes`, ritual cadence columns, `recipe_tweak` RLS

**Files:**
- Create: `supabase/migrations/0020_recipe_swipes_ritual_cadence.sql`

**Interfaces:**
- Produces: `recipe_swipes` table; `households.ritual_cadence_interval`,
  `households.ritual_cadence_anchor_day`; `jobs_write` policy extended to allow
  `recipe_tweak`.
- Consumes: `public.is_member(hid uuid)` (`0002_rls.sql`).

- [ ] **Step 1: Write the migration**

```sql
-- supabase/migrations/0020_recipe_swipes_ritual_cadence.sql
-- Pass 2a (swipe foundation): logs every swipe (Explore + Ritual context), adds
-- household ritual-cadence settings, and allows the client to insert recipe_tweak
-- jobs directly (swipe-up modification, Task 5). See
-- docs/superpowers/specs/2026-08-09-m3-pass2-swipe-judge-design.md §4/§7.

create table recipe_swipes (
  id           uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  -- Nullable: most of today's ritual proposals are free text (set-plan never calls
  -- save-recipe) — see the design spec's "Ritual deck delivery" correction. Explore
  -- Deck swipes always carry a real recipe_id since that surface only browses the
  -- cookbook; Ritual Session swipes carry one only when the candidate is a cookbook
  -- recipe.
  recipe_id    uuid references recipes(id),
  dish_text    text,
  action       text not null check (action in ('like','pass','modify')),
  context      text not null check (context in ('explore','ritual')),
  note         text,
  created_at   timestamptz not null default now(),
  check (recipe_id is not null or dish_text is not null)
);
create index recipe_swipes_household_created on recipe_swipes (household_id, created_at desc);

alter table households
  add column ritual_cadence_interval text not null default 'weekly'
    check (ritual_cadence_interval in ('weekly', 'biweekly')),
  -- Sun=1..Sat=7 — matches Calendar.component(.weekday) already used throughout the
  -- iOS app (WeekBoardView.weekdayGlyph), not an arbitrary new convention.
  add column ritual_cadence_anchor_day smallint not null default 1
    check (ritual_cadence_anchor_day between 1 and 7);

alter table recipe_swipes enable row level security;
create policy recipe_swipes_rw on recipe_swipes for all to authenticated
  using (is_member(household_id)) with check (is_member(household_id));

-- Same pattern as 0005/0006: jobs_write only ever allows an explicit kind allowlist.
-- recipe_tweak is inserted directly by the client on swipe-up (Task 5), not proxied
-- through a chat message first.
alter policy jobs_write on jobs
  with check (is_member(household_id) and kind in ('chat', 'ritual', 'recipe_tweak'));
```

- [ ] **Step 2: Apply locally and verify**

Run: `supabase db reset`

Then: `docker exec -it $(docker ps -qf "name=supabase_db") psql -U postgres -c "\d recipe_swipes" -c "\d households" | grep -E "ritual_cadence|recipe_swipes"`

Expected: `recipe_swipes` table listed with all columns; `households` shows
`ritual_cadence_interval`/`ritual_cadence_anchor_day`.

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/0020_recipe_swipes_ritual_cadence.sql
git commit -m "feat(db): recipe_swipes table, ritual cadence columns, recipe_tweak job RLS"
```

---

## Task 2: `SwipeDeckLogic` — pure drag/deck state machine

**Files:**
- Create: `ios/Sous/SwipeDeckLogic.swift`
- Test: `ios/SousTests/SwipeDeckLogicTests.swift`

**Interfaces:**
- Consumes: `SwipeCandidate` (Shared data shapes, above).
- Produces:
  - `enum SwipeDirection { case like, pass, modify }`
  - `func swipeDirection(dragWidth: CGFloat, dragHeight: CGFloat, commitThreshold: CGFloat = 80) -> SwipeDirection?` — nil while still under threshold.
  - `func cardRotation(dragWidth: CGFloat) -> Double` — `dragWidth * 0.05` (degrees), per README B1 "Drag: `translate(dx, dy) rotate(dx × 0.05deg)`".
  - `func stampOpacity(dragWidth: CGFloat, commitThreshold: CGFloat = 80) -> Double` — `min(abs(dragWidth) / commitThreshold, 1)`, per README "opacity bound to `|dx| / 80`".
  - `struct SwipeDeckState { var candidates: [SwipeCandidate]; var pendingReinserts: [(afterCount: Int, candidate: SwipeCandidate)] }` with:
    - `mutating func advance() -> SwipeCandidate?` — pops and returns the front candidate, applying any due reinsert (see Step 1's test for exact due-timing).
    - `mutating func scheduleReinsert(_ candidate: SwipeCandidate, afterCards: Int = 3)` — queues a `已更新`-tagged card to surface a few cards later, per mechanics spec §2.3 "reinserted into the deck a few cards later."
    - `var current: SwipeCandidate? { candidates.first }`

This is TDD-shaped — pure functions/structs, no view code, no I/O.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Sous

final class SwipeDeckLogicTests: XCTestCase {
    func test_swipeDirection_belowThreshold_isNil() {
        XCTAssertNil(swipeDirection(dragWidth: 40, dragHeight: 0))
    }

    func test_swipeDirection_rightPastThreshold_isLike() {
        XCTAssertEqual(swipeDirection(dragWidth: 90, dragHeight: 0), .like)
    }

    func test_swipeDirection_leftPastThreshold_isPass() {
        XCTAssertEqual(swipeDirection(dragWidth: -90, dragHeight: 0), .pass)
    }

    func test_swipeDirection_upPastThreshold_isModify() {
        XCTAssertEqual(swipeDirection(dragWidth: 10, dragHeight: -90), .modify)
    }

    func test_swipeDirection_horizontalDominatesWhenBothPastThreshold() {
        // a diagonal drag that clears both thresholds resolves to the larger axis
        XCTAssertEqual(swipeDirection(dragWidth: 90, dragHeight: -85), .like)
    }

    func test_cardRotation_scalesWithDragWidth() {
        XCTAssertEqual(cardRotation(dragWidth: 100), 5.0, accuracy: 0.0001)
        XCTAssertEqual(cardRotation(dragWidth: -40), -2.0, accuracy: 0.0001)
    }

    func test_stampOpacity_clampsAtOne() {
        XCTAssertEqual(stampOpacity(dragWidth: 40), 0.5, accuracy: 0.0001)
        XCTAssertEqual(stampOpacity(dragWidth: 200), 1.0, accuracy: 0.0001)
    }

    private func makeCandidate(_ text: String) -> SwipeCandidate {
        SwipeCandidate(id: UUID(), recipeId: nil, dishText: text, mode: nil,
                       meta: nil, pitch: nil, prepNote: nil)
    }

    func test_advance_popsFrontCandidate() {
        var state = SwipeDeckState(candidates: [makeCandidate("A"), makeCandidate("B")],
                                    pendingReinserts: [])
        let popped = state.advance()
        XCTAssertEqual(popped?.dishText, "A")
        XCTAssertEqual(state.candidates.map(\.dishText), ["B"])
    }

    func test_scheduleReinsert_surfacesAfterNAdvances_taggedUpdated() {
        var state = SwipeDeckState(candidates: [makeCandidate("A"), makeCandidate("B")],
                                    pendingReinserts: [])
        state.scheduleReinsert(makeCandidate("Revised"), afterCards: 2)
        _ = state.advance() // consumes A, 1 card seen
        _ = state.advance() // consumes B, 2 cards seen — reinsert now due
        XCTAssertEqual(state.candidates.first?.dishText, "Revised")
        XCTAssertEqual(state.candidates.first?.isUpdated, true)
    }

    func test_scheduleReinsert_notDueBeforeThreshold() {
        var state = SwipeDeckState(candidates: [makeCandidate("A")], pendingReinserts: [])
        state.scheduleReinsert(makeCandidate("Revised"), afterCards: 3)
        _ = state.advance() // 1 card seen, not due yet
        XCTAssertFalse(state.candidates.contains { $0.dishText == "Revised" })
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ios && xcodegen generate && xcodebuild test -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' -only-testing:SousTests/SwipeDeckLogicTests 2>&1 | tail -30`

Expected: FAIL — `SwipeCandidate`/`swipeDirection`/etc. not defined.

- [ ] **Step 3: Implement `SwipeDeckLogic.swift`**

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ios && xcodebuild test -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' -only-testing:SousTests/SwipeDeckLogicTests 2>&1 | tail -30`

Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/Sous/SwipeDeckLogic.swift ios/SousTests/SwipeDeckLogicTests.swift
git commit -m "feat(ios): SwipeDeckLogic — pure drag math and deck/reinsert state machine"
```

---

## Task 3: `SwipeCardView` + stack + 但是… panel

**Files:**
- Create: `ios/Sous/SwipeCardView.swift`

**Interfaces:**
- Consumes: `SwipeCandidate`, `SwipeDirection`, `swipeDirection`, `cardRotation`,
  `stampOpacity` (Task 2).
- Produces:
  - `struct SwipeCardStack: View` — init params: `candidates: [SwipeCandidate]`
    (front 3 shown, back two per README "three sheets"), `dayLabel: String?` (nil in
    Explore context — no day chip per §D3 "distinguished by what is absent"),
    `progressFilled: Int?`, `progressTotal: Int?` (nil in Explore — no progress rule),
    `onSwipe: (SwipeCandidate, SwipeDirection) -> Void`,
    `onModifyNote: (SwipeCandidate, String) -> Void` (called when 但是… is submitted,
    distinct from a plain up-swipe with no text).
  - Not independently unit-testable (pure SwiftUI view); acceptance is visual +
    the build succeeding, same bar as `StageTokens`/`PaperTokens` themselves.

- [ ] **Step 1: Implement**

```swift
import SwiftUI

/// B1 §滑牌儀式 / D3 §探索牌組 — the shared three-sheet swipeable card stack. The two
/// screens differ only in what's passed: Explore omits `dayLabel`/progress (README:
/// "distinguished by what is absent — no day chip, no progress rule, no lock").
struct SwipeCardStack: View {
    let candidates: [SwipeCandidate]
    let dayLabel: String?
    let progressFilled: Int?
    let progressTotal: Int?
    let onSwipe: (SwipeCandidate, SwipeDirection) -> Void
    let onModifyNote: (SwipeCandidate, String) -> Void

    @EnvironmentObject private var model: AppModel
    @GestureState private var dragOffset: CGSize = .zero
    @State private var showModifyPanel = false
    @State private var modifyText = ""

    private var serifName: String { serifFontName(bundled: FontBook.isSerifBundled) }
    private var sansName: String { sansFontName(bundled: FontBook.isSansBundled) }

    var body: some View {
        VStack(spacing: 0) {
            if let filled = progressFilled, let total = progressTotal {
                progressHeader(filled: filled, total: total)
            }
            ZStack {
                ForEach(Array(candidates.prefix(3).enumerated().reversed()), id: \.element.id) { index, candidate in
                    cardView(candidate)
                        .rotationEffect(.degrees(index == 0 ? cardRotation(dragWidth: dragOffset.width) : (index == 1 ? -0.9 : 1.5)))
                        .offset(index == 0 ? dragOffset : .zero)
                        .offset(y: index == 1 ? 3 : (index == 2 ? 7 : 0))
                        .zIndex(Double(3 - index))
                        .allowsHitTesting(index == 0)
                        .gesture(index == 0 ? dragGesture(for: candidate) : nil)
                }
            }
            .padding(.horizontal, Spacing.deckMargin)

            if showModifyPanel, let current = candidates.first {
                modifyPanel(current)
            } else {
                footerBar
            }
        }
    }

    private func progressHeader(filled: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("已排 \(filled) / \(total) 天")
                Spacer()
                Text("還剩 \(total - filled) 天")
            }
            .font(.custom(sansName, size: 10.5))
            .tracking(2.52) // .24em at 10.5pt
            .foregroundStyle(PaperTokens.inkDim)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(PaperTokens.rule).frame(height: 1)
                    Rectangle().fill(model.personaTint)
                        .frame(width: geo.size.width * CGFloat(filled) / CGFloat(total), height: 1)
                        .animation(.easeOut(duration: 0.3), value: filled)
                }
            }
            .frame(height: 1)
        }
        .padding(.horizontal, Spacing.deckMargin)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.sm)
    }

    @ViewBuilder
    private func cardView(_ candidate: SwipeCandidate) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let dayLabel {
                    Text(dayLabel)
                        .font(.custom(sansName, size: 10))
                        .tracking(4.2) // .42em at 10pt
                        .foregroundStyle(model.personaTint)
                }
                Spacer()
                if candidate.isUpdated {
                    Text("已依「\(modifyText.isEmpty ? "你的要求" : modifyText)」改過")
                        .font(.custom(sansName, size: 9.5))
                        .foregroundStyle(PaperTokens.inkDim)
                }
            }
            Rectangle()
                .fill(PaperTokens.stockAlt)
                .frame(height: 130) // photo plate — hatched placeholder per handoff Assets note
                .overlay(Text("料理照片").font(.custom(sansName, size: 10)).foregroundStyle(PaperTokens.inkFaint))
                .padding(.top, dayLabel == nil ? 0 : 10)
            Text(candidate.dishText)
                .font(.custom(serifName, size: 28))
                .foregroundStyle(PaperTokens.ink)
                .padding(.top, 14)
            if let meta = candidate.meta {
                Text(meta)
                    .font(.custom(sansName, size: 10.5))
                    .tracking(2.1)
                    .foregroundStyle(PaperTokens.inkDim)
                    .padding(.top, 4)
            }
            Rectangle().fill(PaperTokens.rule).frame(height: 1).padding(.vertical, 12)
            if let pitch = candidate.pitch {
                Text(pitch)
                    .font(.custom(serifName, size: 13.5).italic())
                    .lineSpacing(13.5) // lh 2.0
                    .foregroundStyle(PaperTokens.inkDim)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PaperTokens.slip)
        .overlay(stampOverlay)
    }

    @ViewBuilder
    private var stampOverlay: some View {
        let opacity = stampOpacity(dragWidth: dragOffset.width)
        if dragOffset.width > 8 {
            stamp("排入", color: model.personaTint).opacity(opacity)
        } else if dragOffset.width < -8 {
            stamp("換道", color: PaperTokens.ink).opacity(opacity)
        }
    }

    private func stamp(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.custom(sansName, size: 22))
            .foregroundStyle(color)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .overlay(Rectangle().stroke(color, lineWidth: 2))
            .rotationEffect(.degrees(color == model.personaTint ? -12 : 12))
    }

    private func dragGesture(for candidate: SwipeCandidate) -> some Gesture {
        DragGesture()
            .updating($dragOffset) { value, state, _ in state = value.translation }
            .onEnded { value in
                guard let direction = swipeDirection(dragWidth: value.translation.width,
                                                     dragHeight: value.translation.height) else { return }
                if direction == .modify {
                    showModifyPanel = true
                } else {
                    onSwipe(candidate, direction)
                }
            }
    }

    private var footerBar: some View {
        HStack(spacing: 0) {
            footerButton("換一道") {
                if let current = candidates.first { onSwipe(current, .pass) }
            }
            Rectangle().fill(PaperTokens.rule).frame(width: 1)
            footerButton("但是…") { showModifyPanel = true }
                .frame(width: 78)
            Rectangle().fill(PaperTokens.rule).frame(width: 1)
            footerButton("排入這天", emphasized: true) {
                if let current = candidates.first { onSwipe(current, .like) }
            }
        }
        .frame(height: 50)
        .overlay(Rectangle().stroke(PaperTokens.rule, lineWidth: 1))
        .padding(.horizontal, Spacing.deckMargin)
        .padding(.vertical, Spacing.md)
    }

    private func footerButton(_ title: String, emphasized: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.custom(sansName, size: 12.5))
                .fontWeight(emphasized ? .semibold : .regular)
                .foregroundStyle(emphasized ? model.personaTint : PaperTokens.ink)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
    }

    private func modifyPanel(_ candidate: SwipeCandidate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("但是…")
                .font(.custom(serifName, size: 15))
                .foregroundStyle(model.personaTint)
            TextField("像是「沒有蝦」「想要辣一點」", text: $modifyText)
                .font(.custom(sansName, size: 13.5))
                .padding(.bottom, 6)
                .overlay(Rectangle().fill(PaperTokens.ink.opacity(0.34)).frame(height: 1), alignment: .bottom)
            Text("不用等 —— 牌繼續發,改好了它會再出現一次。")
                .font(.custom(sansName, size: 10.5).weight(.light))
                .foregroundStyle(PaperTokens.inkDim)
            HStack {
                Button("取消") { showModifyPanel = false; modifyText = "" }
                    .font(.custom(sansName, size: 12.5))
                Spacer()
                Button("交給小當家改") {
                    guard !modifyText.isEmpty else { return }
                    onModifyNote(candidate, modifyText)
                    showModifyPanel = false
                    modifyText = ""
                }
                .font(.custom(sansName, size: 12.5)).fontWeight(.semibold)
                .foregroundStyle(model.personaTint)
            }
        }
        .padding(16)
        .background(PaperTokens.stock)
        .overlay(Rectangle().fill(model.personaTint).frame(height: 2), alignment: .top)
        .padding(.horizontal, Spacing.deckMargin)
        .padding(.bottom, Spacing.md)
    }
}
```

- [ ] **Step 2: Build**

Run: `cd ios && xcodegen generate && xcodebuild build -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' 2>&1 | tail -20`

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add ios/Sous/SwipeCardView.swift
git commit -m "feat(ios): SwipeCardStack — shared card/stack/但是…panel component"
```

---

## Task 4: Explore Deck (D3) + Kitchen Counter entry point

**Files:**
- Create: `ios/Sous/ExploreDeckView.swift`
- Modify: `ios/Sous/CounterView.swift` (add 想吃什麼 peek card + `.fullScreenCover`)
- Modify: `ios/Sous/AppModel.swift` (add `recordSwipe`, `recentPassedRecipeIds`)
- Test: `ios/SousTests/ExploreDeckLogicTests.swift`

**Interfaces:**
- Consumes: `SwipeCardStack`, `SwipeCandidate`, `SwipeDeckState` (Tasks 2–3),
  `model.recipes: [Recipe]` (already loaded by `loadCookbook()`), `AppModel.client`.
- Produces: `AppModel.recordSwipe(recipeId: UUID, action: String, context: String, note: String?) async`;
  `func exploreCandidates(recipes: [Recipe], recentlyPassed: Set<UUID>) -> [SwipeCandidate]`
  (pure, testable — Task 5's `RitualSwipeSessionView` does not consume this, it has its
  own brain-sourced candidates).

Client-only screen — no brain job for ordinary browsing. Candidates come from
`model.recipes` (already fetched), shuffled, excluding recipes passed within the same
day (a cheap, good-enough "don't immediately re-show what I just rejected" rule —
`recipe_swipes` decay policy is explicitly left to later per the design spec §9).

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Sous

final class ExploreDeckLogicTests: XCTestCase {
    private func makeRecipe(_ id: UUID, _ title: String) -> Recipe {
        Recipe(id: id, slug: title, title: title, sourceBlock: nil, bodyMd: "",
              ingredients: [], steps: [], createdAt: Date(), servings: 2)
    }

    func test_exploreCandidates_excludesRecentlyPassed() {
        let keep = UUID(); let dropped = UUID()
        let recipes = [makeRecipe(keep, "留下"), makeRecipe(dropped, "剔除")]
        let result = exploreCandidates(recipes: recipes, recentlyPassed: [dropped])
        XCTAssertEqual(result.map(\.recipeId), [keep])
    }

    func test_exploreCandidates_mapsRecipeFields() {
        let id = UUID()
        let result = exploreCandidates(recipes: [makeRecipe(id, "蔥油雞")], recentlyPassed: [])
        XCTAssertEqual(result.first?.recipeId, id)
        XCTAssertEqual(result.first?.dishText, "蔥油雞")
        XCTAssertNil(result.first?.mode) // Explore cards carry no day/mode context
    }

    func test_exploreCandidates_emptyWhenAllPassed() {
        let id = UUID()
        XCTAssertTrue(exploreCandidates(recipes: [makeRecipe(id, "X")], recentlyPassed: [id]).isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios && xcodebuild test -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' -only-testing:SousTests/ExploreDeckLogicTests 2>&1 | tail -30`

Expected: FAIL — `exploreCandidates` not defined.

- [ ] **Step 3: Implement `ExploreDeckView.swift`**

```swift
import SwiftUI

/// D3 · 探索牌組 — Reference: design_handoff_sous_m3/README.md "D3 · 探索牌組".
/// Client-only: candidates come from already-loaded `model.recipes`, no brain job for
/// ordinary browsing (only swipe-up fires one — see the 但是… wiring below, which
/// reuses the exact same recipe_tweak job Task 7's Ritual Session uses, Task 5).
struct ExploreDeckView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var deck = SwipeDeckState(candidates: [], pendingReinserts: [])

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("探索牌組").font(.custom(serifFontName(bundled: FontBook.isSerifBundled), size: 17))
                Spacer()
                Button("關閉") { dismiss() }
            }
            .padding(.horizontal, Spacing.pageMargin)
            .padding(.top, Spacing.md)

            if deck.candidates.isEmpty {
                Spacer()
                Text("這批牌先看完了").foregroundStyle(PaperTokens.inkDim)
                Spacer()
            } else {
                SwipeCardStack(
                    candidates: deck.candidates, dayLabel: nil,
                    progressFilled: nil, progressTotal: nil,
                    onSwipe: { candidate, direction in handleSwipe(candidate, direction) },
                    onModifyNote: { candidate, note in handleModify(candidate, note) }
                )
            }
        }
        .background(PaperTokens.stock)
        .task {
            let recentlyPassed = await model.recentPassedRecipeIds(context: "explore")
            deck.candidates = exploreCandidates(recipes: model.recipes, recentlyPassed: recentlyPassed)
        }
    }

    private func handleSwipe(_ candidate: SwipeCandidate, _ direction: SwipeDirection) {
        deck.advance()
        guard let recipeId = candidate.recipeId else { return }
        let action = direction == .like ? "like" : "pass"
        Task { await model.recordSwipe(recipeId: recipeId, dishText: nil, action: action,
                                       context: "explore", note: nil) }
    }

    private func handleModify(_ candidate: SwipeCandidate, _ note: String) {
        deck.advance()
        guard let recipeId = candidate.recipeId else { return }
        Task {
            await model.recordSwipe(recipeId: recipeId, dishText: nil, action: "modify",
                                    context: "explore", note: note)
            if let revised = await model.requestRecipeTweak(originRecipeId: recipeId,
                                                             originDishText: candidate.dishText,
                                                             note: note, context: "explore", date: nil) {
                deck.scheduleReinsert(revised)
            }
        }
    }
}

/// Pure — testable without a live `AppModel`. `recentlyPassed` excludes cards the
/// user already rejected today; the exact decay window is left to planning per the
/// design spec §9, same-day is a reasonable, cheap default.
func exploreCandidates(recipes: [Recipe], recentlyPassed: Set<UUID>) -> [SwipeCandidate] {
    recipes
        .filter { !recentlyPassed.contains($0.id) }
        .map { SwipeCandidate(id: UUID(), recipeId: $0.id, dishText: $0.title,
                              mode: nil, meta: nil, pitch: nil, prepNote: nil) }
}
```

- [ ] **Step 4: Add `AppModel` methods**

Add to `ios/Sous/AppModel.swift`, near `toggleShoppingItem` (same "direct write, no
job" family for `recordSwipe`; `requestRecipeTweak` is the one exception that does
fire a job, documented inline):

```swift
    /// Direct write, no job — matches `toggleShoppingItem`'s precedent. A swipe is a
    /// pure user action; only a swipe-up *modification* (handled separately, below)
    /// needs the brain.
    func recordSwipe(recipeId: UUID?, dishText: String?, action: String,
                     context: String, note: String?) async {
        struct NewSwipe: Encodable {
            let household_id: UUID
            let recipe_id: UUID?
            let dish_text: String?
            let action: String
            let context: String
            let note: String?
        }
        guard let household else { return }
        do {
            try await client.from("recipe_swipes")
                .insert(NewSwipe(household_id: household.id, recipe_id: recipeId,
                                 dish_text: dishText, action: action, context: context, note: note))
                .execute()
        } catch { print("record swipe: \(error)") }
    }

    /// Recipe ids passed (not liked) today, in the given context — feeds
    /// `exploreCandidates`'s exclusion filter.
    func recentPassedRecipeIds(context: String) async -> Set<UUID> {
        struct SwipeRow: Decodable { let recipe_id: UUID? }
        guard let household else { return [] }
        let tz = TimeZone(identifier: household.timezone) ?? .current
        do {
            let rows: [SwipeRow] = try await client.from("recipe_swipes")
                .select("recipe_id")
                .eq("household_id", value: household.id)
                .eq("context", value: context)
                .eq("action", value: "pass")
                .gte("created_at", value: dateString(Date(), timezone: tz))
                .execute().value
            return Set(rows.compactMap(\.recipe_id))
        } catch { print("recent passed load: \(error)"); return [] }
    }

    /// Fires a recipe_tweak job and polls for its result — see Task 5 for the worker
    /// side. 2s poll, matching `waitForReply`'s established interval. Returns nil on
    /// timeout/failure; caller (Explore/Ritual) simply doesn't reinsert a card, which
    /// degrades gracefully (mechanics spec §2.3 never guarantees a reinsert succeeds,
    /// only that the deck itself is never blocked).
    func requestRecipeTweak(originRecipeId: UUID?, originDishText: String, note: String,
                            context: String, date: String?) async -> SwipeCandidate? {
        struct Payload: Encodable {
            let origin_recipe_id: UUID?
            let origin_dish_text: String
            let note: String
            let context: String
            let date: String?
        }
        struct NewJob: Encodable {
            let household_id: UUID
            let kind: String
            let payload: Payload
        }
        struct JobRow: Decodable { let id: UUID }
        guard let household else { return nil }
        do {
            let job: JobRow = try await client.from("jobs")
                .insert(NewJob(household_id: household.id, kind: "recipe_tweak",
                               payload: .init(origin_recipe_id: originRecipeId,
                                             origin_dish_text: originDishText, note: note,
                                             context: context, date: date)))
                .select("id").single().execute().value
            // SwipeCandidate.modifyNote (added during Task 3's review — carries the
            // note text for the 已依「...」改過 badge) isn't part of the job result
            // itself; set it here from the note this call already has, so
            // SwipeCardView reads the real note instead of its fallback text.
            guard var revised = await pollJobResult(jobId: job.id) else { return nil }
            revised.modifyNote = note
            return revised
        } catch { print("recipe tweak request: \(error)"); return nil }
    }

    /// Shared polling helper for both recipe_tweak and ritual swipe_deal/swipe_lock
    /// (Task 7 also calls this). 2s interval, 90s ceiling — a tweak/deal job's own
    /// timeout is the worker's chat_timeout_sec (480s) but the UI shouldn't hang the
    /// deck that long; giving up after 90s just means no reinsert/no deck this attempt,
    /// never a crash.
    func pollJobResult(jobId: UUID) async -> SwipeCandidate? {
        struct JobStatusRow: Decodable { let status: String; let result: JobResultPayload? }
        struct JobResultPayload: Decodable {
            let recipe_id: UUID?; let dish_text: String?; let dish_mode: String?
            let meta: String?; let pitch: String?; let prep_note: String?
            let shopping_items: [SwipeShoppingItem]?
        }
        for _ in 0..<45 { // 45 * 2s = 90s ceiling
            do {
                let row: JobStatusRow = try await client.from("jobs")
                    .select("status,result").eq("id", value: jobId).single().execute().value
                if row.status == "done", let result = row.result {
                    return SwipeCandidate(id: UUID(), recipeId: result.recipe_id,
                                          dishText: result.dish_text ?? "", mode: result.dish_mode,
                                          meta: result.meta, pitch: result.pitch, prepNote: result.prep_note,
                                          shoppingItems: result.shopping_items ?? [])
                }
                if row.status == "failed" { return nil }
            } catch { print("poll job result: \(error)") }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return nil
    }
```

- [ ] **Step 5: Wire the Kitchen Counter entry point**

Modify `ios/Sous/CounterView.swift` — add state and the 想吃什麼 peek card between the
`開始做菜` button and `footerNav` (matching README A2's layout order), plus the
`.fullScreenCover`, same tier as Cook Mode's:

```swift
    @State private var showExploreDeck = false
```

```swift
                exploreDeckPeek
```

```swift
    private var exploreDeckPeek: some View {
        Button { showExploreDeck = true } label: {
            HStack(spacing: 12) {
                Rectangle().fill(PaperTokens.stockAlt).frame(width: 54, height: 54)
                VStack(alignment: .leading, spacing: 3) {
                    Text("想吃什麼")
                        .font(.custom(sansFontName(bundled: FontBook.isSansBundled), size: 10))
                        .tracking(2)
                        .foregroundStyle(PaperTokens.inkFaint)
                    Text("滑一下,我記著")
                        .font(.custom(serifFontName(bundled: FontBook.isSerifBundled), size: 14.5))
                        .foregroundStyle(PaperTokens.ink)
                }
                Spacer()
                Image(systemName: "arrow.right").foregroundStyle(model.personaTint)
            }
            .padding(14)
            .overlay(Rectangle().stroke(PaperTokens.rule, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
```

Add alongside the existing `.fullScreenCover(isPresented: $showCookModeForTonight)`:

```swift
        .fullScreenCover(isPresented: $showExploreDeck) {
            ExploreDeckView().environmentObject(model)
        }
```

- [ ] **Step 6: Run tests, then build**

Run: `cd ios && xcodebuild test -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' -only-testing:SousTests/ExploreDeckLogicTests 2>&1 | tail -30`

Expected: all tests PASS.

Run: `cd ios && xcodebuild build -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' 2>&1 | tail -20`

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 7: Commit**

```bash
git add ios/Sous/ExploreDeckView.swift ios/Sous/CounterView.swift ios/Sous/AppModel.swift ios/SousTests/ExploreDeckLogicTests.swift
git commit -m "feat(ios): Explore Deck (D3) + Kitchen Counter entry point"
```

---

## Task 5: Worker — `recipe_tweak` job kind

**Files:**
- Create: `worker/prompts/recipe_tweak.md`
- Modify: `worker/sous_worker/context.py` (add `fetch_recipe_tweak_context`, `build_recipe_tweak_prompt`)
- Modify: `worker/sous_worker/main.py` (add `generate_recipe_tweak_reply`, dispatch branch, skip chat-message insert for this kind)
- Modify: `worker/config.json` (allowed tools + timeout for the new kind)
- Test: `worker/tests/test_context.py`, `worker/tests/test_main.py`

**Interfaces:**
- Consumes: `db.Job` (`job.kind == "recipe_tweak"`, `job.payload` = `{origin_recipe_id,
  origin_dish_text, note, context, date}` — Task 4's `requestRecipeTweak` insert
  shape), `db.complete_job(conn, job_id, result: dict)`.
- Produces: `jobs.result` populated with the single-candidate JSON shape (Shared data
  shapes, above) — **no `chat_messages` row inserted for this kind**, since the result
  is structured data for the deck, not something to read as a chat reply.

- [ ] **Step 1: Write the failing tests**

Add to `worker/tests/test_context.py`:

```python
def test_fetch_recipe_tweak_context_includes_origin_and_note(conn, api_hid):
    ctx = context.fetch_recipe_tweak_context(
        conn, api_hid, origin_dish_text="三杯雞", note="沒有蝦", origin_recipe_id=None,
    )
    assert ctx["origin_dish_text"] == "三杯雞"
    assert ctx["note"] == "沒有蝦"
    assert "preferences" in ctx  # allergies-are-absolute still applies to a tweak


def test_build_recipe_tweak_prompt_substitutes_all_placeholders():
    template = "{origin_dish_text} / {note} / {preferences}"
    ctx = {"origin_dish_text": "三杯雞", "note": "沒有蝦", "preferences": "無"}
    prompt = context.build_recipe_tweak_prompt(template, ctx)
    assert prompt == "三杯雞 / 沒有蝦 / 無"
```

Add to `worker/tests/test_main.py` (matching the file's existing fixture/mocking
style for other job-kind dispatch tests — follow the pattern already used for
`recipe_intake`'s dispatch test in that file):

```python
def test_process_one_recipe_tweak_writes_result_no_chat_message(conn, cfg, monkeypatch):
    hid = _make_household(conn)
    job_id = conn.execute(
        "insert into jobs (household_id, kind, payload) values (%s, 'recipe_tweak', %s) "
        "returning id::text",
        (hid, Jsonb({"origin_recipe_id": None, "origin_dish_text": "三杯雞",
                     "note": "沒有蝦", "context": "ritual", "date": "2026-08-17"})),
    ).fetchone()[0]
    monkeypatch.setattr(main, "generate_recipe_tweak_reply",
                        lambda *a, **kw: json.dumps({"recipe_id": None, "dish_text": "無蝦三杯雞",
                                                     "dish_mode": "fast", "meta": "~25分", "pitch": "拿掉蝦照樣香",
                                                     "prep_note": None, "shopping_items": []}))
    main.process_one(conn, cfg)
    row = conn.execute("select status, result from jobs where id=%s", (job_id,)).fetchone()
    assert row[0] == "done"
    assert row[1]["dish_text"] == "無蝦三杯雞"
    messages = conn.execute("select count(*) from chat_messages where household_id=%s", (hid,)).fetchone()[0]
    assert messages == 0
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd worker && .venv/bin/python -m pytest tests/test_context.py -k recipe_tweak tests/test_main.py -k recipe_tweak -v`

Expected: FAIL — `fetch_recipe_tweak_context`/`generate_recipe_tweak_reply` not defined, and/or `kind: unknown job kind: recipe_tweak`.

- [ ] **Step 3: Write the prompt**

```markdown
{persona_pack}

Today is {today}({weekday})。這是「換一道」模式 — 對方在滑牌時對某張卡按了
「但是…」,要你依照他的要求給一張修改後的候選卡。

## 原本這張卡
{origin_dish_text}

## 對方的要求
{note}

## 家庭偏好(過敏原絕對排除)
{preferences}

## 你的任務
給一張新的候選卡,直接回一個 JSON 物件(不要加任何說明文字、不要用 markdown
code fence),格式:
```
{{"recipe_id": null, "dish_text": "...", "dish_mode": "fast|batch|leftover|play",
  "meta": "~25分 · 快手 · 蛋白質58g", "pitch": "一句話,為什麼這道菜符合他的要求",
  "prep_note": "前置作業(沒有就 null)",
  "shopping_items": [{{"name": "英文品名", "qty": "數量", "section": "Produce|Meat & seafood|Dairy & fridge|Pantry|Breakfast"}}]}}
```
`dish_text` 要真的回應對方的要求(拿掉某食材、換個調味方向等),不是隨便換一道
無關的菜。過敏原不管對方怎麼要求都不能出現。`shopping_items` 要涵蓋這道菜實際
需要買的食材(常備品不用列),名稱一律英文(Woolworths 真實品名),跟
`skills/plan-week.md` 採買清單規則同一套。只回這一個 JSON 物件,沒有其他文字。
```

- [ ] **Step 4: Implement `context.py` additions**

Add to `worker/sous_worker/context.py`, near `fetch_recipe_intake_context`:

```python
def fetch_recipe_tweak_context(conn, household_id: str, origin_dish_text: str,
                               note: str, origin_recipe_id: str | None) -> dict:
    now = datetime.datetime.now(ZoneInfo("Australia/Sydney"))
    return {
        "today": now.date().isoformat(),
        "weekday": "一二三四五六日"[now.weekday()],
        "origin_dish_text": origin_dish_text,
        "note": note,
        "preferences": _render_preferences(conn, household_id),
    }


def build_recipe_tweak_prompt(template: str, ctx: dict) -> str:
    prompt = template
    for key, value in ctx.items():
        prompt = prompt.replace("{" + key + "}", str(value))
    return prompt
```

- [ ] **Step 5: Wire `main.py` dispatch**

Add the generator function near `generate_recipe_intake_reply`:

```python
def generate_recipe_tweak_reply(conn, job: db.Job, cfg: dict) -> str:
    """recipe_tweak: single-shot, no chat message — the brain's entire reply is the
    revised-candidate JSON, parsed and written straight to jobs.result (process_one's
    else-branch below), not shown to the user as a chat line."""
    payload = job.payload
    ctx = context.fetch_recipe_tweak_context(
        conn, job.household_id, origin_dish_text=payload["origin_dish_text"],
        note=payload["note"], origin_recipe_id=payload.get("origin_recipe_id"),
    )
    template = (ROOT / "prompts" / "recipe_tweak.md").read_text()
    prompt = context.build_recipe_tweak_prompt(template, ctx)
    return brain.run_brain(prompt, model=cfg["chat_model"],
                           timeout=cfg["recipe_tweak_timeout_sec"],
                           allowed_tools=cfg["recipe_tweak_allowed_tools"],
                           cwd=str(ROOT),
                           extra_env={"SOUS_HOUSEHOLD_ID": job.household_id})
```

Modify `process_one`'s dispatch chain — add a branch, and special-case the
chat-message insert (currently unconditional for every non-`notif_generate` kind):

```python
        elif job.kind == "recipe_tweak":
            mode = "recipe_tweak"
            reply = generate_recipe_tweak_reply(conn, job, cfg)
```

And change the completion block from:

```python
        with conn.transaction():
            if job.kind != "notif_generate":
                db.insert_chef_message(conn, job.household_id, reply, job.id)
            db.complete_job(conn, job.id, {"reply_chars": len(reply), "mode": mode})
```

to:

```python
        with conn.transaction():
            if job.kind == "recipe_tweak":
                try:
                    parsed = json.loads(reply)
                except json.JSONDecodeError:
                    raise ValueError(f"recipe_tweak reply was not valid JSON: {reply[:200]!r}")
                db.complete_job(conn, job.id, parsed)
            else:
                if job.kind != "notif_generate":
                    db.insert_chef_message(conn, job.household_id, reply, job.id)
                db.complete_job(conn, job.id, {"reply_chars": len(reply), "mode": mode})
```

- [ ] **Step 6: Add config entries**

Add to `worker/config.json`:

```json
  "recipe_tweak_timeout_sec": 180,
  "recipe_tweak_allowed_tools": ["Read"],
```

(No `Bash(.venv/bin/python state_api.py:*)` — a tweak never writes state directly,
it only returns a candidate for the client to decide on later.)

- [ ] **Step 7: Run tests to verify they pass**

Run: `cd worker && .venv/bin/python -m pytest tests/test_context.py tests/test_main.py -k "tweak" -v`

Expected: PASS.

Run full suite to confirm no regressions: `cd worker && .venv/bin/python -m pytest tests/ -x -q`

Expected: same baseline pass/fail count as before this task (6 pre-existing
`plan_days`/notification week-drift failures per `[[sous-m3-design-pass]]` — confirm
via `supabase db reset` first if the count looks different, per that memory's note on
count drifting with wall-clock time).

- [ ] **Step 8: Commit**

```bash
git add worker/prompts/recipe_tweak.md worker/sous_worker/context.py worker/sous_worker/main.py worker/config.json worker/tests/test_context.py worker/tests/test_main.py
git commit -m "feat(worker): recipe_tweak job kind — single-shot swipe-up modification"
```

---

## Task 6: Worker — ritual swipe mode (`swipe_deal` + `swipe_lock`)

**Files:**
- Create: `worker/prompts/ritual_swipe.md`
- Modify: `worker/sous_worker/context.py` (add `fetch_ritual_swipe_context`, `build_ritual_swipe_prompt`)
- Modify: `worker/sous_worker/main.py` (branch on `job.payload.get("mode")` within the existing `ritual` kind)
- Modify: `worker/config.json`
- Test: `worker/tests/test_context.py`, `worker/tests/test_main.py`

**Interfaces:**
- Consumes: `db.Job` where `job.kind == "ritual"` and `job.payload["mode"] in
  ("swipe_deal", "swipe_lock")` (absent/other = today's existing written-ritual path,
  unchanged); `state_api.set_plan` (existing, unmodified — `swipe_lock` calls it
  mechanically with client-confirmed data, no new verb).
- Produces: `jobs.result` = the `swipe_deal` deck JSON (Shared data shapes, above) for
  `swipe_deal`; `{"mode": "swipe_lock", "week_of": ...}` for `swipe_lock`, mirroring
  `set_plan`'s own return shape.

- [ ] **Step 1: Write the failing tests**

Add to `worker/tests/test_context.py`:

```python
def test_fetch_ritual_swipe_context_reuses_ritual_context_fields(conn, api_hid):
    ctx = context.fetch_ritual_swipe_context(conn, api_hid)
    # Same underlying signal as the written ritual — banger/craving/allergy judgment
    # doesn't change just because the interaction model did.
    for key in ("recent_weeks", "inbox", "verdicts_recent", "staples_flagged",
                "preferences", "cookbook_index", "target_week_of"):
        assert key in ctx


def test_build_ritual_swipe_prompt_substitutes_target_week(conn, api_hid):
    ctx = context.fetch_ritual_swipe_context(conn, api_hid)
    template = "week: {target_week_of}"
    prompt = context.build_ritual_swipe_prompt(template, ctx)
    assert ctx["target_week_of"] in prompt
```

Add to `worker/tests/test_main.py`:

```python
def test_process_one_ritual_swipe_deal_writes_deck_to_result(conn, cfg, monkeypatch):
    hid = _make_household(conn)
    job_id = conn.execute(
        "insert into jobs (household_id, kind, payload) values (%s, 'ritual', %s) "
        "returning id::text",
        (hid, Jsonb({"mode": "swipe_deal"})),
    ).fetchone()[0]
    fake_deck = {"mode": "swipe_deal", "days": [
        {"date": "2026-08-17", "candidates": [
            {"recipe_id": None, "dish_text": "三杯雞", "dish_mode": "fast",
             "meta": "~25分", "pitch": "香", "prep_note": None, "shopping_items": []}]}]}
    monkeypatch.setattr(main, "generate_ritual_swipe_deal_reply",
                        lambda *a, **kw: json.dumps(fake_deck))
    main.process_one(conn, cfg)
    row = conn.execute("select status, result from jobs where id=%s", (job_id,)).fetchone()
    assert row[0] == "done"
    assert row[1]["days"][0]["candidates"][0]["dish_text"] == "三杯雞"


def test_process_one_ritual_swipe_lock_calls_set_plan(conn, cfg, monkeypatch):
    hid = _make_household(conn)
    week_of = week_monday(datetime.datetime.now(ZoneInfo("Australia/Sydney")).date()) + datetime.timedelta(days=7)
    conn.execute("insert into plan_weeks (household_id, week_of, status) values (%s, %s, 'proposing')",
                (hid, week_of))
    days = [{"date": (week_of + datetime.timedelta(days=i)).isoformat(), "dish": f"菜{i}", "mode": "fast"}
            for i in range(7)]
    job_id = conn.execute(
        "insert into jobs (household_id, kind, payload) values (%s, 'ritual', %s) returning id::text",
        (hid, Jsonb({"mode": "swipe_lock", "days": days, "shopping_items": []})),
    ).fetchone()[0]
    main.process_one(conn, cfg)
    week_status = conn.execute("select status from plan_weeks where household_id=%s and week_of=%s",
                              (hid, week_of)).fetchone()[0]
    assert week_status == "locked"
    result = conn.execute("select result from jobs where id=%s", (job_id,)).fetchone()[0]
    assert result["mode"] == "swipe_lock"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd worker && .venv/bin/python -m pytest tests/test_context.py -k ritual_swipe tests/test_main.py -k "swipe_deal or swipe_lock" -v`

Expected: FAIL — functions not defined.

- [ ] **Step 3: Write the prompt**

```markdown
{persona_pack}

Today is {today}({weekday})。這是「滑牌儀式」模式 — 一次性產生下週
({target_week_of} 那週)整整七天、每天 2-3 張候選卡,讓對方用滑的方式一天一天
決定,不是像平常聊天那樣來回問答。

## 你知道的(渲染好的狀態)
### 近期排菜紀錄
{recent_weeks}
### 收件匣
{inbox}
### 最近評價
{verdicts_recent}
### 常備品快用完
{staples_flagged}
### 家庭偏好
{preferences}
### 食譜庫(索引)
{cookbook_index}

## 產卡邏輯
沿用既有判斷(`skills/plan-week.md` Step 1-2 同一套):翻車的菜這輪別排;神作且
近 4 週沒出現過的列為候選 banger;過敏原絕對不上卡;兩週內煮過的不上卡(除非是
banger 點名)。每天依照該天的性質(週末可以輕鬆一點、平日要快)判斷需要哪種
候選,和寫給對話儀式的邏輯是同一套判斷,只是這裡一次要對七天各給 2-3 張候選,
不是一次給 8 張讓對方挑。

## 輸出格式(硬性 — 只回這個 JSON,不要任何說明文字或 markdown code fence)
```
{{"mode": "swipe_deal", "days": [
  {{"date": "YYYY-MM-DD", "candidates": [
    {{"recipe_id": null, "dish_text": "...", "dish_mode": "fast|batch|leftover|play",
      "meta": "~分鐘 · 快手/... · 蛋白質Ng", "pitch": "一句話 hook", "prep_note": null,
      "shopping_items": [{{"name": "英文品名", "qty": "數量", "section": "Produce|Meat & seafood|Dairy & fridge|Pantry|Breakfast"}}]}},
    ...(每天 2-3 張)
  ]}},
  ...(共 7 天,涵蓋 {target_week_of} 那週週一到週日)
]}}
```
每天第一張候選盡量放最有把握的選擇(banger/craving 優先);其餘候選是同一天的
備選,滑「換一道」時依序換上。週末candidate 可以包含「外食」這種輕鬆選項(這種
選項 `shopping_items` 給空陣列即可)。`shopping_items` 規則跟 `skills/plan-week.md`
的採買清單規則同一套:同一項目只列一次、名稱英文、常備品不列、涵蓋配菜/湯不只
主菜。
```

- [ ] **Step 4: Implement `context.py` additions**

```python
def fetch_ritual_swipe_context(conn, household_id: str, history_limit: int = 20) -> dict:
    """Same underlying signal as fetch_ritual_context — the swipe deck's card-dealing
    judgment (banger/craving/allergy rules) doesn't change with the interaction model,
    only the output shape does. Deliberately does not call ensure_proposing_week here;
    process_one's dispatch does that once, matching the existing ritual-kind flow."""
    now = datetime.datetime.now(ZoneInfo("Australia/Sydney"))
    target_week_of = week_monday(now.date()) + datetime.timedelta(days=7)
    return {
        "today": now.date().isoformat(),
        "weekday": "一二三四五六日"[now.weekday()],
        "target_week_of": target_week_of.isoformat(),
        "recent_weeks": _render_recent_weeks(conn, household_id, before=target_week_of, weeks_back=4),
        "inbox": _render_inbox(conn, household_id),
        "verdicts_recent": _render_verdicts_recent(conn, household_id),
        "staples_flagged": _render_staples_flagged(conn, household_id),
        "preferences": _render_preferences(conn, household_id),
        "cookbook_index": _render_cookbook_index(conn, household_id),
    }


def build_ritual_swipe_prompt(template: str, ctx: dict) -> str:
    prompt = template
    for key, value in ctx.items():
        prompt = prompt.replace("{" + key + "}", str(value))
    return prompt
```

(Verified against the actual definition in `context.py`: `_render_recent_weeks(conn,
household_id, before, weeks_back=4)` — the code above uses the real parameter name.)

- [ ] **Step 5: Wire `main.py` dispatch**

Add the generator:

```python
def generate_ritual_swipe_deal_reply(conn, job: db.Job, cfg: dict) -> str:
    ctx = context.fetch_ritual_swipe_context(conn, job.household_id, cfg["history_limit"])
    template = (ROOT / "prompts" / "ritual_swipe.md").read_text()
    prompt = context.build_ritual_swipe_prompt(template, ctx)
    return brain.run_brain(prompt, model=cfg["chat_model"],
                           timeout=cfg["chat_timeout_sec"],
                           allowed_tools=cfg["ritual_swipe_deal_allowed_tools"],
                           cwd=str(ROOT),
                           extra_env={"SOUS_HOUSEHOLD_ID": job.household_id})


def run_ritual_swipe_lock(conn, job: db.Job) -> dict:
    """swipe_lock is a mechanical pass-through, not a brain turn — every day is
    already decided by swiping, so there's no judgment left to make. Calling
    set_plan directly (not via a claude -p subprocess) reuses its existing
    validation/idempotency/week-lock logic without duplicating it, and skips the
    100-150s wait a real brain call would add to the one moment that least needs it."""
    result = state_api.set_plan(conn, job.household_id, job.payload["days"],
                                job.payload.get("shopping_items", []),
                                reasoning=job.payload.get("reasoning"))
    return {"mode": "swipe_lock", "week_of": str(result["week_of"])}
```

Modify `process_one`'s existing `job.kind in ("chat", "ritual")` branch to check the
payload mode first:

```python
        if job.kind in ("chat", "ritual"):
            ritual_mode = job.payload.get("mode") if job.kind == "ritual" else None
            if ritual_mode == "swipe_deal":
                mode = "ritual_swipe_deal"
                reply = generate_ritual_swipe_deal_reply(conn, job, cfg)
            elif ritual_mode == "swipe_lock":
                mode = "ritual_swipe_lock"
                reply = None  # no brain turn — handled in the completion block below
            else:
                mode = ("ritual" if job.kind == "ritual"
                        or db.get_proposing_week(conn, job.household_id) else "chat")
                reply = (generate_ritual_reply(conn, job, cfg) if mode == "ritual"
                         else generate_chat_reply(conn, job, cfg))
```

And extend the completion block (already modified by Task 5) with the two new modes:

```python
        with conn.transaction():
            if job.kind == "recipe_tweak":
                try:
                    parsed = json.loads(reply)
                except json.JSONDecodeError:
                    raise ValueError(f"recipe_tweak reply was not valid JSON: {reply[:200]!r}")
                db.complete_job(conn, job.id, parsed)
            elif mode == "ritual_swipe_deal":
                try:
                    parsed = json.loads(reply)
                except json.JSONDecodeError:
                    raise ValueError(f"ritual swipe_deal reply was not valid JSON: {reply[:200]!r}")
                db.complete_job(conn, job.id, parsed)
            elif mode == "ritual_swipe_lock":
                db.complete_job(conn, job.id, run_ritual_swipe_lock(conn, job))
            else:
                if job.kind != "notif_generate":
                    db.insert_chef_message(conn, job.household_id, reply, job.id)
                db.complete_job(conn, job.id, {"reply_chars": len(reply), "mode": mode})
```

Add the import at the top of `main.py`: `from sous_worker import brain, context, db, gemini_intake, state_api`
(adjust to match whatever import line already exists — verify against the file
before editing, since Task 5 may have already changed nearby lines).

**Also fix the post-success notification gate** — `process_one`'s success branch
(`else:` after the `try`/`except`, at the bottom of the function) only enqueues
post-lock week notifications when `mode == "ritual"`:

```python
    else:
        if mode == "ritual":
            try:
                household = db.get_household(conn, job.household_id)
                now = datetime.datetime.now(ZoneInfo(household["timezone"]))
                target_week_of = context.week_monday(now.date()) + datetime.timedelta(weeks=1)
                db.enqueue_week_notifications_if_locked(conn, job.household_id, target_week_of)
            except Exception:
                log.exception("failed to enqueue week notifications for household %s",
                             job.household_id)
    return True
```

`ritual_swipe_lock` also locks a week (via `run_ritual_swipe_lock`'s `set_plan` call)
and must trigger the same check — `enqueue_week_notifications_if_locked` itself
re-checks `plan_weeks.status` before enqueuing anything, so it's safe to call it
whenever a week *might* have just been locked, not only via the literal `"ritual"`
mode. `ritual_swipe_deal` never locks anything and must stay excluded — do not
widen this to all three modes. Change the condition to:

```python
        if mode in ("ritual", "ritual_swipe_lock"):
```

- [ ] **Step 6: Add config entries**

Add to `worker/config.json`:

```json
  "ritual_swipe_deal_allowed_tools": ["Read"],
```

(`swipe_lock` needs no entry — it never shells out to `claude -p`.)

- [ ] **Step 7: Run tests to verify they pass**

Run: `cd worker && .venv/bin/python -m pytest tests/test_context.py tests/test_main.py -k "ritual_swipe or swipe_deal or swipe_lock" -v`

Expected: PASS.

Run full suite: `cd worker && .venv/bin/python -m pytest tests/ -x -q`

Expected: same baseline as Task 5's Step 7.

- [ ] **Step 8: Commit**

```bash
git add worker/prompts/ritual_swipe.md worker/sous_worker/context.py worker/sous_worker/main.py worker/config.json worker/tests/test_context.py worker/tests/test_main.py
git commit -m "feat(worker): ritual swipe_deal + swipe_lock — one-shot weekly deck, mechanical lock"
```

---

## Task 7: Ritual Swipe Session (B1) + Week Board dual entry point

**Files:**
- Create: `ios/Sous/RitualSwipeSessionView.swift`
- Modify: `ios/Sous/WeekBoardView.swift` (dual ritual-entry buttons; `weekdayGlyph`
  call site updated to the extracted shared function)
- Modify: `ios/Sous/AppModel.swift` (`startSwipeRitual`, `submitSwipeLock`)
- Modify: `ios/Sous/Models.swift` (extract `weekdayGlyph(for:timezone:)` as a shared
  free function)
- Modify: `ios/Sous/RecipePhotoCarousel.swift` (widen `[safe:]` from `private
  extension Array` to `extension Array`)

**Interfaces:**
- Consumes: `SwipeCardStack`, `SwipeCandidate`, `SwipeDeckState` (Tasks 2–3),
  `AppModel.pollJobResult`/`requestRecipeTweak` (Task 4 — note `pollJobResult`'s
  current signature only decodes the single-candidate shape; this task adds a
  sibling `pollRitualDeck(jobId:)` for the `{"days": [...]}` shape rather than
  overloading it, to keep each decoder's `Decodable` type honest).
- Produces: `RitualSwipeSessionView: View` (`.fullScreenCover`, same tier as Cook
  Mode); `AppModel.startSwipeRitual() async -> UUID?` (returns the created job id);
  `AppModel.submitSwipeLock(days:, shoppingItems:) async -> Bool`.

- [ ] **Step 1: Add `AppModel` methods**

Add near `startRitual()`:

```swift
    /// Bootstraps the swipe ritual — inserts a `ritual`-kind job with
    /// `payload.mode = "swipe_deal"` (Task 6's worker branch), no chat message
    /// involved (unlike `startRitual()`'s written-ritual path). Returns the job id
    /// for the caller to poll.
    func startSwipeRitual() async -> UUID? {
        struct Payload: Encodable { let mode: String }
        struct NewJob: Encodable { let household_id: UUID; let kind: String; let payload: Payload }
        struct JobRow: Decodable { let id: UUID }
        guard let household else { return nil }
        do {
            let job: JobRow = try await client.from("jobs")
                .insert(NewJob(household_id: household.id, kind: "ritual", payload: .init(mode: "swipe_deal")))
                .select("id").single().execute().value
            return job.id
        } catch { print("start swipe ritual: \(error)"); return nil }
    }

    struct SwipeDeckDay { let date: String; let candidates: [SwipeCandidate] }

    /// Decodes the swipe_deal deck shape specifically — kept separate from
    /// `pollJobResult` (Task 4) because that one's `JobResultPayload` is a single
    /// flat candidate, not a `{"days": [...]}` wrapper; overloading one decoder for
    /// both shapes would make either failure mode silently swallow the other's.
    func pollRitualDeck(jobId: UUID) async -> [SwipeDeckDay]? {
        struct CandidateRow: Decodable {
            let recipe_id: UUID?; let dish_text: String?; let dish_mode: String?
            let meta: String?; let pitch: String?; let prep_note: String?
            let shopping_items: [SwipeShoppingItem]?
        }
        struct DayRow: Decodable { let date: String; let candidates: [CandidateRow] }
        struct DeckResult: Decodable { let mode: String; let days: [DayRow] }
        struct JobStatusRow: Decodable { let status: String; let result: DeckResult? }
        for _ in 0..<90 { // 90 * 2s = 180s — a full-week deck is a bigger brain turn than a tweak
            do {
                let row: JobStatusRow = try await client.from("jobs")
                    .select("status,result").eq("id", value: jobId).single().execute().value
                if row.status == "done", let result = row.result {
                    return result.days.map { day in
                        SwipeDeckDay(date: day.date, candidates: day.candidates.map {
                            SwipeCandidate(id: UUID(), recipeId: $0.recipe_id, dishText: $0.dish_text ?? "",
                                          mode: $0.dish_mode, meta: $0.meta, pitch: $0.pitch, prepNote: $0.prep_note,
                                          shoppingItems: $0.shopping_items ?? [])
                        })
                    }
                }
                if row.status == "failed" { return nil }
            } catch { print("poll ritual deck: \(error)") }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return nil
    }

    struct SwipeLockDayPayload: Encodable {
        let date: String
        let dish: String
        let mode: String
        let prep_note: String?
    }

    /// Fires the swipe_lock job (Task 6) once all 7 days are confirmed, then waits
    /// for it exactly like any other ritual completion, refreshing the week board on
    /// success — same post-lock refresh `loadWeekBoard()` already provides elsewhere.
    /// Concrete `Encodable` payload structs (not a generic `[String: Any]`/`AnyJSON`
    /// blob) — matches every other job-insert precedent in this file
    /// (`requestRecipeTweak`'s `Payload`, `sendSystemAction`'s `NewMessage`).
    func submitSwipeLock(days: [SwipeLockDayPayload], shoppingItems: [SwipeShoppingItem]) async -> Bool {
        struct Payload: Encodable {
            let mode: String
            let days: [SwipeLockDayPayload]
            let shopping_items: [SwipeShoppingItem]
        }
        struct NewJob: Encodable { let household_id: UUID; let kind: String; let payload: Payload }
        struct JobRow: Decodable { let id: UUID }
        guard let household else { return false }
        do {
            let job: JobRow = try await client.from("jobs")
                .insert(NewJob(household_id: household.id, kind: "ritual",
                               payload: .init(mode: "swipe_lock", days: days, shopping_items: shoppingItems)))
                .select("id").single().execute().value
            for _ in 0..<45 {
                struct StatusRow: Decodable { let status: String }
                let row: StatusRow = try await client.from("jobs")
                    .select("status").eq("id", value: job.id).single().execute().value
                if row.status == "done" { await loadWeekBoard(); return true }
                if row.status == "failed" { return false }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            return false
        } catch { print("submit swipe lock: \(error)"); return false }
    }
```

- [ ] **Step 2: Implement `RitualSwipeSessionView.swift`**

```swift
import SwiftUI

/// B1 · 滑牌儀式 — Reference: design_handoff_sous_m3/README.md "B1 · 滑牌儀式".
/// Deals one candidate per open day; right confirms and advances to the next day,
/// left asks for a different candidate for the *same* day (mechanics spec §2.2 —
/// "the load-bearing mechanic"), up opens 但是… (Task 3's panel, wired here to fire
/// recipe_tweak with this card's date attached).
struct RitualSwipeSessionView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var days: [AppModel.SwipeDeckDay] = []
    @State private var dayIndex = 0
    @State private var deck = SwipeDeckState(candidates: [], pendingReinserts: [])
    @State private var confirmed: [String: SwipeCandidate] = [:] // date -> chosen candidate
    @State private var loading = true
    @State private var locking = false

    private var serifName: String { serifFontName(bundled: FontBook.isSerifBundled) }
    private var sansName: String { sansFontName(bundled: FontBook.isSansBundled) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("滑牌儀式").font(.custom(serifName, size: 17))
                Spacer()
                Button("關閉") { dismiss() }
            }
            .padding(.horizontal, Spacing.pageMargin)
            .padding(.top, Spacing.md)

            if loading {
                Spacer()
                RitualWaitingCard(stages: model.thinkingStages,
                                  leaveOkText: model.personaCopy["wait_leave_ok"] ?? "你可以先去忙 —— 排好我會放進便條通知你。",
                                  tint: model.personaTint, startedAt: Date())
                    .padding(.horizontal, Spacing.pageMargin)
                Spacer()
            } else if confirmed.count == days.count, days.count == 7 {
                lockCard
            } else if let currentDay = days[safe: dayIndex] {
                SwipeCardStack(
                    candidates: deck.candidates,
                    dayLabel: weekdayLabel(currentDay.date),
                    progressFilled: confirmed.count, progressTotal: days.count,
                    onSwipe: { candidate, direction in handleSwipe(candidate, direction, day: currentDay) },
                    onModifyNote: { candidate, note in handleModify(candidate, note, day: currentDay) }
                )
            }
        }
        .background(PaperTokens.stock)
        .task {
            guard let jobId = await model.startSwipeRitual() else { loading = false; return }
            if let result = await model.pollRitualDeck(jobId: jobId) {
                days = result
                deck.candidates = result.first?.candidates ?? []
            }
            loading = false
        }
    }

    private func handleSwipe(_ candidate: SwipeCandidate, _ direction: SwipeDirection, day: AppModel.SwipeDeckDay) {
        deck.advance()
        Task {
            await model.recordSwipe(recipeId: candidate.recipeId, dishText: candidate.dishText,
                                    action: direction == .like ? "like" : "pass",
                                    context: "ritual", note: nil)
        }
        if direction == .like {
            confirmed[day.date] = candidate
            advanceDay()
        }
        // .pass: stay on this day — README §2.2 "offers a different candidate for
        // the *same* day, not the next day." If this day's pre-generated candidates
        // are exhausted, deck.candidates is simply empty until a recipe_tweak
        // reinsert lands or the user backs out — no synchronous re-deal.
    }

    private func handleModify(_ candidate: SwipeCandidate, _ note: String, day: AppModel.SwipeDeckDay) {
        deck.advance()
        Task {
            await model.recordSwipe(recipeId: candidate.recipeId, dishText: candidate.dishText,
                                    action: "modify", context: "ritual", note: note)
            if let revised = await model.requestRecipeTweak(originRecipeId: candidate.recipeId,
                                                             originDishText: candidate.dishText,
                                                             note: note, context: "ritual", date: day.date) {
                deck.scheduleReinsert(revised)
            }
        }
    }

    private func advanceDay() {
        dayIndex += 1
        guard let next = days[safe: dayIndex] else { return }
        deck = SwipeDeckState(candidates: next.candidates, pendingReinserts: [])
    }

    private var lockCard: some View {
        VStack(spacing: 14) {
            Text("五天都排好了").font(.custom(sansName, size: 10)).tracking(2).foregroundStyle(model.personaTint)
            Text("這一週 / 交給我").font(.custom(serifName, size: 24)).multilineTextAlignment(.center)
            if locking {
                ProgressView().tint(model.personaTint)
            } else {
                Button("鎖　定") { Task { await lockWeek() } }
                    .font(.custom(sansName, size: 13)).fontWeight(.medium)
                    .foregroundStyle(PaperTokens.stock)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(PaperTokens.ink)
                    .padding(.horizontal, Spacing.pageMargin)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private func lockWeek() async {
        locking = true
        let daysPayload: [AppModel.SwipeLockDayPayload] = days.compactMap { day in
            guard let chosen = confirmed[day.date] else { return nil }
            return AppModel.SwipeLockDayPayload(date: day.date, dish: chosen.dishText,
                                                mode: chosen.mode ?? "fast", prep_note: chosen.prepNote)
        }
        // Flat aggregate across all 7 confirmed candidates — set_plan's
        // --shopping-items is one list for the whole week, not per-day (state_api.py:
        // set_plan(conn, household_id, days, shopping_items, reasoning)). Duplicate
        // ingredient names across dishes are possible but harmless — the same gap
        // already exists in today's written-ritual flow, where dedup is the brain's
        // own care in Step 3, not something set_plan enforces.
        let shoppingPayload = confirmed.values.flatMap(\.shoppingItems)
        let success = await model.submitSwipeLock(days: daysPayload, shoppingItems: shoppingPayload)
        locking = false
        if success { dismiss() }
    }

    private func weekdayLabel(_ dateStr: String) -> String {
        "週　" + weekdayGlyph(for: dateStr, timezone: .current)
    }
}
```

- [ ] **Step 3: Extract shared utilities `RitualSwipeSessionView` needs**

`WeekBoardView.weekdayGlyph(for:)` is currently a *private* method on that view,
keyed off `householdTimezone` implicitly. Extract it to a shared free function in
`ios/Sous/Models.swift`, alongside the existing free functions `chefIsPresent`/
`color(fromHex:)`:

```swift
private static let weekdayGlyphs = ["日", "一", "二", "三", "四", "五", "六"] // Calendar weekday: Sun=1...Sat=7

/// Maps a "YYYY-MM-DD" date string to its Chinese weekday glyph in the given
/// timezone. Shared by `WeekBoardView` and `RitualSwipeSessionView` so both read
/// the same convention instead of diverging.
func weekdayGlyph(for dateStr: String, timezone: TimeZone) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = timezone
    guard let date = formatter.date(from: dateStr) else { return "" }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timezone
    let weekday = calendar.component(.weekday, from: date)
    return weekdayGlyphs[weekday - 1]
}
```

(`weekdayGlyphs` moves out of `WeekBoardView`'s `private static let` into this
free-function scope — a plain top-level `private let` in `Models.swift` works
identically.)

Delete `WeekBoardView`'s own private `weekdayGlyph(for:)` method and its private
`weekdayGlyphs` array (both now live in `Models.swift`); update its one call site
(inside `weekdayGlyph(for:)`'s own body, now removed, so no call-site change needed
there) — but `dayRow`'s callers that invoke `weekdayGlyph(for: day.date)` now resolve
to the free function automatically. Explicitly pass the timezone at each call site:
`weekdayGlyph(for: day.date, timezone: householdTimezone)`.

Widen `[safe:]` in `ios/Sous/RecipePhotoCarousel.swift` from `private extension
Array` to `extension Array` (drop `private` only — it's a two-line, side-effect-free
subscript, safe to broaden in place without moving the file):

```swift
extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
```

Run: `cd ios && xcodebuild build -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' 2>&1 | tail -20`

Expected: `BUILD SUCCEEDED` (confirms `WeekBoardView` still compiles against the
extracted free function before moving on).

- [ ] **Step 4: Wire Week Board's dual entry point**

Modify `WeekBoardView.swift`'s `startRitualPrompt` (currently single-button per its
own doc comment — "Pass 1a has no swipe ritual to link a second button to — that's
Pass 2"). Replace the single button with both, per README E2 "next week offers both
ritual models by name: ink-filled 滑牌排 and outlined 用寫的":

```swift
    private var startRitualPrompt: some View {
        VStack(spacing: 12) {
            Text("還沒排 —— 現在排嗎?")
                .font(.custom(serifName, size: 17))
                .lineSpacing(8.5)
                .foregroundStyle(PaperTokens.ink)
                .multilineTextAlignment(.center)

            Button { showSwipeRitual = true } label: {
                Text("滑牌排")
                    .font(.custom(sansName, size: 12)).fontWeight(.medium).tracking(2.4)
                    .foregroundStyle(PaperTokens.stock)
                    .frame(maxWidth: .infinity).padding(13)
                    .background(PaperTokens.ink)
            }
            .buttonStyle(.plain)

            Button {
                pendingRitualStart = true
                ritualWaitStartedAt = Date()
                Task { await model.startRitual() }
            } label: {
                Text("用寫的")
                    .font(.custom(sansName, size: 12)).fontWeight(.medium).tracking(2.4)
                    .foregroundStyle(PaperTokens.ink)
                    .frame(maxWidth: .infinity).padding(13)
                    .overlay(Rectangle().stroke(PaperTokens.ink, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }
```

Add the new state and `.fullScreenCover`:

```swift
    @State private var showSwipeRitual = false
```

```swift
        .fullScreenCover(isPresented: $showSwipeRitual) {
            RitualSwipeSessionView().environmentObject(model)
        }
```

- [ ] **Step 5: Build**

Run: `cd ios && xcodegen generate && xcodebuild build -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' 2>&1 | tail -20`

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add ios/Sous/RitualSwipeSessionView.swift ios/Sous/WeekBoardView.swift ios/Sous/AppModel.swift ios/Sous/Models.swift ios/Sous/RecipePhotoCarousel.swift
git commit -m "feat(ios): Ritual Swipe Session (B1) + Week Board dual ritual entry"
```

---

## Task 8: Ritual cadence Settings UI (E3)

**Files:**
- Modify: `ios/Sous/NotificationsSettingsView.swift` (add 儀式節奏 section — the
  file already has a scope-note comment at line 7 flagging this as explicit Pass 2
  scope, per this task)
- Modify: `ios/Sous/Models.swift` (extend `Household` with the two new columns)
- Modify: `ios/Sous/AppModel.swift` (`updateRitualCadence`)

**Interfaces:**
- Consumes: `households.ritual_cadence_interval`/`ritual_cadence_anchor_day`
  (Task 1).
- Produces: `Household.ritualCadenceInterval: String`,
  `Household.ritualCadenceAnchorDay: Int`; `AppModel.updateRitualCadence(interval:
  anchorDay:) async`.

- [ ] **Step 1: Extend `Household`**

Modify `ios/Sous/Models.swift`'s `Household` struct:

```swift
struct Household: Codable {
    let id: UUID
    let name: String
    let workerSeenAt: Date?
    let timezone: String
    let personaId: UUID
    let ritualCadenceInterval: String
    let ritualCadenceAnchorDay: Int

    enum CodingKeys: String, CodingKey {
        case id, name, timezone
        case workerSeenAt = "worker_seen_at"
        case personaId = "persona_id"
        case ritualCadenceInterval = "ritual_cadence_interval"
        case ritualCadenceAnchorDay = "ritual_cadence_anchor_day"
    }
}
```

Every existing `Household` query must add these two columns to its `select` string —
check `AppModel.loadAll()` (or wherever `household` is first fetched) for the
current column list and extend it there; a missing column here throws a decode
error under the non-optional fields, per `Recipe.selectColumns`'s own documented
precedent of exactly this failure mode.

- [ ] **Step 2: Add `AppModel.updateRitualCadence`**

```swift
    /// Direct write, no job — same "instant settings toggle" family as
    /// `submitPreferences`. The worker's own scheduler (not built in this pass —
    /// see the parent spec's staging note) will read these columns later; the
    /// setting itself has no reason to wait on a brain round-trip.
    func updateRitualCadence(interval: String, anchorDay: Int) async {
        guard let household else { return }
        struct Update: Encodable { let ritual_cadence_interval: String; let ritual_cadence_anchor_day: Int }
        do {
            try await client.from("households")
                .update(Update(ritual_cadence_interval: interval, ritual_cadence_anchor_day: anchorDay))
                .eq("id", value: household.id)
                .execute()
            self.household = Household(id: household.id, name: household.name,
                                       workerSeenAt: household.workerSeenAt, timezone: household.timezone,
                                       personaId: household.personaId, ritualCadenceInterval: interval,
                                       ritualCadenceAnchorDay: anchorDay)
        } catch { print("update ritual cadence: \(error)") }
    }
```

- [ ] **Step 3: Add the Settings section**

Add to `NotificationsSettingsView.swift`, following that file's existing section
pattern (chips + explanation text, per README E3 "儀式節奏... chips + anchor day +
explanation of what the setting causes" — match the file's current chip-row styling
exactly rather than inventing a new one):

```swift
    private var ritualCadenceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("儀式節奏")
                .font(.custom(sansFontName(bundled: FontBook.isSansBundled), size: 10))
                .tracking(2)
                .foregroundStyle(PaperTokens.inkFaint)
            HStack(spacing: 8) {
                cadenceChip("每週", value: "weekly")
                cadenceChip("每兩週", value: "biweekly")
            }
            Text(cadenceExplanation)
                .font(.custom(sansFontName(bundled: FontBook.isSansBundled), size: 11))
                .foregroundStyle(PaperTokens.inkDim)
        }
    }

    private func cadenceChip(_ label: String, value: String) -> some View {
        let selected = model.household?.ritualCadenceInterval == value
        return Button {
            Task { await model.updateRitualCadence(interval: value, anchorDay: model.household?.ritualCadenceAnchorDay ?? 1) }
        } label: {
            Text(label)
                .font(.custom(sansFontName(bundled: FontBook.isSansBundled), size: 12))
                .foregroundStyle(selected ? PaperTokens.stock : PaperTokens.ink)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(selected ? model.personaTint : Color.clear)
                .overlay(Rectangle().stroke(selected ? Color.clear : PaperTokens.rule, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var cadenceExplanation: String {
        let interval = model.household?.ritualCadenceInterval == "biweekly" ? "每兩週" : "每週"
        return "\(interval)提醒你開始排菜儀式一次。"
    }
```

Call `ritualCadenceSection` from the view's existing body composition, in whatever
section-ordering the file already uses.

- [ ] **Step 4: Build**

Run: `cd ios && xcodegen generate && xcodebuild build -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' 2>&1 | tail -20`

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add ios/Sous/NotificationsSettingsView.swift ios/Sous/Models.swift ios/Sous/AppModel.swift
git commit -m "feat(ios): ritual cadence setting (E3) — interval chips, households columns"
```

---

## Final verification

- [ ] **Full iOS test suite**: `cd ios && xcodebuild test -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' 2>&1 | tail -40` — expect all green, no regressions vs. the pre-Pass-2a baseline (124 tests per `[[sous-m3-design-pass]]`'s Pass 1c note, plus this pass's new tests).
- [ ] **Full worker test suite**: `cd worker && .venv/bin/python -m pytest tests/ -x -q` — expect the same pre-existing 6-failure baseline, not a new count (re-run `supabase db reset` first if it drifts, per `[[sous-m3-design-pass]]`).
- [ ] **Push migration to production before any real-device check**: `supabase db push --linked`, then confirm via `supabase migration list --linked` — per `[[feedback-real-device-check-needs-cloud-migrations]]`, this must happen *before* symptoms appear, not after.
- [ ] **Whole-branch review** — per this project's established bar (Pass 1a/1b/1c), dispatch a full-branch review before any real-device walkthrough; this pass has more first-time interaction surface (drag gestures, job-result polling) than any prior pass, so treat the review as load-bearing, not a formality.
- [ ] **Real-device walkthrough on Mike's iPhone 13 mini**: Explore Deck (peek card → swipe right/left/up → 但是… reinsert), Ritual Swipe Session (both entry points — chat CTA is Pass 2b/notification-scheduling territory, so for this pass just the Week Board button — day-by-day dealing, a real 换一道/但是… cycle, full lock flow), ritual cadence Settings toggle.
