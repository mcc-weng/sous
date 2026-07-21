# M2c2 — Recipe Pipeline iOS Design

**Status:** Approved, ready for planning.

## Context

M2c1 shipped the recipe pipeline backend: a `recipe_intake` job kind, `gemini_intake.py`
(pre-fetch via yt-dlp captions + Gemini video understanding), and the `save-recipe`
state_api verb (upsert-by-slug into `recipes`). It's merged to main and cloud-verified
(`docs/superpowers/plans/2026-07-20-m2c1-recipe-pipeline-backend.md`'s `## M2c1 cloud
exit verification` section) — the real worker daemon, polling the real cloud `jobs`
table, successfully turned a real YouTube recipe video into a structured `recipes` row,
a craving inbox item, and an in-persona chat announcement.

What's still missing is everything on the iOS side: no way for a real user to *create*
a `recipe_intake` job (M2c1 tested it via direct DB insertion), no way to browse the
recipes that exist, and no way to actually cook one. This is M2c2's scope, per the
original design spec (`docs/specs/2026-07-11-sous-app-design.md`): **share-sheet
intake** (share an IG/YT/web link → job created), **cookbook** (searchable recipe
grid, verdict history), and **cook mode** (备料 checklist → teleprompter).

## Scope decisions made during brainstorming

- **No push notifications in M2c2.** The original spec describes a push ("新菜學會了!")
  when the card lands, but there is zero APNs infrastructure anywhere yet (client or
  server) — that's explicitly M3 scope. The share extension fires the job and exits;
  the user discovers the finished recipe next time they open the cookbook. Push gets
  wired in during M3 without changing this flow.
- **One phase, three task groups**, not three separate M2c2/M2c3/M2c4 phases. The three
  surfaces (share extension, cookbook, cook mode) share the same `recipes` data model
  and are meant to be used together; splitting into separate merge/exit-check cycles
  would add process overhead without much isolation benefit. This mirrors M2b2, which
  bundled week-board + shopping-list UI into one plan.
- **No step-aware chat rail in cook mode v1.** The original spec describes an embedded
  chat during the teleprompter for step-aware Q&A. That needs new backend
  context-rendering work (threading the current cook session/step into a chat job) plus
  embedded chat UI on the one full-screen surface — deferred. If the user needs to ask
  the chef something mid-cook, they exit cook mode and use the existing chat sheet.
- **No real countdown timers in v1.** Steps carry an optional `duration_sec`; v1 just
  displays it as text (e.g. "約 15 分鐘") rather than running a background-safe countdown
  with local notifications. That's its own meaningful chunk of iOS work, worth its own
  pass once the core teleprompter flow is proven.
- **No recipe editing UI.** Recipes are brain-authored via `save-recipe`
  (upsert-by-slug); there's no `update-recipe` verb and no indication in the original
  spec of user-editable recipe cards for v1.

## Architecture

Three task groups plus one backend migration:

1. **Share extension** — new Xcode target, direct-insert architecture.
2. **Cookbook sheet** — fourth bottom sheet alongside week/shopping, following the
   existing `WeekBoardView`/`WeekBoardLogic` split pattern.
3. **Cook mode** — new full-screen (non-sheet) surface, direct client writes to
   `cook_sessions`/`verdicts` (both already have full RLS access for household members
   from `0002_rls.sql` — `cook_rw`, `verdict_rw` — this predates M2c2 and needs no new
   migration).
4. **`jobs_write` RLS migration** — adds `recipe_intake` as an allowed `kind`, mirroring
   `0005_jobs_allow_ritual_kind.sql`'s fix for `ritual`. Required for the share
   extension to work at all; flagged as a carry-in gap when M2c1 merged.

No new backend/worker code is needed beyond the migration — M2c1's pipeline already
handles everything a `recipe_intake` job needs to do.

## Component 1: Share extension

New target `SousShareExtension` (bundle id `com.mikeweng.SousShareExtension`), sharing
App Group `group.com.mikeweng.sous` with the main app (`com.mikeweng.sous`). The App
Group enables two things:

- A shared **Keychain access group**. `supabase-swift`'s `SupabaseClient` stores its
  session in the Keychain by default; both the main app and the extension initialize
  their `SupabaseClient` with the same explicit keychain access group, so the extension
  inherits whatever session the main app is signed into — no separate sign-in flow in
  the extension. This requires a small change to the *main app* target too:
  `AppModel`'s `SupabaseClient` init needs the explicit access group added (it
  currently uses the SDK's unconfigured default), not just the new extension target.
- A shared `UserDefaults(suiteName:)` container caching `household_id`, so the
  extension can insert without an extra network round-trip before showing
  confirmation. This requires adding one line to `AppModel.refreshHousehold()` (in the
  main app) to write `household_id` into the shared container whenever it refreshes —
  new behavior, not something that exists today.

**Activation rule:** `NSExtensionActivationSupportsWebURLWithMaxCount = 1` in the
extension's `Info.plist` — the standard URL-share rule, works from Safari, Instagram,
YouTube, or anything else that shares a URL.

**UI:** a minimal SwiftUI-hosted view (not the legacy `SLComposeServiceViewController`
composer) — shows the captured URL, one confirm action, then a brief success/failure
state before auto-dismissing. The insert mirrors `AppModel.sendSystemAction`'s existing
pattern exactly:

```swift
try await client.from("jobs")
    .insert(NewJob(household_id: cachedHouseholdId, kind: "recipe_intake",
                    payload: .init(url: sharedURL, by: "mike")))
    .execute()
```

**Error handling (inline, no crash, no retry queue):**
- No session in the shared Keychain (never signed in on this device, or the access
  group is misconfigured) → "先打開小當家登入".
- Insert fails (offline, RLS rejection) → inline error message; the user can just
  re-share later. No background retry queue for v1 — matches the rest of the app's
  current "no realtime, best-effort" posture (see M2b2's realtime-removal decision).

## Component 2: Cookbook

**Models** (`Models.swift`): `Recipe` (id, householdId, slug, title, sourceBlock,
bodyMd, ingredients: [Ingredient], steps: [Step], createdAt), `Ingredient` (name, qty),
`Step` (text, stage?, durationSec?, tip?) — matching `recipes`' JSONB shape exactly.

**AppModel:** `@Published var recipes: [Recipe] = []`, `func loadCookbook() async`.
Loaded lazily on sheet appear (`.task`, same pattern `WeekBoardView` already uses),
*not* folded into `loadAll()` — the user may never open the cookbook in a session.

**`CookbookView`/`CookbookLogic.swift`** (mirrors the existing `WeekBoardView`/
`WeekBoardLogic` split): a search field driving a client-side substring filter over the
already-loaded `recipes` array (no full-text search infra needed at this scale — v1
recipe counts are small), a card grid (`LazyVGrid`), added as a fourth sheet in
`CounterView` alongside week board and shopping list.

**Recipe detail view:** `source_block` (verbatim 📌 original), the structured card
(ingredients list, numbered steps with tips), verdict history + "上次煮". Verdicts
reference `plan_day_id`, not `recipe_id` — there is no direct recipe→verdict foreign
key. Verdict history is fetched via a PostgREST embedded-resource query joining through
`plan_days.recipe_id`:

```swift
client.from("verdicts")
    .select("*, plan_days!inner(recipe_id)")
    .eq("plan_days.recipe_id", value: recipe.id)
    .order("created_at", ascending: false)
```

"上次煮" is the most recent result's date, shown on both the card and detail view. A
"開始煮" button on the detail view launches `CookModeView(recipe: recipe, planDay: nil)`.

## Component 3: Cook mode

`CookModeView(recipe: Recipe, planDay: PlanDay?)`, presented `.fullScreenCover` (the
one non-sheet surface, per the original spec) from two entry points: the week
board/tonight card (`planDay` set — cooking something on this week's plan) and a
cookbook recipe's "開始煮" button (`planDay == nil` — cooking something not currently
planned).

**Flow:**
1. On appear, insert a `cook_sessions` row (`recipe_id`, `started_at`) directly via the
   client (`cook_rw` RLS policy already permits this). This is optimistic and
   best-effort — a failed insert doesn't block cooking, mirroring the shopping
   checkbox's existing optimistic-update-with-no-hard-gate precedent from M2b2.
2. **備料 checklist gate:** derived from `ingredients`, local `@State` checklist (not
   persisted — this is a lightweight pre-cook gate, not a tracked feature). All checked
   (or explicitly skipped) advances to the teleprompter.
3. **Teleprompter:** one step per screen, paginated over `steps` (swipe/tap to
   advance), each showing `text` + optional `tip` + `durationSec` as plain text (e.g.
   "約 15 分鐘" — no interactive timer per the scope decision above). A step-list-jump
   affordance opens a lightweight list to jump directly to any step.
4. **Completion:** tapping through the last step updates `cook_sessions.completed_at`
   (+ `step_ticks`). If `planDay != nil`, shows an optional, skippable verdict prompt
   (神作/不錯/普通/翻車 + free-text note) that inserts into `verdicts` with that
   `plan_day_id` (`verdict_rw` RLS policy already permits this). If `planDay == nil`
   (cooked from cookbook, nothing to rate against), skips straight to a "煮好了!"
   dismiss state.
5. Dismissing returns to whichever surface launched it.

No new state_api verbs, no brain/job involvement anywhere in cook mode — every write is
a direct, mechanical, app-native client write, the same carve-out already established
for the shopping checkbox.

## Testing / verification

Real-device exit check, mirroring M2b2's precedent (Mike's phone, cloud project): share
a real recipe URL from Instagram or YouTube's native share sheet, confirm the job is
created and processed, open the cookbook and confirm the new card appears with correct
data, search for it, open detail view, start cook mode from both entry points (tonight
plan day and cookbook), complete the checklist and teleprompter, confirm a verdict can
be submitted (plan-day entry) and is correctly skipped (cookbook entry), confirm
`cook_sessions`/`verdicts` rows land correctly in the DB.

## Out of scope (tracked for later)

- Push notification on job completion — M3 (APNs soul pass).
- Step-aware chat rail during cook mode — needs new backend context-rendering work,
  deferred alongside the M3 quick-reply-buttons work already tracked in project memory.
- Real countdown timers with local notifications for steps with `duration_sec`.
- Recipe editing UI (fixing bad extractions) — no backend verb exists for this either.
- The WebFetch fallback path for plain (non-video) recipe URLs was never exercised in
  M2c1's testing (every smoke test used a video URL) — the share extension will
  faithfully hand off whatever URL type is shared, but a plain-web-recipe end-to-end
  test is still an open gap carried in from M2c1, not something M2c2 needs to fix.
