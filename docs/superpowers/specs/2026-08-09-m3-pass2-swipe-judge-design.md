# Pass 2 — Swipe Ritual, Explore Deck, and Judge Grading — Design Spec

**Date:** 2026-08-09
**Status:** Approved design, pre-implementation
**Builds on:**
`docs/superpowers/specs/2026-07-29-swipe-ritual-judge-design.md` (interaction mechanics —
day-assignment rule, modification loop, explore-deck semantics — all still correct, not
restated here) and `design_handoff_sous_m3/README.md` (exact visual specs for
B1/D3/C4/A2/A3/D1/E3 — this doc does not restate token/layout values; read those sections
directly during implementation).
**Corrects:** §3 of the 2026-07-29 spec. That spec had the user submit the rating, with
小當家 adding commentary afterward. The design handoff's "Spec deltas" section (written in
a separate, unlinked Claude Design conversation) instead has 小當家 assign the rating, user
reacts 我同意/我不服. These are incompatible — different job trigger, different UI. §3
below resolves it with a third model that both specs pointed toward but neither stated
exactly, confirmed with Mike 2026-08-09.
**Staging:** one spec, two implementation passes — **Pass 2a** (swipe foundation) and
**Pass 2b** (judge layer + chat-schema odds and ends) — each gets its own
plan/worktree/whole-branch-review/merge, same pattern as M3 Pass 1's one spec
(`2026-08-02-m3-visual-restyle-design.md`) staged into 1a/1b/1c. Rationale and exact split
in §7.

## 0. Why (tone anchor — inherited from Pass 1)

Same anchor as Pass 1 (§0 of `2026-08-02-m3-visual-restyle-design.md`): Sous is a personal
chef in your pocket, Michelin-cookbook restraint over folksy warmth, and that's the
tie-breaker for any ambiguous call below. Nothing about the swipe/judge feature changes
this — 小當家 judging a plate should read like a serious critic, not a game-show host.

## 1. Scope

- **Explore Deck (D3)** — ambient, always-on swipe browsing. Every swipe logged to
  `recipe_swipes`; never touches the plan.
- **Ritual Swipe Session (B1)** — replaces the guided Q&A as the weekly-planning
  interaction model. Day-by-day card dealing, ends in 鎖定.
- **Swipe-up modification loop (但是…)** — shared by both surfaces. Non-blocking: fires a
  background job, deck keeps moving, revised card re-enters a few cards later tagged
  已更新.
- **Judge layer** — 小當家 judges first (blind reveal, from photo + telemetry + history),
  then the user rates for real. See §3.
- **已修改 chat indicator (A3)** — a link row on any 小當家 slip whose reply actually
  changed plan/shopping state.
- **邊欄 recipe-page Q&A (D1), minimal version** — asking "關於這一頁" from Recipe Detail
  tags the exchange to that recipe; the page shows the single most recent exchange, not an
  accumulating thread (see §5 rationale).
- **Ritual cadence setting (E3)** — interval + anchor day, configurable in Settings.

**Not in scope** (unchanged from the 2026-07-29 spec §6): multiplayer/social battles,
demographic-based recommendation, themed-challenge mode.

## 2. Interaction mechanics — unchanged, reference only

The three-gesture mechanic (right = like/assign, left = pass, up = 但是…), the Explore
Deck's always-on semantics, the Ritual Session's day-assignment rule (candidate per open
day, liked pool consulted first, "N of 5 days filled"), and the swipe-up modification
loop's non-blocking job/reinsertion pattern are all specified in full in
`2026-07-29-swipe-ritual-judge-design.md` §2. Nothing here changes any of it — this doc
adds the visual grounding (handoff §B1/§D3) and the data model (§4) that spec left
implementation-level.

## 3. Judge / grading — the reconciled model

**Two voices, not a competing scale.** 小當家's judgment is performative — for fun,
independent of the user, working only from what he can actually observe. The user's
rating stays the ground truth, since only they tasted the dish — it remains the record
used for cookbook history and self-comparison ("第三次做,比上次快十分鐘").

**Flow, in order:**

1. Cook session completes (上菜, already built in Pass 1c) — `cook_sessions` has
   `photo_url`, `step_ticks`.
2. `judge_commentary` job fires once the cook session is complete — photo is an input
   when present but never a precondition (see §6 for the exact trigger). Inputs: the
   photo if present, cook telemetry (elapsed time vs. expected, timer usage, steps
   revisited, whether the user escaped to chat mid-cook), and history for that
   `recipe_id` (past `verdicts`, cook count). Output: `verdicts.chef_rating` (same
   four-tier scale) + `verdicts.chef_commentary`
   (dramatic, in-character, and — per Mike's framing — should include something
   actionable/technique-observational where the telemetry supports it, e.g. timing or
   pacing notes, not pure flavor text. This doubles as the "helps you improve" goal;
   no separate mechanism needed for that).
