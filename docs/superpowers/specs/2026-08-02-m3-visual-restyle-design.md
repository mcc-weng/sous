# M3 Visual Restyle — 書與灶 Design System (Pass 1 of 2)

**Date:** 2026-08-02
**Status:** Approved (2026-08-02) — including the two inferred boundaries in §4
(grading flip and 邊欄 rearchitecture deferred to Pass 2), confirmed by Mike
**Source:** Claude Design handoff, `design_handoff_sous_m3/README.md` — the primary
reference for exact token values, per-screen layout, motion, and accessibility rules.
**This doc does not restate those values.** It records the corrections and
implementation-specific decisions layered on top, and draws the scope line between this
pass and Pass 2.

## 0. Why (tone anchor for judgment calls)

Sous is a personal chef in your pocket. The visual vibe is **high-end fine dining — a
Michelin-star restaurant's own cookbook**, not a folksy home recipe box. When an
implementation detail isn't pinned down by the handoff's exact values, default toward
restraint and precision over warmth/rustic — the handoff's own rules already point this
way (one seal-red per page, no border radius, hairline rules, square everything) and
this is the tie-breaker when two readings are both defensible.

## 1. Staging: this is Pass 1 of 2

The Claude Design handoff bundles two different things: a visual restyle of the app's
existing 10 screens (what was originally briefed), and a new feature — swipe ritual,
explore deck, and brain-assigned grading (`docs/superpowers/specs/2026-07-29-swipe-ritual-judge-design.md`).
Decided 2026-08-02: **ship them as two separate passes**, each with its own
spec/plan/worktree/review, same pattern as M2's a/b/c split. This doc is Pass 1 only.

## 2. In scope for Pass 1

- The full 書與灶 (paper/stage) design system — tokens, typography, spacing, motion,
  accessibility — applied to all 10 existing screens per the handoff README's screen
  sections (A1–A2, B2–B3, C1–C4, D1–D2, E1–E3, plus states in §G).
- **Recipe Detail (D1)** redesign: photo carousel, servings stepper with live
  ingredient rescale, unit/print/copy icon row, ingredient list, numbered steps with
  inline tips, notes, 邊欄 rendering *of existing chat history relevant to that recipe if
  trivial* — see §4 for what's excluded here.
- **Cook Mode (C1–C4)** redesign: prep checklist, per-step timer (ring + concurrent
  background timers), the new 上菜 photo-of-dish capture step (skippable), and the
  existing verdict screen restyled — **rating stays a user selection in Pass 1** (see §4).
- **Written ritual (B2)**: restyled to the new visual system, chip-based quick replies
  added at existing fixed-choice moments (the CTA-button entry point into a *swipe*
  session is Pass 2 — see §4).
- Presence: **kept, not deleted** — see §3 correction.
- copy_pack sweep folded in: every hardcoded string in a touched screen moves to
  `copy_pack`, including the new keys the handoff's section H defines (exact key list
  and 小當家 values to be extracted from `Sous App v2.dc.html` section H during
  implementation — not reproduced here to avoid transcription drift from the source).
- Onboarding, Notification Settings, Auth, Week Board, Shopping List, Cookbook: restyled
  to the new tokens, no interaction changes.
- Font bundling: Noto Serif TC + Noto Sans TC (Google Fonts, SIL OFL) as in-app bundled
  fonts — these are not iOS system faces and must ship in the app bundle.

## 3. Correction to the handoff: presence is kept

Decided 2026-08-02 (overrides the handoff's §"Spec deltas" item 6 and the A2/E3 sections
that assume its removal): **presence is not deleted.** `households.worker_seen_at`
reflects whether the *worker/brain process* is actually running — a different, more
important signal than device connectivity, and the named mitigation in the original spec
for "chat latency when the laptop's asleep" (validated by M1's exit test: presence flip +
queue-while-worker-down + recovery). The handoff's aesthetic argument ("a book's author
has no presence indicator") is a real tension worth respecting *stylistically* — implement
as:

- Reuse the handoff's 離線 (offline) treatment — hollow seal, `inkFaint` glyph — for
  **both** device-offline and worker-offline, rather than introducing a second visual
  language for presence. Copy differs (`小當家目前無法回覆` for worker-down vs. whatever
  device-offline already says), but the visual grammar is shared, which keeps the
  "book's author" restraint the handoff was going for.
- The old pill/dot presence indicator (在廚房/外出中 chip) goes away as a *component* —
  that part of the handoff's instinct was right, it didn't fit the paper language. What's
  kept is the underlying signal and a treatment consistent with the hollow-seal idiom,
  not the old chip verbatim.
- Exact placement/copy is an implementation decision for the Kitchen Counter (A2)
  running head, where presence used to live — flag during planning if the hollow-seal
  treatment doesn't read cleanly there.

## 3b. Correction to the original product spec: paper-first, not dark-mode-first

Confirmed 2026-08-02: the original product spec's "dark-mode-first" constraint is
**superseded** by the approved 書與灶 design. Per the handoff README: "System Dark Mode
does not invert the book. Paper stays paper... Inverting a printed page destroys the
premise." Nearly every screen (Auth, Kitchen Counter, Chat, ritual, Shopping, Week Board,
Cookbook, Recipe Detail, Onboarding, Settings) uses the warm paper palette
(`paper.stock` `#EDEAE2` and friends) regardless of system appearance. Only three screens
are ever dark: Cook Mode's step teleprompter, the timer state, and 上菜 (the `stage.*`
tokens) — deliberately, because "if your hands are busy and something is counting, dark;
everything else is paper." This is an intentional trade-off accepted for this pass, not
an oversight — flagging it here so it isn't silently lost the way presence almost was.

