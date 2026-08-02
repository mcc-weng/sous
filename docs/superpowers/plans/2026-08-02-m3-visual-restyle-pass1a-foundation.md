# M3 Visual Restyle — Pass 1a: Foundation + Restyle-Only Screens Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the 書與灶 (paper/stage) design system's foundation (tokens, fonts,
persona tint, copy_pack) and apply it to the 8 screens that are pure restyle — no new
interaction logic. Recipe Detail and Cook Mode (which have real new logic) are Pass 1b
and 1c, separate plans.

**Architecture:** A small `DesignTokens.swift` becomes the single source of color/type/
spacing constants every view imports. The persona accent (`seal`) is sourced from the
existing `personas.tint` column at runtime via `AppModel`, not hardcoded — same seam
already used for `copy_pack`. Screens are restyled in place; no new views, no new state,
no new tables. Fonts are bundled, not system fonts, with a tested fallback path.

**Tech Stack:** SwiftUI (iOS 17+, existing project), XCTest, Supabase Postgres migration
(SQL), no new dependencies.

## Global Constraints

- **Paper-first, not dark-first**: warm cream/paper palette for all 8 screens in this
  plan (dark is reserved for Cook Mode's 3 stage screens — out of scope here). Confirmed
  2026-08-02, overrides the original product spec's dark-mode-first constraint. See
  `docs/superpowers/specs/2026-08-02-m3-visual-restyle-design.md` §3b.
- **No border radius anywhere on paper** — slips, cards, buttons, stamps are square.
  This is the single biggest carrier of the "printed" feel; don't default back to
  rounded corners out of habit.
- **Persona-tintable**: the seal accent color comes from `personas.tint`
  (`AppModel.household`'s persona row), never a hardcoded hex in a view file.
- **Traditional Chinese primary, CJK is the normal case** — Noto Serif TC (小當家's
  voice: dish names, verdicts, body, 眉批) and Noto Sans TC (interface chrome, labels,
  user input) are two distinct bundled fonts, not interchangeable, not system fonts.
- **copy_pack discipline**: no hardcoded persona-facing string in a view. Every string
  this plan touches is a `copy_pack` key with a neutral fallback.
- Minimum touch target 44pt; shopping rows 56pt (62pt at accessibility sizes).
- **Real device target**: iPhone 13 mini, 375pt logical width. The design is authored at
  402pt (iPhone 15/16 Pro) — verify layouts actually fit at 375pt, don't assume the
  larger canvas ports 1:1.
- Design reference for exact values: `design_handoff_sous_m3/README.md` (committed,
  read this alongside each task below) and the live canvas
  `design_handoff_sous_m3/Sous App v2.dc.html` (open directly in a browser — this is
  the higher-fidelity source when the README's prose is ambiguous about an exact pixel
  detail).

---

## Task 1: Design tokens + font fallback resolution

**Files:**
- Create: `ios/Sous/DesignTokens.swift`
- Test: `ios/SousTests/DesignTokensTests.swift`

**Interfaces:**
- Produces: `enum PaperTokens` (static `Color` constants: `stock`, `stockAlt`, `slip`,
  `ink`, `inkDim`, `inkFaint`, `rule`, `ruleStrong`, `leader`), `enum Spacing` (static
  `CGFloat`: `pageMargin = 34`, `deckMargin = 27`, `sm = 8`, `md = 16`, `lg = 24`),
  `func serifFontName(bundled: Bool) -> String`, `func sansFontName(bundled: Bool) ->
  String` — pure functions taking an explicit `bundled` flag so they're testable without
  depending on actual runtime font registration.
- Consumes: nothing (this is the foundation every other task builds on).

**Note on scope:** per-screen exact values (which weight, which size, where a rule
appears) live in the README and are applied directly in each screen task — this file
only holds the *shared* constants used across multiple screens. Don't try to
pre-enumerate every screen's typography here; that duplicates the README and drifts from
it.

- [ ] **Step 1: Write the failing tests for font fallback resolution**

```swift
// ios/SousTests/DesignTokensTests.swift
import XCTest
@testable import Sous

final class DesignTokensTests: XCTestCase {
    func testSerifFontNameUsesBundledFaceWhenAvailable() {
        XCTAssertEqual(serifFontName(bundled: true), "NotoSerifTC-Regular")
    }

    func testSerifFontNameFallsBackToSystemSerifWhenNotBundled() {
        // Songti TC (PostScript name STSongti-TC-Regular) is iOS's built-in
        // Traditional Chinese serif — a real fallback, not a sans substitute, since
        // the serif/sans split carries real meaning (小當家's voice vs. interface
        // chrome) and a sans fallback would silently erase that distinction everywhere
        // at once.
        XCTAssertEqual(serifFontName(bundled: false), "STSongti-TC-Regular")
    }

    func testSansFontNameUsesBundledFaceWhenAvailable() {
        XCTAssertEqual(sansFontName(bundled: true), "NotoSansTC-Regular")
    }

    func testSansFontNameFallsBackToSystemSansWhenNotBundled() {
        XCTAssertEqual(sansFontName(bundled: false), "PingFang TC")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios && xcodebuild test -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' -only-testing:SousTests/DesignTokensTests 2>&1 | tail -30`

Expected: FAIL — `serifFontName`/`sansFontName` not defined.

- [ ] **Step 3: Write `DesignTokens.swift`**

The serif fallback is **Songti TC** (`PostScript` family name `STSongti-TC-Regular`) —
iOS's built-in Traditional Chinese serif, matching Step 1's test. Do not use PingFang TC
(a sans face) as the serif fallback; the sans fallback in these functions is for
`sansFontName` only.

```swift
// ios/Sous/DesignTokens.swift
import SwiftUI

enum PaperTokens {
    static let stock = Color(red: 0xED / 255, green: 0xEA / 255, blue: 0xE2 / 255)
    static let stockAlt = Color(red: 0xE7 / 255, green: 0xE2 / 255, blue: 0xD8 / 255)
    static let slip = Color(red: 0xF7 / 255, green: 0xF4 / 255, blue: 0xEC / 255)
    static let ink = Color(red: 0x22 / 255, green: 0x20 / 255, blue: 0x1C / 255)
    static let inkDim = Color(red: 0x4E / 255, green: 0x4A / 255, blue: 0x42 / 255)
    static let inkFaint = Color(red: 0x5E / 255, green: 0x5A / 255, blue: 0x52 / 255)
    static let rule = ink.opacity(0.20)
    static let ruleStrong = ink.opacity(0.42)
    static let leader = ink.opacity(0.30)
}

enum Spacing {
    static let pageMargin: CGFloat = 34
    static let deckMargin: CGFloat = 27
    static let sm: CGFloat = 8
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
}

/// `bundled` is injected (not read from the font registry internally) so this stays a
/// pure, testable function — call sites pass `FontBook.isSerifBundled` (Task 3).
func serifFontName(bundled: Bool) -> String {
    bundled ? "NotoSerifTC-Regular" : "STSongti-TC-Regular"
}

func sansFontName(bundled: Bool) -> String {
    bundled ? "NotoSansTC-Regular" : "PingFang TC"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ios && xcodebuild test -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' -only-testing:SousTests/DesignTokensTests 2>&1 | tail -30`

Expected: PASS (4/4).

- [ ] **Step 5: Commit**

```bash
git add ios/Sous/DesignTokens.swift ios/SousTests/DesignTokensTests.swift
git commit -m "feat(ios): add paper design tokens and font fallback resolution"
```

---

## Task 2: copy_pack migration + persona tint update

**Files:**
- Create: `supabase/migrations/0016_paper_design_copy_pack.sql`

**Interfaces:**
- Produces: 11 new `copy_pack` keys on the seeded persona row (`app_subtitle`,
  `book_title`, `inbox_title`, `ritual_invite`, `thinking_stages` — JSON array,
  `wait_leave_ok`, `lock_hero`, `lock_signoff`, `failure_message`, `offline_note`,
  `empty_book`), plus updates `personas.tint` to the seal color.
- Consumes: nothing new. Does **not** touch `presence_in`/`presence_out` — those stay
  exactly as `[[sous-project-status]]`/migration `0015` left them; the handoff's
  instruction to delete them was overridden (see design spec §3), and their existing
  values (在廚房/外出中) are already correct for the restyled presence treatment in
  Task 5.

**Note on `ritual_invite` wording:** the handoff's copy ("該排下週的菜單了。給我十二張
牌的時間就好。") references the swipe-deck card mechanic, which doesn't exist in Pass
1a. Use the adapted wording below instead — same voice, no card-count reference.

- [ ] **Step 1: Write the migration**

```sql
-- supabase/migrations/0016_paper_design_copy_pack.sql
-- M3 visual restyle (Pass 1a): new copy_pack keys for the 書與灶 paper design,
-- and the seal-red persona tint. Does not touch presence_in/presence_out — kept
-- per docs/superpowers/specs/2026-08-02-m3-visual-restyle-design.md §3.

update personas set tint = '#9B2C1E' where id = '00000000-0000-0000-0000-00000000000a';

update personas set copy_pack = copy_pack || jsonb_build_object(
  'app_subtitle', '你的私廚,在口袋裡',
  'book_title', '私廚手記',
  'inbox_title', '與小當家的往來',
  'ritual_invite', '該排下週的菜單了,陪我聊幾句就好。',
  'thinking_stages', jsonb_build_array('看菜單…', '配菜…', '寫清單…'),
  'wait_leave_ok', '你可以先去忙 —— 排好我會放進便條通知你。',
  'lock_hero', '這一週,我來安排',
  'lock_signoff', '放心去過你的一週',
  'failure_message', '可惡…廚房出了點狀況,再讓我試一次。',
  'offline_note', '打勾照樣有效,回到訊號範圍我再同步。',
  'empty_book', '這本書還沒有第一道菜'
) where id = '00000000-0000-0000-0000-00000000000a';
```

- [ ] **Step 2: Apply locally and verify**

Run: `supabase db reset`

Expected: migration applies cleanly (no error), seed re-runs after it.

Run:
```bash
docker exec -it $(docker ps -qf "name=supabase_db") psql -U postgres -c \
  "select tint, copy_pack->>'app_subtitle' as subtitle, copy_pack->>'presence_in' as presence_in from personas;"
```

Expected: `tint` is `#9B2C1E`, `subtitle` is `你的私廚,在口袋裡`, `presence_in` is
still `在廚房` (unchanged, confirming the override held).

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/0016_paper_design_copy_pack.sql
git commit -m "feat(db): add paper design copy_pack keys and seal persona tint"
```

---

## Task 3: Bundle Noto Serif TC / Noto Sans TC fonts

**Files:**
- Create: `ios/Sous/Fonts/NotoSerifTC-Regular.otf`, `NotoSerifTC-Medium.otf`,
  `NotoSerifTC-SemiBold.otf` (weights 400/500/600 — the type scale in the design spec
  uses these three serif weights; skip 300 since nothing in Pass 1a's screens needs it)
- Create: `ios/Sous/Fonts/NotoSansTC-Light.otf`, `NotoSansTC-Regular.otf`,
  `NotoSansTC-Medium.otf` (weights 300/400/500)
- Modify: `ios/project.yml` (add font resources + `UIAppFonts`)
- Modify: `ios/Sous/DesignTokens.swift` (add a `FontBook` that checks real registration)
- Test: extend `ios/SousTests/DesignTokensTests.swift`

**This task has a manual prerequisite Mike needs to complete — it isn't something a
coding agent can do inside this sandbox:** download the OTF files for Noto Serif TC
(weights 400/500/600) and Noto Sans TC (weights 300/400/500) from Google Fonts
(SIL Open Font License — free to bundle) and place them at the paths above before
running Step 3. **The typography is not a cosmetic detail here — the serif/sans split
is the entire "Michelin cookbook" premise, so don't defer this indefinitely; screens
built against the system-serif fallback will look wrong until the real fonts land.**

- [ ] **Step 1: Write the failing test for runtime font detection**

```swift
// append to ios/SousTests/DesignTokensTests.swift
extension DesignTokensTests {
    func testFontBookDetectsBundledSerifWhenRegistered() {
        // UIFont.familyNames only includes fonts actually present in the bundle +
        // registered via Info.plist UIAppFonts, so this exercises the real path
        // rather than a mock.
        let isBundled = UIFont.familyNames.contains { $0.contains("Noto Serif TC") }
        XCTAssertEqual(FontBook.isSerifBundled, isBundled)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios && xcodebuild test -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' -only-testing:SousTests/DesignTokensTests 2>&1 | tail -30`

Expected: FAIL — `FontBook` not defined.

- [ ] **Step 3: Add font resources to the Xcode project**

In `ios/project.yml`, under the `Sous` target's `info.properties`, add:

```yaml
        UIAppFonts:
          - NotoSerifTC-Regular.otf
          - NotoSerifTC-Medium.otf
          - NotoSerifTC-SemiBold.otf
          - NotoSansTC-Light.otf
          - NotoSansTC-Regular.otf
          - NotoSansTC-Medium.otf
```

And add `Sous/Fonts` to the target's `sources` list (it's currently just
`sources: [Sous]`, which already recursively includes subdirectories — confirm this by
checking whether other non-`.swift` resources in `Sous/` are already picked up; if
XcodeGen needs an explicit resource entry instead, add
`- path: Sous/Fonts` `type: folder` `buildPhase: resources` under `sources`).

Run: `cd ios && xcodegen generate`

- [ ] **Step 4: Add `FontBook` to `DesignTokens.swift`**

```swift
// append to ios/Sous/DesignTokens.swift
import UIKit

enum FontBook {
    static var isSerifBundled: Bool {
        UIFont.familyNames.contains { $0.contains("Noto Serif TC") }
    }
    static var isSansBundled: Bool {
        UIFont.familyNames.contains { $0.contains("Noto Sans TC") }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd ios && xcodebuild test -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' -only-testing:SousTests/DesignTokensTests 2>&1 | tail -30`

Expected: PASS. If the font files aren't in place yet, this still passes (it's
asserting consistency between `FontBook` and the real registry, not that the fonts
exist) — but note in the task report whether `isSerifBundled`/`isSansBundled` are
actually `true`, since that's the real signal of whether Step 3's prerequisite was
completed.

- [ ] **Step 6: Commit**

```bash
git add ios/project.yml ios/Sous/DesignTokens.swift ios/SousTests/DesignTokensTests.swift ios/Sous/Fonts/
git commit -m "feat(ios): bundle Noto Serif/Sans TC with system-serif fallback"
```

---

## Task 4 through 11: screen restyles

Each of the following is one task. **Unlike Tasks 1–3, these are not TDD-shaped** —
visual restyling has no meaningful unit test (you cannot assert "this label uses Serif
31pt" in XCTest in a way that catches a real regression better than looking at it).
Each screen task instead has:

- The exact current file(s) to modify.
- The exact section(s) of `design_handoff_sous_m3/README.md` to implement from (open
  the corresponding section in `design_handoff_sous_m3/Sous App v2.dc.html` in a
  browser for pixel reference — the README is a transcription, the canvas is the
  source of truth for anything the README's prose leaves ambiguous).
- Which `DesignTokens` constants and `copy_pack` keys apply.
- An explicit acceptance bar in place of a unit test.

Existing logic files (`*Logic.swift`) and their tests are **not touched** by any of
these tasks — this is a view-layer restyle only. If a screen task seems to require
changing a `Logic.swift` file's behavior, stop and flag it — that's a sign the task has
drifted into Pass 1b/1c territory (new interaction), not Pass 1a (restyle).

### Task 4: Auth (A1)

**Files:** Modify `ios/Sous/AuthView.swift` (52 lines — the whole file).
**Design reference:** README "A1 · 扉頁 (Auth)".
**Tokens/copy:** `PaperTokens.stock` background, `serifFontName`/`sansFontName` via
`FontBook`, new key `app_subtitle`.
**Acceptance:** Build succeeds. Visually matches README's A1 description (centered
column, seal square, headline, outlined Apple sign-in button) at both 402pt (simulator
default) and 375pt (iPhone 13 mini simulator or real device). Existing auth
functionality (Sign in with Apple flow) unchanged — this task touches layout/styling
only, not `AuthView`'s auth logic.

- [ ] Restyle per the reference above.
- [ ] Build: `cd ios && xcodebuild build -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' 2>&1 | tail -20` — expect `BUILD SUCCEEDED`.
- [ ] Run full test suite (`-only-testing` omitted) to confirm no regressions: expect the same pass count as before this task, plus Tasks 1–3's new tests.
- [ ] Commit: `git commit -m "feat(ios): restyle Auth screen to paper design"`

### Task 5: Kitchen Counter (A2), including the presence correction

**Files:** Modify `ios/Sous/CounterView.swift` (131 lines).
**Design reference:** README "A2 · 廚房 (Kitchen Counter — root)".
**Presence correction (the one piece of real logic change in this task):** replace the
current flame/moon icon + colored label (`CounterView.swift:86-92`, using
`chefIsPresent(workerSeenAt:)` from `Models.swift:88` — **do not modify that function,
it's correct and tested**) with a seal-glyph treatment: filled seal when
`chefIsPresent(...)` is true, nothing extra shown (per the design's "a book's author has
no presence indicator when things are fine"); hollow seal (`1px ink@30% border,
transparent fill`) plus the existing `presence_out` copy string when false. This is a
visual swap only — the boolean and its copy keys are unchanged, only how they render.
**Tokens/copy:** `presence_in`/`presence_out` (existing, unchanged), `empty_book` (if
`model.household`'s tonight dish is nil — the "第一頁" empty state from README §G),
`PaperTokens.stockAlt` note: A2 uses regular `stock`, not `stockAlt` (that's deck
screens only, out of scope here).
**Acceptance:** Build succeeds, full test suite still passes including `PresenceTests`
(unchanged, still exercising the untouched `chefIsPresent` function). Visually matches
README A2 at 375pt. Tapping through to Week Board / Shopping / Cookbook / 便條 still
navigates correctly (existing navigation, not touched).

- [ ] Restyle per the reference above, including the presence seal swap.
- [ ] Build and run full test suite as in Task 4.
- [ ] Commit: `git commit -m "feat(ios): restyle Kitchen Counter, seal-based presence"`

### Task 6: 便條 / Chat (A3)

**Files:** Modify `ios/Sous/ChatView.swift` (87 lines).
**Design reference:** README "A3 · 便條 (the slip thread)".
**Scope guard:** this task restyles the existing flat conversation view only. The
邊欄 (margin-note-attached-to-a-recipe-page) concept from the handoff is **not** built
here — per the design spec §4, it's deferred to Pass 2 and may not even be the right
interpretation of the original ask. If it's tempting to start threading messages to
recipes here, stop — that's out of scope.
**Tokens/copy:** `inbox_title` (new key, header), existing chat copy unchanged.
**Acceptance:** Build succeeds, full test suite passes (including the keyboard/scroll
fix tests from commit `0784e95` — don't regress those). Visually matches README A3 at
375pt: his slips left-styled with seal left border, user messages right-aligned
outlined boxes, composer with seal `↑`.

- [ ] Restyle per the reference above.
- [ ] Build and run full test suite as in Task 4.
- [ ] Commit: `git commit -m "feat(ios): restyle chat/便條 thread to paper design"`

### Task 7: Written ritual — waiting state and lock (B2, B3)

**Files:** Modify `ios/Sous/WeekBoardView.swift` (118 lines) and/or `ChatView.swift`
depending on where the current ritual waiting/lock UI actually lives — **check both
files first**; the ritual conversation flows through the chat job pipeline
(`sendSystemAction`/`waitForReply` in `AppModel.swift`), so the waiting state may need
to render inside `ChatView` rather than `WeekBoardView`. Confirm before editing.
**Design reference:** README "B2 · 對話儀式 (written ritual — ships today)" and
"B3 · 鎖定 (lock)".
**Tokens/copy:** `thinking_stages` (new key, JSON array — rotate through it every 2.6s
per the README while a ritual job is in flight), `wait_leave_ok` (new key), `lock_hero`/
`lock_signoff` (new keys).
**Scope guard:** the design's B2 also mentions "every fixed-choice moment also offers
chips" — this is the quick-reply idea from the original brief. Include it if the
existing ritual flow already has clearly-identifiable fixed-choice moments to attach
chips to; if it requires the worker to emit structured choice data (a real backend
contract change), stop and flag it as Pass 1b/Pass 2 scope instead of improvising a
client-side guess at what the choices are.
**Acceptance:** Build succeeds, full test suite passes. The waiting state shows a
rotating stage word, not a bare spinner. Ritual functionality (start, converse, lock)
unchanged — this is a rendering change around an existing job/state flow, not a new one.

- [ ] Locate the current ritual waiting/lock rendering (check both files above).
- [ ] Restyle per the reference above.
- [ ] Build and run full test suite as in Task 4.
- [ ] Commit: `git commit -m "feat(ios): restyle ritual waiting and lock states"`

### Task 8: Shopping List (E1)

**Files:** Modify `ios/Sous/ShoppingListView.swift` (34 lines).
**Design reference:** README "E1 · 採買清單 (shopping)".
**Tokens/copy:** `offline_note` (new key) — add as static informational text near the
list; **do not build live network-reachability detection for this task** (no such
capability exists in the codebase today and adding it is a separate concern from
restyling — just surface the copy as a persistent caption, not a conditional banner).
**Scope guard:** checkbox behavior (`shopping_items.checked`, instant local write) is
existing `ShoppingListLogic` behavior — don't touch the logic file, only the view.
**Acceptance:** Build succeeds, full `ShoppingListLogicTests` and full suite pass
unchanged. Visually matches README E1 at 375pt: 56pt rows, square checkbox, checked
rows at 50% opacity with strikethrough and quantity replaced by 已買.

- [ ] Restyle per the reference above.
- [ ] Build and run full test suite as in Task 4.
- [ ] Commit: `git commit -m "feat(ios): restyle shopping list to paper design"`

### Task 9: Week Board (E2)

**Files:** Modify `ios/Sous/WeekBoardView.swift`.
**Design reference:** README "E2 · 本週 (week board)".
**Scope guard — important:** the README's E2 description shows a dual ritual entry
("next week offers both ritual models by name: ink-filled 滑牌排 and outlined 用寫的").
**Do not build the dual-button version.** Pass 1a doesn't have a swipe ritual to link
to. Keep the single existing 開始本週儀式 entry point, restyled to the new tokens
(ink-filled button per the design's button language), pointing at the same written
ritual as today.
**Tokens/copy:** existing week-board copy, no new keys needed for this screen.
**Acceptance:** Build succeeds, full `WeekBoardLogicTests` and full suite pass
unchanged. Visually matches README E2 at 375pt (printed table, tonight as the only
slip on the page, long-press-to-swap unchanged) minus the dual ritual-entry piece.

- [ ] Restyle per the reference above, single ritual entry point only.
- [ ] Build and run full test suite as in Task 4.
- [ ] Commit: `git commit -m "feat(ios): restyle week board to paper design"`

### Task 10: Cookbook (D2)

**Files:** Modify `ios/Sous/CookbookView.swift` (47 lines).
**Design reference:** README "D2 · 食譜本 (cookbook)".
**Tokens/copy:** `book_title` (new key, if used as a heading here — otherwise it
belongs on Task 11's Settings colophon; use it in whichever screen actually has an
"imprint" moment per the live canvas, not both), `empty_book` (new key, empty state).
**Scope guard:** this becomes "a table of contents, not a card grid" per the design —
that's a real layout change (list-by-chapter instead of grid), but it's still a pure
restyle of existing data (`CookbookLogic.filteredRecipes`, unchanged) into a different
`View` body, not new logic.
**Acceptance:** Build succeeds, full `CookbookLogicTests` and full suite pass unchanged.
Visually matches README D2 at 375pt: search field, filter chips, chapter grouping by
ingredient, folio-numbered rows.

- [ ] Restyle per the reference above.
- [ ] Build and run full test suite as in Task 4.
- [ ] Commit: `git commit -m "feat(ios): restyle cookbook as table of contents"`

### Task 11: Onboarding + Notification Settings (E3)

**Files:** Modify `ios/Sous/OnboardingView.swift` (156 lines) and
`ios/Sous/NotificationsSettingsView.swift` (72 lines).
**Design reference:** README "E3 · 設定 (settings as colophon)" for Settings; the
handoff README doesn't have a dedicated Onboarding section (it wasn't called out
separately in the screen list) — restyle Onboarding to the same tokens
(`PaperTokens`, square shapes, serif/sans split) for visual consistency with everything
else, using the existing wizard structure and existing `onboarding_*` copy_pack keys
unchanged.
**Tokens/copy:** `book_title` (new key, if not already used in Task 10 — see that
task's note), existing `onboarding_*` keys unchanged, printed-square toggle style for
notification switches per E3 ("filled seal = on, outlined = off").
**Scope guard:** `OnboardingLogic`/`NotificationsLogic` are unchanged — view-layer only.
**Acceptance:** Build succeeds, full `OnboardingLogicTests`/`NotificationsLogicTests`
and full suite pass unchanged. Onboarding wizard flow (steps, chips, stepper,
completion screen) still functions identically, just restyled.

- [ ] Restyle both screens per the reference above.
- [ ] Build and run full test suite as in Task 4.
- [ ] Commit: `git commit -m "feat(ios): restyle onboarding and notification settings"`

---

## Self-Review

**Spec coverage:** §2's in-scope items for Pass 1a (design system, presence
correction, copy_pack sweep for touched screens, font bundling) each map to a task
above. Recipe Detail and Cook Mode (§2's other items) are explicitly Pass 1b/1c, not
missing — see this plan's own scope statement. §5's `cook_sessions.photo_url` and step
timer duration are Pass 1c, correctly absent here. §6's persona-tint constraint is
handled by Task 2 (tint column) + the constraint that no task hardcodes a color that
should route through it.

**Placeholder scan:** no TBD/TODO left in any step; Task 3's manual-prerequisite note is
an explicit instruction with a concrete deliverable (specific files, specific paths),
not a vague placeholder. Task 7's "check both files first" is a real, boundable
investigation step (two named files), not an open-ended "figure it out."

**Type consistency:** `serifFontName(bundled:)`/`sansFontName(bundled:)` (Task 1) are
consumed by `FontBook` (Task 3) — same signatures throughout. `chefIsPresent
(workerSeenAt:now:threshold:)` (existing, `Models.swift:88`) is referenced identically
in Task 5's description and is explicitly marked not-to-be-modified in every place it's
mentioned.

**Scope check:** every task's "Scope guard" line exists specifically to stop a screen
task from silently absorbing Pass 1b/1c/Pass 2 work (chat rearchitecture, swipe ritual
entry points, grading changes). If an implementer hits one of those guards and the
screen genuinely can't be restyled without crossing it, that's a signal to stop and
report back rather than improvise.