3. **Blind reveal** (already designed in handoff §C4): 小當家's tier is shown blurred, then
   revealed with his commentary — the "AI judges the dish" spectacle.
4. **User then submits their own rating + note** — the existing, already-built verdict
   flow (`rating`/`note`), simply moved to *after* the reveal instead of before it. No new
   UI concept — same picker, same fields, later in the sequence.
5. No blocking on step 4 — a user can, in principle, dismiss without rating (existing
   behavior for `planDayId == nil` sessions is unchanged: 講評 always shows, persistence
   still no-ops without a `planDayId`).

**What this drops from the handoff's original "Spec deltas":** no 我同意/我不服 reaction
buttons, no re-tasting job. The user's own rating *is* the disagreement mechanism — if
小當家 says 普通 and the user picks 神作, that divergence is visible by just showing both
values together (e.g. on D2's cookbook history rows or C4's own page), without needing a
dedicated dispute flow. Simpler than either prior spec, and avoids inventing UI for a
"did the AI get it right" mechanic nobody asked for directly.

## 4. Data model changes

New table:
- **`recipe_swipes`** — `id`, `household_id`, `recipe_id` (**nullable** — correction
  found during Pass 2a plan-writing: verified against `state_api.py`/`plan-week.md`
  that today's guided ritual proposes most dishes as free text via `set-plan`, never
  calling `save-recipe` — only the recipe_intake pipeline populates `recipes`. Explore
  Deck swipes always carry a real `recipe_id` since that surface only ever browses the
  cookbook; Ritual Session swipes carry one only when the candidate happens to be a
  cookbook recipe), `dish_text` (nullable — the free-text dish name when `recipe_id` is
  null), `action` (check: like/pass/modify), `context` (check: explore/ritual), `note`
  (nullable), `created_at`.
- **Ritual deck delivery** — also found during plan-writing: a live brain turn takes
  100–150s (per the existing B2 waiting-state design), so the swipe session cannot wait
  on one per card or per rejection — that would be slower than the chat it's replacing,
  not faster. The `ritual` job, in swipe mode, generates multiple candidates per day for
  the full week in one brain turn and writes them as structured JSON into `jobs.result`
  (existing column, previously unused by any handler) rather than requiring the client to
  parse a chat message. The client fetches the job row it created once `status = 'done'`
  and hydrates the local deck from `result`; ordinary left-swipe rejections pop the next
  pre-generated candidate for that day with no new brain call. Only swipe-up (但是…)
  triggers a fresh `recipe_tweak` job — same delivery mechanism (client polls that job's
  row, reads `result` on completion), consistent with the app's existing polling-not-
  realtime pattern (`AppModel.waitForReply`'s doc comment: realtime `postgres_changes`
  was confirmed non-functional in this project during a 2026-07-19 exit check).

Altered tables:
- **`households`** gains `ritual_cadence_interval` (text, default `'weekly'`) and
  `ritual_cadence_anchor_day` (text or smallint weekday) — **correction to the
  2026-07-29 spec**, which assumed this belonged on `preferences`. Checked the actual
  schema: `preferences.content` is a single free-text blob the brain reads/writes
  (household preferences prose), not structured settings — wrong place for a value the
  worker's scheduler needs to query reliably. `households` already holds structured
  settings of exactly this kind (`timezone`, `worker_seen_at`), so the cadence fields go
  there instead.
- **`cook_sessions`** gains `plan_day_id` (nullable uuid, references `plan_days`) —
  closes a real gap: today `cook_sessions` has no way to join to its eventual `verdicts`
  row (verified against `0001_schema.sql` — `cook_sessions` has no `plan_day_id`,
  `verdicts` has one but nothing populates the other side of the join). Populated at
  session-start in `CookModeView.startSession()`, using the same `planDay?.id` value
  `submitVerdict()` already receives — one extra field on an existing insert, not new
  plumbing.
- **`verdicts`** gains `chef_rating` (nullable text, same tier values) and
  `chef_commentary` (nullable text). Existing `rating`/`note` are unchanged in meaning —
  still the user's own submission.
