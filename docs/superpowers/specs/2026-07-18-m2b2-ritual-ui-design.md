# Sous M2b2 — Ritual UI Design Spec

**Date:** 2026-07-18
**Status:** Approved design, pre-implementation
**Scope:** iOS UI only — Week board sheet, Shopping list sheet, "開始本週儀式" button,
minimal Kitchen Counter navigation. No new backend/worker code; consumes the M2b1
interfaces (`set-plan`, `clear-inbox`, `cancel-ritual`, `swap-days`, `add-shopping-item`,
`plan_weeks.status` routing) as-is.

## Context

M2b1 (backend) shipped and was verified against real cloud data on 2026-07-16: the full
craving-deck → propose → lock ritual works end-to-end, driven by direct job insertion.
M2b2 gives that flow — and the resulting week/shopping data — a real UI, so it can be
triggered and read without hand-crafted SQL.

**Design-effort scope decision (2026-07-17):** this build is **functional-only**, matching
the M1/M2a/M2b1 pattern — system-default SwiftUI styling, no visual/branding craft. The
full "Claude Design pass" (persona-tintable token layer, typography system, color) is
explicitly banked for M3, to be applied consistently app-wide in one pass rather than
piecemeal per screen. Raw UX insights from real Discord/小當家 usage were captured ahead
of that pass in `docs/design/brief.md` — two of those insights turned out to be
*functional* requirements even under a functional-only build (see below), not polish, and
are included in this spec's scope.

## Out of scope (explicitly deferred)

- Any visual/branding design work (→ M3 Claude Design pass)
- Cookbook sheet, full recipe cards, cook mode, mid-cook portion/ingredient adjustment,
  inline chef tips during cooking (→ M2c — also captured as raw notes in
  `docs/design/brief.md`)
- Streaks, 🔥 chip, onboarding (→ M3)
- Any new worker/backend code — this plan only builds against interfaces M2b1 already
  shipped and cloud-verified

## Data model additions (`ios/Sous/Models.swift`)

- `PlanDay` gains `status: String` (not currently modeled; needed to distinguish
  planned/cooked/skipped — the column already exists in Postgres, unused by the app so
  far)
- New `PlanWeek: Codable`:
  ```swift
  struct PlanWeek: Codable, Identifiable {
      let id: UUID
      let weekOf: String       // "YYYY-MM-DD" (Monday), postgres date — keep as string
      let status: String       // "proposing" | "locked"
      let reasoning: String?
  }
  ```
- New `ShoppingItem: Codable, Identifiable`:
  ```swift
  struct ShoppingItem: Codable, Identifiable {
      let id: UUID
      let name: String
      let qty: String?
      let section: String?
      var checked: Bool
  }
  ```
- **Nutrition is explicitly NOT modeled.** `plan_days.nutrition` exists in the schema but
  `state_api.set_plan` never populates it — there's no real data to show. Add it to the
  model only once a backend follow-up writes it; showing an always-null field now would
  be misleading, not just incomplete.

## Navigation (`CounterView.swift`)

