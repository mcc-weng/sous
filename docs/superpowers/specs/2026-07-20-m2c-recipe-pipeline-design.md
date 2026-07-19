# Sous M2c — Recipe Pipeline Design Spec

**Date:** 2026-07-20
**Status:** Approved design, pre-implementation
**Scope:** Structured recipe data + share-sheet intake + cookbook + cook mode — the last
piece of M2 before the "planned, shopped, cooked entirely in the app" exit test can be
attempted for real. Split into two build phases (own plan/worktree/review cycle each,
same pattern as M2a → M2b1 → M2b2), documented together here since both consume one data
model and were designed in one pass.

## Context

`recipes` (slug, title, source_block, body_md, ingredients JSONB, steps JSONB) has existed
in the schema since the M1 migration; nothing has ever written to it. `plan_days.recipe_id`
has existed just as long and has never been set by any code path either. Alfred
(`~/Projects/alfred`) has a working, real-world-proven intake pipeline
(`scripts/recipe_intake.py`, `scripts/save_recipe.py`) worth porting the *mechanism* of —
but its output is prose markdown with emoji-marker conventions (🔥/⚠️/💡/📌), not a
structured schema. Sous's `steps: [{stage, text, duration_sec?, tip?}]` shape is new design,
not a port.

**Scope decision (2026-07-20, explicit user call):** M2c does **not** wire
`plan_days.recipe_id`. Cook mode launches only from the cookbook sheet — tapping a recipe
card, not the Tonight hero card. Linking the ritual/planning flow to cookbook recipes
(`set-plan`/`update-day` gaining a `recipe_id` param, `plan-week.md` looking up matching
recipes) is explicitly deferred; it would re-touch the already-shipped M2b1 backend for a
nice-to-have wiring detail, not a new capability this milestone needs.

**Also explicit (2026-07-20):** recipe intake stays a dedicated job kind
(`recipe_intake`), triggered only by the share extension — unlike alfred, where *any* URL
dropped in chat is caught by the LLM's own judgment in chat mode. Sous's chat mode does
**not** gain automatic URL/recipe detection. If that's ever wanted, it's a new decision,
not an oversight.

## Data shapes

- **`ingredients`**: `[{"name": str, "qty": str}]` — same name/qty pair as
  `shopping_items`, no `section` (that's a shopping-specific grouping concept, meaningless
  on a recipe).
- **`steps`**: `[{"text": str, "duration_sec": int?, "tip": str?}]`. `duration_sec` is
  **required whenever the step is genuinely time-bound** (simmer/rest/marinate/bake/boil),
  optional for pure actions ("season with salt", "wash the greens"). This directly ports
  alfred's 2026-07-13 lesson: leaving duration "optional/judgment-based" caused it to
  silently get dropped by the LLM. The prompt states the requirement explicitly rather than
  leaving it a judgment call.
- **`stage`**: the column stays in the schema (future stage-lanes cook mode, explicitly
  deferred in the original design spec) but the enrichment prompt does **not** populate it
  in v1, and cook mode renders `steps` as a flat ordered list, ignoring the field entirely.
- **`source_block`**: verbatim original ingredients+steps, translated to Chinese if needed
  but never edited — alfred's 📌 原始食譜 concept, now its own column instead of
  markdown-embedded text.
- **`body_md`**: the teaching-card prose (tips/traps/chef notes, alfred's optional
  🔥/⚠️/✅ sections) stays markdown — it's genuinely prose, not data cook mode needs to
  branch on.

## New `state_api.py` verbs

- **`save-recipe --title --slug? --source-block --body-md --ingredients <JSON> --steps <JSON>`**
  — `slug` defaults from `title` (slugify, ASCII kebab-case, matching alfred's
  `slugify()`) when omitted. On `(household_id, slug)` conflict: **upsert in place**
  (`on conflict do update`, the same pattern `set-plan` already uses for `plan_days`) —
  re-sharing a dish updates its existing card rather than erroring, and `recipe_id` stays
  stable so nothing referencing it (future `cook_sessions`/`verdicts`/`plan_days.recipe_id`
  rows) orphans. This is a deliberate divergence from alfred's file-exists-so-no-op dedup —
  Postgres upsert is strictly better here and costs nothing extra to implement.
- **`post-card --content --cards <JSON>?`** — inserts a `chat_messages` row as `chef`,
  optional `cards` JSONB attachment. Named in the original architecture spec's verb list
  (§5), never built until now. Used to announce completion: "🎉 新菜學會了：{title}".
- **`capture-inbox --kind craving --content "想做{title}"`** — already exists (M2a), reused
  as-is for the craving-queue side effect so the next ritual can consider the new dish.
  No new verb needed here.

## M2c1 — recipe pipeline backend

**Job kind `recipe_intake`**, payload `{"url": str, "by": str}`.

1. **Worker-side deterministic pre-fetch** (new module, e.g.
   `worker/sous_worker/gemini_intake.py`, ported from alfred's `recipe_intake.py`
   `cmd_gemini`) runs **before** the brain is invoked at all — not an LLM tool call, exactly
   like alfred's `listener.py` does it. Only for IG/YouTube URLs (matched by the same
   `RECIPE_URL_RE`-style pattern):
   - `yt-dlp -j --skip-download` for caption/metadata.
   - YouTube: URL passed directly to Gemini (`file_data`/`file_uri`) — no download.
   - Instagram: `yt-dlp` download → upload via the Gemini Files API, poll for `ACTIVE`
     (≤45s), then `generate_content`.
   - Model: `gemini-2.5-flash`, fallback `gemini-2.0-flash`. Never raises — any failure
     (missing key, download failure, quota, timeout) degrades to caption-only context, same
     fallback ladder as alfred.
   - Plain web URLs skip this step entirely — no pre-fetch needed.
