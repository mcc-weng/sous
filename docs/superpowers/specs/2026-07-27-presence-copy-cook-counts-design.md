# M3 — Presence Copy Sweep + Per-Dish Cook Counts Design

**Status:** Approved, ready for planning.

## Context

Per the original design spec (`docs/specs/2026-07-11-sous-app-design.md` §6/§8), M3's
remaining scope after Onboarding includes "presence states" and "streaks (derived)".

**Presence** already works functionally — `CounterView.swift`'s header shows a binary
"chef in"/"chef out" label driven by `chefIsPresent(workerSeenAt:)` (`Models.swift`),
backed by a 30s poll of `households.worker_seen_at` (`AppModel.swift`), and is unit
tested (`PresenceTests.swift`). The gap is that the label text is hardcoded English,
never routed through `copy_pack` — in letter conflict with the persona-discipline rule
(CLAUDE.md: "zero hardcoded persona strings in app or prompts"), same class of gap
already tracked and swept for onboarding (`0013_onboarding_copy_pack.sql`).

**Streaks**, as specced ("chip row: 🔥 streak", "Finish → 上菜 celebration... streak +1"),
implied a daily-cooking-habit counter. During brainstorming, Mike redirected this: a
daily streak isn't the useful signal for this household's cooking cadence — a **per-dish
repeat-cook count** ("cooked this 5 times") is. This design implements that instead of
the spec's literal daily-streak chip; the spec's home-screen `🔥` chip is dropped
entirely as a result (see Scope decisions).

Both pieces are small and share a common thread (persona-voice + `cook_sessions`-derived
display data), so they're specced and planned together.

## Scope decisions made during brainstorming

- **Presence: copy_pack sweep only, no new states.** The binary present/away logic is
  correct and already tested; only the copy source changes. Richer presence states
  (e.g. distinguishing "actively cooking for you" from generic "away") were considered
  and explicitly deferred — no evidence yet that binary is insufficient.
- **Streak redefined as per-dish cook count, not a daily habit chip.** Derived from
  `cook_sessions` (`recipe_id`, `completed_at`) exactly as the spec's "streaks/history:
  derived, no new machinery" note intended — just counting a different dimension
  (repeats per dish) than the spec originally described (consecutive days).
- **No home-screen chip for this.** The spec's `🔥 streak` chip assumed a single
  household-wide daily number worth a permanent home-row slot. A per-dish count doesn't
  have one obvious household-wide value to show there, so nothing is added to
  `CounterView.swift`'s chip row. The count is contextual — shown wherever a specific
  dish is already in view.
- **Milestone reactions only at the cook-mode completion moment, not everywhere the
  count appears.** Recipe detail and cookbook grid show the count as plain, factual UI
  text (matching how verdict ratings/dates are already displayed — no persona voice
  attached to data readouts). The completion screen is the one moment celebration makes
  sense: normal counts show a plain line, milestone counts (3rd, 5th, 10th, then every
  10th) show a persona reaction line instead, driven by one generic `copy_pack` template
  with an `{n}` placeholder — the first placeholder-style `copy_pack` key in this
  codebase (existing keys are all static strings), kept to a single `{n}` substitution
  to avoid building general templating machinery for one use.
- **Client-side derivation over a view/RPC or a cached column.** Household-scale data is
  tiny (per the original spec's risk table), and `RecipeDetailView.swift` already
  fetches-and-derives verdict history the same way. A Postgres view/RPC would be
  over-engineering for this data volume; a cached `cook_count` column on `recipes` would
  need a write path and could drift from `cook_sessions` on session edits/deletes —
  both rejected in favor of reusing the established fetch-and-derive pattern.

## What's landing

**Migration `0015_presence_cook_count_copy.sql`** — merges into `personas.copy_pack`
(same `copy_pack || jsonb_build_object(...)` merge style as `0013`, preserving existing
keys):
- `presence_in` / `presence_out` — replace `CounterView.swift`'s hardcoded "chef in"/
  "chef out" strings, e.g. 在廚房 / 外出中 framing per the original spec's screen
  inventory (「小當家 🔥・在廚房/外出中」).
- `cook_milestone_reaction` — one template with an `{n}` placeholder, e.g. 「哇,這是你
  第 {n} 次做這道菜了!越來越上手了呢 🔥」, reused for every milestone count.

**`CookHistoryLogic.swift`** (new, mirrors `CookbookLogic.swift`/`OnboardingLogic.swift`
as a pure-logic file with no view/network code):
- `cookCount(sessions: [CookSession], recipeId: UUID) -> Int` — counts sessions matching
  `recipeId` with non-nil `completedAt`.
- `isMilestone(_ count: Int) -> Bool` — `count == 3 || count == 5 || (count >= 10 &&
  count % 10 == 0)`.

**`AppModel.swift`** — new `@Published var cookSessions: [CookSession] = []`, fetched
inside the existing `loadCookbook()` call (household-scoped, alongside the existing
recipes fetch) — reuses the load lifecycle already triggered by `CounterView`'s `.task`.
`CookSession` (`Models.swift`) already exists from M2c2; no model changes needed.

**`CounterView.swift`** — header label lookups become `model.personaCopy["presence_in"]
?? "chef in"` / `["presence_out"] ?? "chef out"`, matching the existing
`model.personaCopy[key] ?? fallback` pattern (`OnboardingView.swift:17`). No chip row
change.

**`RecipeDetailView.swift`** — a plain line near the existing verdict history, e.g.
「已煮 5 次」, computed via `cookCount(sessions: model.cookSessions, recipeId: recipe.id)`.

**`CookbookView.swift`** — the same plain count shown as a small badge on each grid card.

**`CookModeView.swift`** — `finishCooking()` re-runs `model.loadCookbook()` after
updating `completed_at` so `model.cookSessions` reflects the just-finished session, then
`doneView` computes the count for `recipe.id`:
- Non-milestone: plain 「已煮 N 次」 line (same style as recipe detail/cookbook).
- Milestone: the `cook_milestone_reaction` copy_pack template with `{n}` substituted,
  shown instead of the plain line.

## Error handling

Matches the existing best-effort, non-blocking precedent already documented on
`startSession()` ("a failed insert doesn't block cooking"). If the post-finish
`loadCookbook()` refresh fails, the completion screen simply omits the count/milestone
line — it never blocks the "關閉" button. Recipe detail and cookbook counts default to 0
before `cookSessions` has loaded, same as `model.recipes` already behaves while loading.

## Testing

Unit tests for `CookHistoryLogic`:
- `cookCount`: matches only the given `recipeId`; excludes sessions with nil
  `completedAt`; returns 0 for no matches or an empty array.
- `isMilestone`: true at 3, 5, 10, 20, 30; false at 1, 2, 4, 6, 9, 11, 19, 21, 25.

No changes needed to `PresenceTests.swift` — the present/away logic itself is unchanged,
only its copy source.

## Out of scope

- Any daily-streak/habit-tracking mechanic (explicitly rejected in favor of per-dish
  counts).
- Richer presence states beyond binary present/away.
- General `copy_pack` placeholder/templating support beyond the single `{n}` case needed
  here.
