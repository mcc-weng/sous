# M3 Visual Restyle — Pass 1b: Recipe Detail (D1) Design

**Status:** Approved, ready for planning.
**Parent spec:** `docs/superpowers/specs/2026-08-02-m3-visual-restyle-design.md` (§2
scopes Recipe Detail into Pass 1; this doc is the sub-spec for that one screen, same
split as Pass 1a's foundation-only plan referenced needing "separate plans" for D1/Cook
Mode).
**Design reference:** `design_handoff_sous_m3/README.md` §D1 and the live canvas
`Sous App v2.dc.html` (lines ~481–558) — the primary source for the paper-restyle parts
of this screen. This doc does not restate those values; it records the parts that
mockup doesn't cover and the corrections layered on top.

## Context

`RecipeDetailView.swift` is currently unstyled (plain `GroupBox` sections) and needs the
書與灶 paper system applied, same as Pass 1a's 8 screens. Unlike those screens, D1 isn't
a pure restyle: the parent spec's §2 bullet for D1 lists "photo carousel" and "unit/
print/copy icon row," neither of which appears in the actual mockup (README or
`Sous App v2.dc.html` show one static photo, no icon row) — drift from when the Pass 1
spec was written, not literal requirements. Brainstormed 2026-08-04 to decide what these
should actually be, since Mike wants both built as real (if new) features rather than
dropped.

## Scope decisions made during brainstorming

- **Photo carousel is new UI, tap-to-advance, not swipe.** Tinder-style invisible tap
  zones (right half = next, left half = previous) with thin progress-segment bars along
  the top edge showing photo count/position — no arrows. Swipe is deliberately avoided
  because it's reserved for the separate swipe-ritual gesture elsewhere in the app;
  reusing it here would collide.