2. New prompt `worker/prompts/recipe_intake.md` receives the pre-fetched context (or
   nothing, for plain web) and gets a **`WebFetch`** tool in addition to the
   `state_api.py` verb allowlist — the first job kind that needs live web access. Must end
   its turn having called `save-recipe`, `capture-inbox`, and `post-card`.
3. **Credentials**: `GEMINI_API_KEY` reused from alfred's existing key, added fresh to
   `worker/.env` (a credential, not shared state — doesn't touch the alfred/sous state
   isolation rule). New Python deps: `google-genai`, `yt-dlp` (added to
   `worker/pyproject.toml`).
4. **Verification**: direct job insertion against the sandbox household, real IG/YouTube
   URLs, no iOS code involved — same approach that proved M2b1's ritual backend before any
   UI existed.

## M2c2 — iOS surfaces (functional only)

Per the M1/M2a/M2b1/M2b2 pattern: system-default SwiftUI styling, zero visual/branding
craft — the Claude Design token-layer pass (M3) restyles everything app-wide in one pass
later. **This app has no realtime subscriptions** (removed entirely in M2b2 — see that
milestone's notes; don't reintroduce `postgres_changes`/channel code). All of the below
follows the established polling/refresh-on-appear pattern instead.

- **Share extension**: new minimal Share Extension target. Receives a URL, inserts one
  `jobs` row directly (`kind=recipe_intake`, payload `{url, by}`) — same "app writes narrow,
  brain does the rest" pattern as the existing ritual-start button. No local processing, no
  waiting on completion; the extension dismisses immediately after the insert succeeds.
- **Cookbook sheet**: searchable list of `recipes` (title only, no images — no image
  storage exists yet), refreshed via `.task` on sheet appear (same pattern as
  `WeekBoardView`/`ShoppingListView`). Tap → detail view: `body_md` rendered + `source_block`
  + a manual "開始料理" button that opens cook mode for *that* recipe.
  "排進菜單" on the detail view is a **direct app-side `inbox_items` insert** (no job) —
  same precedent as the shopping checkbox: recording intent needs no brain judgment call.
- **Cook mode** (full-screen, the one non-sheet surface, per the original architecture
  spec §6): teleprompter over `steps`, one step per screen, huge type, progress dots.
  Timer button appears only when `duration_sec` is present; continues via local
  notifications when backgrounded. Escape hatch ("出狀況了") opens the existing chat overlay
  with cook context prepended to that chat job's payload
  (`"user is currently cooking {title}, on step {n}: {text}"`) — reuses the same
  poll-after-send pattern (`loadMessages()` every 2s, 180s safety net) `AppModel` already
  has for chat/ritual/swap, no new machinery. `cook_sessions.step_ticks` updates as
  app-owned direct writes as the user advances (already ★ app-owned in the data model) — no
  new verb needed.
- Tonight hero card's "開始料理" stays unwired this milestone (see scope decision above).

## Out of scope (explicitly deferred)

- `plan_days.recipe_id` linkage / Tonight-card cook-mode launch (deferred, see scope
  decision above)
- Automatic recipe-URL detection inside chat mode (deferred, see scope decision above)
- Image/screenshot intake, pasted raw recipe text (deferred — v1 intake is IG/YouTube via
  Gemini + plain web via WebFetch only)
- Stage-lanes / parallel-track cook mode (`stage` field unused; steps render as a flat list)
- Push notifications for "新菜學會了" (APNs pipeline is M3; `post-card` substitutes for now
  — user sees it next time they open chat)
- Recipe thumbnails/images, nutrition data on recipes
- Any visual/branding design work (→ M3 Claude Design pass)

## Testing & exit criteria

**M2c1 (backend):**
- Unit tests: `save-recipe` upsert behavior (insert vs. update-in-place on slug conflict),
  slug derivation from title, `steps`/`ingredients` JSON validation, `post-card` insert
  shape.
- Gated real-pipeline test (`SOUS_SMOKE=1`-style, matching M2b1's precedent): a real IG or
  YouTube recipe URL end-to-end → `recipes` row with populated `steps`/`ingredients`/
  `source_block`, an `inbox_items` craving row, and a `chat_messages` chef card — driven by
  direct job insertion against the sandbox household, no iOS involved.

**M2c2 (iOS):**
- Unit tests: teleprompter step-index/progress logic, timer-eligibility derivation
  (`duration_sec` present or not), cookbook search/filter logic — pure-logic only, matching
  the project's established testing convention (no UI-gesture harness).
- Real-device exit test (mirrors M1/M2a/M2b1/M2b2's real-use pattern): share a real IG/
  YouTube recipe link from the Photos/Safari share sheet → confirm it lands in the cookbook
  with real structured steps → open it, "開始料理" → walk through the teleprompter, trigger
  at least one timer, background the app during a timer and confirm the local notification
  fires → finish → confirm `cook_sessions` recorded. Separately: "排進菜單" from a cookbook
  recipe → confirm an inbox craving row appears.