- **`chat_messages`** gains:
  - `recipe_id` (nullable uuid, references `recipes`) — set when a chat exchange
    originates from Recipe Detail's "問小當家關於這一頁" field, for 邊欄.
  - `changed_summary` (nullable text) — set by the worker whenever handling a reply
    actually invokes a `state_api` write verb (not an LLM self-report of "did I change
    something" — tied to a real write, so it can't drift or hallucinate).
  - `changed_target` (nullable text, e.g. `'week'` / `'shopping'`) — which screen the
    已修改 row's seal `→` navigates to, set alongside `changed_summary` from the same
    verb-dispatch point. Avoids parsing `changed_summary`'s free text on the client to
    figure out where to navigate.

New job kinds (values in `jobs.kind`, no schema change — `kind` is already free text):
- **`recipe_tweak`** — fires on swipe-up, produces a revised/alternative card.
- **`judge_commentary`** — fires on cook-session completion once photo+telemetry exist
  (see §3).

## 5. Screen → handoff mapping

Read these sections of `design_handoff_sous_m3/README.md` directly during implementation
— exact token/layout values live there, not reproduced here:

| Screen | Handoff section | Notes |
|---|---|---|
| Explore Deck | D3 (探索牌組) | Shares the swipe-card component with B1; distinguished by what's absent (no day chip/progress/lock). |
| Ritual Swipe Session | B1 (滑牌儀式) | Day-assignment, progress rule, lock card. |
| Kitchen Counter entry point | A2 (廚房), "想吃什麼" section | Peek card already fully specified — no new layout decision needed. |
| 已修改 indicator | A3 (便條), the link-row paragraph | Already part of the core chat design, just unbuilt pending schema. |
| 邊欄 exchange | D1 (食譜), "the 邊欄 exchange" paragraph | Single most-recent exchange only — see §1 scope note; the handoff's own language ("a slip: 你問... his answer") is singular, not a thread. |
| Blind reveal / judge commentary | C4 (講評) | Already restyled in Pass 1c; this pass wires the reveal to real `chef_rating`/`chef_commentary` instead of a placeholder, and reorders the user's rating to come after. |
| Ritual cadence setting | E3 (設定), 儀式節奏 section | Chips (每週/每兩週/不固定) + anchor day + explanation. |

## 6. Correlation & job-trigger summary

For implementation clarity, since this pass adds two new job triggers with real
dependencies:

- `judge_commentary` fires when `cook_sessions.completed_at` is set **and**
  `cook_sessions.photo_url` is present-or-skipped (the photo is optional; the job runs
  either way once the cook session is marked complete, per the existing 上菜 skip
  affordance). It reads `cook_sessions` via the new `plan_day_id` correlation, not by
  timing/guessing.
- `recipe_tweak` fires immediately on a swipe-up submission (前 §2, unchanged from
  2026-07-29 spec) — synchronous trigger, no new correlation needed since the triggering
  swipe and the resulting card are directly linked by the job's own payload.

## 7. Staging: Pass 2a / Pass 2b

Split along the real technical seam — shared UI components vs. independent backend
plumbing — not an arbitrary halving:

**Pass 2a — swipe foundation:**
- `recipe_swipes` table
- Shared swipe-card SwiftUI component (drag gesture, stamps, release/spring mechanics)
- Explore Deck (D3)
- Ritual Swipe Session (B1) — day-assignment, progress, lock
- Swipe-up modification loop (`recipe_tweak` job + reinsertion)
- Ritual cadence setting (`households` columns + E3 Settings UI)
- `ritual.md` rewrite: emit structured card payloads (dish/photo/meta/pitch) per open day,
  reusing existing rotation/mode/staple/inbox decisioning — not new judgment logic, just a
  new output shape.

**Pass 2b — judge layer + chat schema:**
- `verdicts.chef_rating`/`chef_commentary`, `cook_sessions.plan_day_id`
- `judge_commentary` job (vision-enabled)
- Blind-reveal wiring + reordered user-rating flow (§3)
- `chat_messages.recipe_id`/`changed_summary`/`changed_target`
- 已修改 indicator (A3)
- 邊欄 minimal exchange (D1)

2b has zero UI-component overlap with 2a; 2a's two screens share nearly everything.
Building them in this order also means 2b's judge layer ships against a codebase that
already has the swipe interaction pattern proven out, though 2b has no hard dependency on
2a's code beyond that.

## 8. Explicitly deferred (unchanged from 2026-07-29 spec §6)

| Item | Why deferred |
|---|---|
| Multiplayer/social battles | Needs another household in the loop. |
| Demographic-based recommendation | Solves a cold-start problem this app doesn't have; conflicts with the no-vector-DB/RAG decision. |
| Solo "themed challenge" mode | Self-comparison narrative already covers the show-vibe goal. |
| 邊欄 full accumulating thread | Bigger IA commitment than what was actually asked for (§1, §5) — minimal version ships now, thread version is a real future option if wanted. |

## 9. Left to planning (not design-level decisions)

- 收藏 (liked-pool) decay rule — handoff flags `快過期` styling for month-unused items but
  the threshold/exact rule isn't pinned; a reasonable default can be picked during 2a
  planning without another design round.
- Wildcard/冷門推薦 card frequency in the Explore Deck and Ritual Session pools.
- Exact `households.ritual_cadence_anchor_day` representation (weekday text vs. smallint)
  — an implementation detail, not a product decision.