- **Carousel photo sources, this pass: placeholders + your own cook photos (once
  available) only.** Two sources were on the table — auto-found reference photos (like
  a web image search) and the user's own 上菜 cook-completion photos. The auto-found
  path is a new worker capability (web image search, a new job kind, a storage/URL
  schema, a `state_api.py` verb, real copyright/licensing questions) — explicitly **not**
  a restyle, so it's cut from Pass 1b and deferred to its own future spec. The
  cook-photo path is real but blocked: `cook_sessions.photo_url` doesn't exist until
  **Pass 1c** (Cook Mode redesign) adds that column. So Pass 1b ships the carousel
  *component* as placeholder-only (hatched slots, no query against `cook_sessions` at
  all — that column doesn't exist yet, so nothing to query) — no dedicated Pass 1b
  backend work, no upload flow. Wiring the carousel to real `cook_sessions.photo_url`
  rows is a small follow-up task that belongs to **Pass 1c's** plan, once that column
  exists (most-recent-first ordering, no cap needed) — not Pass 1b's.
- **Servings stepper gets real live rescale, backed by new structured-quantity data.**
  Both the servings stepper and the unit toggle need a number+unit, not the current
  free-text `Ingredient.qty: String?`. Rather than defer both (mockup only) or fake it
  client-side (regex-parsing free text — rejected as fragile per CLAUDE.md's "no
  temporary fixes"), this pass adds `recipes.servings` and optional structured
  `qtyValue`/`qtyUnit` fields to `Ingredient`, populated going forward by
  `recipe_intake.md`. Old recipes degrade gracefully per-row (see Data model below) —
  no backfill of ingredient quantities, since parsing free-text quantities reliably
  needs an LLM pass and isn't a "restyle" cost worth taking on here.
- **`recipes.servings` backfills cleanly, unlike ingredient quantities.**
  `recipe_intake.md` already normalizes every recipe to `份量換算到 2 人份` today —
  every existing recipe already implicitly assumes 2 servings. Backfilling
  `recipes.servings = 2` for all existing rows is therefore accurate, not a guess, and
  removes the "missing servings" case entirely. Only per-ingredient `qtyValue`/`qtyUnit`
  genuinely stays nil on old recipes.
- **邊欄 exchange is excluded from Pass 1b entirely**, confirmed against the mockup
  showing it live on D1. `ChatMessage` (`Models.swift`) has no `recipe_id` — there's no
  existing link between a chat message and a recipe, so the parent spec's "if trivial"
  carve-out (§2) doesn't apply, consistent with §4's separate deferral of the full 邊欄
  rearchitecture to Pass 2. D1 in Pass 1b ends at steps/notes/verdict history; no
  chat-on-page.
- **Print and copy icons get the standard iOS pattern, not bespoke UI.** Neither appears
  in the mockup, so both were designed fresh: 拷貝 copies the recipe as formatted plain
  text to the clipboard; 列印 hands that same text to the system share sheet
  (`UIActivityViewController`), which already surfaces AirPrint — no dedicated
  print-layout screen.
- **Unit toggle only affects convertible continuous units.** 公制/英制 toggle
  (metric/imperial) is a local, non-persisted view preference — not written to the
  server — and only touches weight/volume units via a small hardcoded conversion table.
  Discrete count units (顆/支/片/瓣/把/條/塊) are untouched by the toggle and never
  receive fractional values from rescale (see Rescale math below), matching
  `recipe_intake.md`'s existing "don't fabricate fake fractions" rule for these.

## Data model changes

**Migration** (next sequential number after the latest applied):
- `recipes.servings smallint not null default 2` — backfilled to `2` for all existing
  rows in the same migration (see rationale above).

**`Ingredient` (`Models.swift`)** — two new optional fields, existing `qty` kept as the
display fallback:
```swift
struct Ingredient: Codable, Equatable, Hashable {
    let name: String
    let qty: String?        // unchanged — free-text display fallback
    let qtyValue: Double?   // new — numeric magnitude, nil if not cleanly parseable
    let qtyUnit: String?    // new — unit string ("g", "ml", "cup", "顆", ...), nil if qtyValue is nil

    enum CodingKeys: String, CodingKey {
        case name, qty
        case qtyValue = "qty_value"
        case qtyUnit = "qty_unit"
    }
}
```

**`Recipe` (`Models.swift`)** — new `servings: Int` field (`CodingKeys` maps
`servings`).

**`worker/state_api.py`** — `save_recipe` gains a `servings: int` parameter (default 2
if the caller omits it, matching the migration default), inserted/updated alongside the
existing columns.

**`worker/prompts/recipe_intake.md`** — updated to emit `qty_value`/`qty_unit` in the
`--ingredients` JSON when a quantity cleanly parses (e.g. `qty:"300g"` →
`qty_value:300, qty_unit:"g"`), and to omit both (leave `qty` as the only field, as
today) when it doesn't — same judgment call the prompt already makes for "1 顆蛋" vs.
"300g雞胸肉", just now surfaced as structured data instead of only prose.

## What's landing (iOS)

**`RecipeDetailView.swift`** — restyled to the paper system (running head, folio, seal
`第 X 道` numeral, Serif title, description, ingredient/step sections) per the D1 mockup,
plus:

- **Photo carousel** (new subview, e.g. `RecipePhotoCarousel.swift`): tap-zone
  navigation, progress-segment bars, placeholder-only in this pass — a single hatched
  slot, matching Pass 1a's precedent for un-populated imagery. Does not query
  `cook_sessions` (see Scope decisions — that column doesn't exist until Pass 1c).
  Built so a later data source is a prop/binding change, not a rebuild.
- **Servings stepper**: `@State private var currentServings: Int`, initialized from
  `recipe.servings`. −/+ adjusts it for this viewing session only — no `state_api` write.
  Purely a display multiplier; nothing persists.
- **Rescale math** (new pure-logic function, e.g. `RecipeScalingLogic.swift`, mirroring
  `CookHistoryLogic.swift`'s pattern of logic-only, no view/network code):
  - For ingredients with `qtyValue` set: `qtyValue * currentServings / recipe.servings`.
  - **Discrete units** (hardcoded set: 顆/支/片/瓣/把/條/塊, extend as needed) round to
    the nearest whole number, minimum 1.
  - **Continuous units** (g/ml/kg/L/cup/tbsp/tsp/oz/lb/fl oz) round to 1 decimal place.
  - Ingredients with `qtyValue == nil` render their free-text `qty` unchanged, un-rescaled.
- **Unit toggle**: local `@State` (or `@AppStorage` if it should persist across
  launches — implementation detail, doesn't need a spec decision), cycling 公制/英制,
  **defaulting to 公制** (Taiwan's standard, matches the app's TC-first orientation).
  Converts continuous units via a small hardcoded table (g⇄oz, kg⇄lb,
  ml/L⇄cup/tbsp/tsp/fl oz). Discrete units are never touched by this toggle.
- **Print/copy icon row**: 拷貝 builds a formatted plain-text string (title, current
  ingredient list at `currentServings`, numbered steps) and writes it to
  `UIPasteboard.general.string`, with a haptic + brief toast confirmation. 列印 passes
  the same string to `UIActivityViewController` via `.sheet`/`UIViewControllerRepresentable`.
- **Steps**: unchanged data path (`RecipeStep.tip`/`durationSec` already exist), restyled
  to the mockup's numbered/Chinese-numeral + inline 眉批 + duration treatment.
- **Verdict history**: existing `GroupBox` block restyled to the mockup's "這一頁的紀錄"
  list treatment — no logic change.

## Error handling

- `recipe.servings` is non-optional (`Int`, backed by the `not null default 2` column),
  so there's no missing-servings state to guard in the UI post-migration — the "hide the
  stepper if data's missing" fallback discussed during brainstorming turned out
  unnecessary once the clean backfill was found (see Scope decisions); the DB constraint
  makes it structurally impossible, not just unlikely.
- Clipboard/share-sheet failures (rare on-device) fail silently — copying/printing a
  recipe is a convenience action, not a blocking one; no error alert needed, matching the
  existing best-effort precedent for `startSession()`.

## Testing

Unit tests for `RecipeScalingLogic`:
- Continuous-unit rescale: `300g @ 2→4 servings` → `600.0g`; `1.5 cup @ 4→2` → `0.8 cup`
  (1-decimal rounding).
- Discrete-unit rescale never produces a fraction: `1 顆 @ 2→3 servings` → `2 顆` (rounds
  up to nearest whole, minimum 1), not `1.5 顆`.
- Ingredients with `qtyValue == nil` pass through unchanged regardless of servings delta.
- Unit toggle conversion table: spot-check one weight pair (g⇄oz) and one volume pair
  (ml⇄cup) round-trip within reasonable rounding tolerance.

No changes needed to existing verdict-loading tests — that path is unchanged, only
restyled.

## Verification / exit criteria

- Unit tests: 97/97 passing on `main` post-merge (94 from the plan's 10 tasks + 3 more
  from a whole-branch-review fix — see below).
- Whole-branch review (opus): Ready to merge = Yes (with fixes), no Critical/Important
  findings. One real cross-task gap found and fixed: `recipe_intake.md`'s own worked
  example emits Traditional Chinese volume units (`大匙`/`小匙`/`杯`) that
  `RecipeScalingLogic.swift`'s conversion table didn't recognize, so the metric/imperial
  toggle silently no-op'd for the most common TC volume units — fixed by adding them as
  clean Asian-cooking-convention entries (15/5/240 ml), plus two Minor touch-target gaps
  (`minWidth: 44` missing on two buttons), re-reviewed clean.
- Real-device exit check (2026-08-05): built, installed, and launched directly on Mike's
  iPhone 13 mini via `xcrun devicectl` (generic-iOS build, signed, then
  `devicectl device install app` / `device process launch` — the specific-device
  `xcodebuild` destination hit a transient "developer disk image could not be mounted"
  error, worked around by building generically first). Confirms the app runs on real
  hardware at the true 375pt width. **Not independently confirmed: the actual visual
  appearance of the restyled Recipe Detail screen, servings stepper, unit toggle, photo
  carousel, and icon row on-device** — no screenshot/screen-mirroring tool was available
  in this environment to inspect the physical screen, so this exit check covers the
  mechanical deploy path only, not the visual walkthrough Pass 1a's exit check had.
  **Open: Mike to eyeball the Recipe Detail screen on-device** (open any recipe from
  Cookbook) before treating Pass 1b as fully closed the way Pass 1a is.

## Out of scope (deferred, not forgotten)

- Auto-found reference photos (web search sourcing) — own future spec.
- 邊欄 chat-on-recipe-page — Pass 2, alongside the `recipe_id` linking work the parent
  spec's §4 already calls out.
- Backfilling structured `qtyValue`/`qtyUnit` onto existing recipes — would need an LLM
  pass over free-text quantities; not attempted here.
- Persisting servings adjustments back to the recipe (e.g. "this household always cooks
  this for 4") — the stepper is view-local/ephemeral only in this pass.
