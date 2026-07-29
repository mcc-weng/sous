# Swipe Deck, Ritual, and Judge Grading — Design Spec

**Date:** 2026-07-29
**Status:** Approved design, pre-implementation
**Supersedes:** the guided two-question ritual flow (`worker/prompts/ritual.md`,
`docs/superpowers/specs/2026-07-18-m2b2-ritual-ui-design.md`) as the *interaction model*
for weekly planning. Does not change the underlying job/state_api architecture from
`docs/specs/2026-07-11-sous-app-design.md` — this is additive to it.
**Scope note (corrected 2026-07-29, later same day):** an earlier draft of this doc
stated this was "folded into M3" as decided fact. That overreached — the only thing
actually confirmed was redirecting the *design canvas* (which hadn't drawn ritual/
week-board screens yet, so no throwaway design work either way). Whether M3's
*implementation* also takes on this feature (new schema, new job kinds, two new
SwiftUI surfaces) versus shipping as a restyle-only milestone with this as a fast-follow
is a separate, larger decision that has not been made — see the open coupling question
this raises for the canvas work itself. Either way, the other Claude Code conversation
waiting on the M3 handoff does not know about any of this and needs a manual heads-up
before it proceeds — this session has no access to it.

## 1. Goal

Replace the free-text ritual Q&A with a swipe-based interaction (faster than typing back
and forth, matches the "chef competition show" tone Mike wants — Culinary Class Wars /
MasterChef vibes), and layer a judge/grading persona moment onto the existing verdict
system using data the app already has (ratings, cook telemetry, history) plus a
newly-added photo of the finished dish.

Explicitly not doing yet (parked, see §6): social/multiplayer battles, demographic-based
recipe recommendation, solo "themed challenge" mode.

## 2. Interaction model