Two new chips added to the existing header row (not the full 4-chip row from the original
design spec — 📖 cookbook and 🔥 streak stay out until M2c/M3 build the screens they'd open):

- **`📅 本週`** → opens Week board as a `.sheet` with large/medium detents (~85%,
  swipe up = full, down = dismiss, per the original design spec §6)
- **`🛒 買菜 N`** → opens Shopping list the same way; `N` = live count of unchecked items

## Week board sheet

**Layout:** one scrollable list, two sections:

- **「這週」** — the current week, always fully populated (7 day rows) since it's
  already locked by definition (you're living in it)
- **「下週」** — contents depend on next week's `plan_weeks.status`, computed as a
  3-state derivation (unit-testable pure function):
  1. **No row exists** → show the **"開始本週儀式"** button in place of day rows
  2. **`status == "proposing"`** → show a status line instead of days:
     *"本週儀式進行中 — 到聊天室繼續"* — no button (re-tapping would be harmless since
     `ensure_proposing_week` is idempotent, but a live-looking button that does nothing
     new is confusing)
  3. **`status == "locked"`** → show the full 7 day rows, same rendering as this week

**Day row:** `dish · mode tag · prep_note`, plus a plain-text status marker when
`status != "planned"` (e.g. "已煮" for `cooked`, "skip" for `skipped`) — `update-day`
already supports setting this via chat (M1/M2a), it just hasn't been surfaced in the app
yet. No special visual treatment (strikethrough, color) — that's M3's job; this just
renders the value. Tap toggles an inline expansion (local `@State`, no navigation, no new
screen) revealing `reasoning` too.

**Drag-to-swap** (meaningful only within an already-locked week — dragging within a
proposing/button state does nothing since there are no day rows to drag):
1. Drop day A onto day B
2. Insert a synthetic user-visible chat message: `"（手勢）把 {date A} 和 {date B} 對調"`
3. Insert a matching `chat`-kind job (same `chat_messages` + `jobs` insert pattern
   `AppModel.send()` already uses) — the brain interprets this exactly like a typed
   request and calls `swap-days`
4. Mark both rows with the pending state (see below) until the realtime `plan_days`
   update lands

**"開始本週儀式" button:** tap →
1. Insert a synthetic user message `"（開始本週儀式）"` + a `ritual`-kind job — the exact
   shape verified by hand during the M2b1 cloud exit check
2. Button replaced immediately by the pending state
3. Flips to the "proposing" status line (state 2 above) once the realtime `plan_weeks`
   subscription observes the new row

**Pending/loading state (bare-bones, functional only — 2026-07-17 decision):** a plain
`ProgressView()` + static text (e.g. "chef is thinking…" / "對調中…") — system-default
styling, zero visual craft. This exists because real cloud ritual turns take ~100-150s
each; without *any* indicator the screen looks frozen/broken rather than working. M3
restyles this state later; M2b2 only needs the logic (show/hide based on a pending job) to
exist. This directly addresses the Discord latency pain point captured in
`docs/design/brief.md`.

**Pending-state clearing (no client-side timeout):** pending persists until the
corresponding realtime update (`plan_weeks` or `plan_days` change) actually arrives — there
is no invented timeout/retry logic in the iOS app. If a ritual-bootstrap or edit job fails
permanently, the recovery path is the M2b1 `cancel-ritual` escape hatch (invoked by the
brain when the user types something like "算了" in chat), not a client-side fallback. This
keeps M2b2 from inventing job-tracking machinery the backend doesn't otherwise need;
robustness beyond this is a candidate for revision once real use surfaces a concrete gap
(same pattern M2a's exit test used to catch the flag-staple language mismatch).

## Shopping list sheet

**Scope:** all `shopping_items` for the household, not filtered by week — items get added
to whichever week is current via chat (`add-shopping-item` defaults to the current week)
regardless of which week's ritual generated them, so a week-scoped view would only add
confusion for no benefit.

**Grouping:** by `section`, in a fixed canonical order matching what `skills/plan-week.md`
already instructs the brain to use: **Produce → Meat & seafood → Dairy & fridge → Pantry
→ Breakfast → Other** (fallback bucket for anything uncategorized). `section` is
free-text in Postgres — this ordering lives only in the iOS code as a fixed list, not a
schema constraint.

**Checkbox:** tap toggles `checked` via a **direct Supabase update** (no job, no brain
round-trip — instant, same as the original design spec's "instant at Woolies" intent).
Checked items sink to the bottom *within their section* (not to a separate global
done-pile) with strikethrough, so everything stays findable by aisle. This is the direct
fix for the Discord pain point: *"shopping list is hard to read, and no check marks so we
sometimes forget about stuff."*

**Badge:** `🛒 買菜 N` = live count of unchecked items across all sections.

## Realtime (`AppModel.swift`)

Extend the existing `subscribe()` channel (same `"kitchen"` channel, same
refetch-on-any-change pattern already used for `chat_messages` → `loadMessages()` and
`plan_days` → `loadTonight()`) with two more listeners:

- `plan_weeks` (any change) → refreshes whichever state feeds the Week board (both
  weeks' status + day rows) — this is what live-flips the 下週 section between the three
  states above
- `shopping_items` (any change) → refreshes the shopping list + the chip badge count

Both stay active at the `AppModel` level regardless of which sheet is currently open —
same as the existing pattern — so data is already current the moment a sheet opens, and
updates live while it's open.

## Testing

Following the established project pattern (`SousTests/PresenceTests.swift` — pure-logic
XCTest, no UI/gesture harness) and the project's stated verification philosophy
("milestones have a real-use exit test... verify via real use, not sandboxes"):

**Unit tests** (pure logic only):
- Week-bucketing: does date X fall in "this week" or "next week," given `week_monday`
- The 3-state Week-board derivation (row-absent / proposing / locked → button / status
  line / day-list)
- Shopping section canonical ordering
- Unchecked-item count derivation

**Not unit-tested** (matches project convention — SwiftUI rendering, drag gestures, and
realtime wiring aren't meaningfully testable without a full UI-testing harness the
project doesn't have, and M1/M2a/M2b1 all verified through real use instead):

**Exit test (real device/simulator, mirrors M1/M2a/M2b1's real-use pattern):**
1. Open Week board — see this week fully populated, next week showing the ritual button
2. Tap "開始本週儀式" — button replaced by pending state, then flips to "進行中" status
   line once the row lands
3. Continue the ritual via normal chat (craving deck → pick → 「鎖定!」) — reusing the
   flow already cloud-verified in M2b1
4. Confirm next week's section fills in with 7 real day rows after lock, live, without
   reopening the sheet
5. Drag-swap two days within the now-locked next week — confirm pending state shows,
   then both days update live
6. Open Shopping list — confirm items are grouped by section in canonical order, check
   off a few items, confirm strikethrough + sink-to-bottom-within-section, relaunch the
   app, confirm checked state persisted