## 4. Explicitly NOT in Pass 1 (deferred to Pass 2)

- **Explore Deck (D3) and Ritual Swipe Session (B1)** — new full-screen surfaces, not
  built in Pass 1. The Week Board's `滑牌排` entry point and the Chat CTA into a swipe
  session are not wired up yet.
- **`recipe_swipes` table, `recipe_tweak` / `judge_commentary` job kinds** — no schema or
  worker changes for these in Pass 1.
- **Grading flip** — `verdicts.rating` **stays a user-submitted field in Pass 1.** The
  handoff's judge/commentary system (brain writes the rating, user reacts 我同意/我不服)
  ships together with Pass 2's other judge-layer pieces, since the commentary job needs
  cook-session telemetry plumbing that doesn't exist yet and building the reaction UI
  twice (once for a user-rating world, again for a brain-rating world) would be wasted
  work. **This is an inferred boundary, not something Mike confirmed explicitly** — he
  confirmed brain-assigned grading is the right *eventual* direction, not that it ships
  in this pass. Flagging for the review gate below.
- **邊欄 (margin-note) chat rearchitecture** — today's Chat/便條 gets the paper visual
  treatment in Pass 1, but "an answer gets written permanently into the recipe's own
  page" is new information architecture (needs a way to associate a chat exchange with a
  specific recipe), not a restyle. Deferred to Pass 2 alongside the rest of the
  interaction changes. **Also an inferred boundary — flagging for review.**
- **Ritual cadence setting** — tied to swipe-ritual scheduling, deferred with it.

## 5. Data model changes for Pass 1

- `cook_sessions.photo_url` (nullable text or storage path) — captured at the 上菜 step,
  new Supabase Storage bucket for dish photos. Consumed by judge commentary in Pass 2,
  but captured and stored starting in Pass 1 since the Cook Mode redesign is in scope now.
- Recipe step timer duration — steps need a duration value for the timer ring to have
  something to count down from. Existing `recipes.steps` JSONB needs a duration field;
  recipes without one just render without a timer for that step. Both write paths
  (`save-recipe` verb, `recipe_intake` pipeline) need to populate it going forward;
  backfilling existing seeded/intake'd recipes is a nice-to-have, not a blocker.
- No changes to `verdicts` in Pass 1 (see §4).

## 6. Implementation constraints

- **Canvas width vs. real device**: the handoff is authored at 402pt (iPhone 15/16 Pro).
  Mike's real test device is a 13 mini (375pt). Treat "pixel-accurate" as the *intent* for
  spacing/type/color, not a literal port — verify every screen actually fits and reads at
  375pt during implementation, not just at build time.
- **Persona-tintability**: the handoff bakes in one specific identity (seal red
  `#9B2C1E`, the serif voice, 小當家-specific copy) without mentioning the tint seam.
  Resolution: same discipline as before — route the seal/accent color through the same
  kind of token seam already established (`personas` data, not hardcoded literals in 20
  view files) — just with 書與灶's values instead of the earlier "Ember" ones. This
  doesn't require designing a second persona's visual language now, only avoiding
  hardcoding the one value that exists today.
- Fonts ship via the Xcode project (`ios/project.yml` resource + `Info.plist`
  `UIAppFonts`), not downloaded at runtime.

## 7. Screen → file mapping

Reuse the handoff README's "Repo mapping" table verbatim — it's already correct for
Pass 1's scope (the swipe/explore rows point at the Pass 2 spec, not new Pass-1 files).

## 8. Verification / exit criteria

Same bar as every prior milestone: unit tests green, a real whole-branch review, and a
real-device exit check on Mike's iPhone 13 mini specifically (not just simulator) given
the 402pt→375pt adaptation risk in §6.

## 8b. Backlog items surfaced during Pass 1a implementation — both resolved 2026-08-04

Two real gaps found by task reviews during implementation. Both now have a decision from
Mike, recorded here rather than left open:

- **"已修改 →" changed-indicator row** (from 便條's slip design, README A3): when a chat
  reply actually changed plan/shopping state, the design shows a small link row on that
  slip. `ChatMessage` (`Models.swift`) has no field recording *that* a reply changed
  something or *what* — this needs new schema (the worker would have to report it) and
  is backend-coupled the same way the grading flip and 邊欄 are. **Decision: goes to Pass
  2 planning**, not a Pass 1a fast-follow.
- **Kitchen Counter footer's 4th cell** (currently 通知 → `NotificationsSettingsView`)
  vs. the design's intent (便條, with an unread count). Investigated during Pass 1a: this
  isn't a one-line retarget — `ChatView` is embedded *inline* in `CounterView` already
  (always visible, not behind a sheet), so there's no separate "chat thread" screen to
  point the footer at without inventing a redundant modal duplicating what's already on
  screen. This is a real information-architecture question (does a 4th 便條 destination
  even make sense given chat is already always-visible?), not a mechanical fix — needs a
  real decision, not a quick patch. **Decision: keep the 4th cell as 通知
  (`NotificationsSettingsView`).** The design's 便條 footer entry isn't adopted for this
  app's actual IA — chat being always-visible inline already covers what that entry
  would have provided.

## 9. Open items for Mike's review (don't silently proceed past these)

1. §4's two inferred boundaries (grading flip and 邊欄 rearchitecture landing in Pass 2,
   not Pass 1) — confirm or correct.
2. §3's presence treatment (shared hollow-seal idiom for both offline types) — confirm
   this resolves the tension acceptably, or wants a distinct treatment.
3. Whether 邊欄-style "recipe page accumulates chat history" is wanted at all as a future
   Pass 2 item, or was more the *visual* framing of D1's existing chat exchange than a
   real ask — the handoff may be over-interpreting a smaller original request.