**Three gestures, one mechanic, used in two surfaces:**
- **Right** — like / assign
- **Left** — pass
- **Up** — "yes, but": opens a short text field docked to the card ("沒有蝦" / "想要辣一
  點"), tags the card with the note, closes back into the deck. Does not block — see §2.3.

### 2.1 Explore deck (always-on)

Ambient, reachable anytime, zero commitment. Every swipe (including left) is logged —
rejects are as useful a signal as likes. Right/up swipes join a **liked pool** (see §4,
`recipe_swipes`). No day is assigned here. Includes occasional wildcard cards: 小當家
surfaces an untried or creative dish using the same judgment he already applies to
rotation/variety — not a recommendation algorithm (see §6).

### 2.2 Ritual session (scheduled)

Cadence is configurable per household (default weekly; user can set biweekly, etc. — new
`preferences` field). At the scheduled time, 小當家 sends an in-character chat message
(reuses the existing notification → chat pattern) with a CTA button. Tapping it launches
the swipe session full-screen (same tier as Cook Mode — not a sheet). The Week Board's
existing "開始本週儀式" button (already implemented, `WeekBoardView.swift`) becomes a
second, always-available entry point into the same session.

**Day-assignment rule (the load-bearing mechanic, pinned explicitly):** the deck is not a
flat, day-agnostic stack. Each card is generated *for a specific open day* — 小當家 already
decides, via the existing rotation/mode/staple/inbox logic in `ritual.md`, what kind of
dish a given day needs (e.g. Sunday wants batch, a weeknight wants fast); the card
presented is his candidate for that day. **Right** confirms the candidate for that day and
writes through `state_api` (`update-day`), advancing to the next open day's candidate.
**Left** rejects the candidate; 小當家 offers a different candidate for the *same* day, not
the next day. **Up** modifies the current day's candidate (see §2.3) before deciding. The
liked pool (§2.1) is consulted first: if a pool item fits what a given day needs, it's
offered as that day's first candidate — this is what makes a well-stocked pool produce a
short session of fast confirms; an empty pool just means every candidate is fresh
curation. Progress is visible as "N of 5 days filled." Either way the session always ends
the same way: 鎖定! writes `plan_days` + `shopping_items`, identical to today's lock
behavior.

This *replaces* the guided Q&A as the ritual's interaction model. The underlying
reconciliation logic (rotation, staples, inbox, allergies-are-absolute) is preserved —
only the interaction changes, from conversational Q&A to a curated deck.

### 2.3 Modification loop (swipe-up)

A swipe-up note must never block the deck — waiting on a live brain response mid-swipe
defeats the point of swiping being faster than chat. Instead: the note fires a background
job (same job/worker/realtime pattern chat already uses), the deck continues immediately,
and when the brain responds with an adjusted or alternative card, it's reinserted into
the deck a few cards later (tagged, e.g. "🔥 updated"). The user swipes on it like any
other card — right accepts, left passes, up chains another modification.

## 3. Judge / grading layer

No new rating scale. The existing 4-tier `verdicts` rating (神作/不錯/普通/翻車) stays as
the only score — a second competing scale would just be confusing.

**What's new:**
- **Photo capture** at the 上菜 celebration moment (already a Cook Mode redesign target in
  the design brief) is explicitly wired into judging, not just cookbook history: it's
  optional/skippable, and when present it's a real vision input to the commentary job
  below — genuine plating/presentation critique, not invented. **Timing matters**: this
  happens at cook-session completion, but the rating doesn't exist until the post-dinner
  push ~1h later (per `docs/specs/2026-07-11-sous-app-design.md` §6) — so the photo is
  captured onto `cook_sessions`, not `verdicts` (which doesn't have a row yet at that
  point). See §4.
- **Chef commentary job**: a new brain job kind, fires **when the verdict is submitted**
  (not at cook-session completion — the rating is the last piece it needs), takes as
  input — the rating just submitted, the corresponding `cook_sessions` row's telemetry
  (time per step vs. expected, timer usage, whether the user escaped to chat mid-cook,
  first attempt vs. repeat) and photo if present, and history for that `recipe_id` (past
  verdicts, cook count). Output is a short, dramatic, in-character commentary string
  written onto the `verdicts` row.
- **Self-comparison ("battle") framing**: the drama comes from comparing this attempt
  against the user's own past attempts of the same dish ("第三次做,比上次快了十分鐘") —
  no opponent needed, no new infrastructure. This is the show-vibe payoff without
  requiring social features.

## 4. Data model changes

New/changed tables (additive to `docs/specs/2026-07-11-sous-app-design.md` §4):

- **`recipe_swipes`** — `household_id`, `recipe_id`, `action` (like/pass/modify),
  `context` (explore/ritual), `note?`, `created_at`. Ritual-context like/modify swipes
  additionally trigger the existing `update-day` state_api call; explore-context swipes
  only ever write here. Kept separate from `inbox_items` (free-text craving notes) since
  swipes are structured and need dedup/decay logic `inbox_items` doesn't.
- **`preferences`** gains a ritual-cadence field (interval + anchor day).
- **`cook_sessions`** gains `photo_url?`, captured at the 上菜 moment (cook-session
  completion) — before a `verdicts` row exists. Needs a reliable way to correlate to the
  eventual `verdicts` row (likely `plan_day_id`, if `cook_sessions` doesn't already carry
  one — **verify against the actual schema during implementation**, not assumed here).
- **`verdicts`** gains `chef_commentary?`, populated by the new job at submission time.
- **New job kinds**: `recipe_tweak` (swipe-up modification → alternative card, fires
  immediately on swipe-up), `judge_commentary` (fires on verdict submission, joins the
  correlated `cook_sessions` row for telemetry/photo, optionally vision-enabled).

## 5. Navigation / IA

Kitchen Counter remains the single root (no change to the locked navigation decision).
Chat remains the persistent write path and is now also the ritual's announcement surface
(chat message + CTA button, not an in-chat swipe UI). Both swipe surfaces (Explore,
Ritual session) are full-screen, joining Cook Mode as the app's non-sheet surfaces — they
need the same uninterrupted focus. Explore gets a persistent, prominent entry point on
the Kitchen Counter home screen (a peek card showing the top of the deck) rather than
being buried behind a chip like Cookbook/Shopping — exact layout is a Claude Design
question, not decided here. Chat remains available as an escape hatch during a swipe
session via the existing avatar-summon pattern used elsewhere.

## 6. Explicitly deferred (not designed, not built)

| Item | Why deferred |
|---|---|
| Multiplayer/social battles (comparing against other households' dishes) | Needs another household in the loop — a social phase, not a UI decision. Self-comparison (§3) gets most of the "battle" feeling now without it. |
| Demographic-based recipe recommendation (ethnicity/location/age inference) | Solves a cold-start problem this household-scale app doesn't have; the household already has rich explicit signal (verdicts, swipes, cook history). Also conflicts with the standing "no vector DB/RAG, deterministic assembly" decision. Parked in someday.md. |
| Solo "themed challenge" mode | Real idea, not needed for this pass — self-comparison narrative already covers the show-vibe goal. |

## 7. Open items (flag, don't silently decide)

- Where in the UI the ritual cadence gets configured (Notification Settings screen is the
  obvious candidate — it already exists in the screen inventory).
- Decay/staleness rule for liked-pool items that never get picked across many rituals.
- Exact home-screen layout budget for the Explore peek card alongside the existing hero
  card / chip row — left to the Claude Design pass.
