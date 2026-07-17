# Sous Design Brief — Raw Notes

> Seed notes for the eventual M3 "Claude Design pass" brief. Captured 2026-07-17 during
> M2b2 brainstorming, before the formal design session. The design spec
> (`docs/specs/2026-07-11-sous-app-design.md` §6) already locked most structural
> decisions (Kitchen Counter, sheets, teleprompter cook mode) — this file collects
> lived-experience input that should inform the M3 pass, not redo that structure. Expand
> into the full brief shape (concept & soul, persona system, screen inventory, flows as
> storyboards, copy voice samples, constraints) when M3 design work actually begins —
> this file is not that yet.

## Discord/小當家 usage insights (from Mike, 2026-07-17)

Captured directly from Mike's real usage of 小當家 on Discord — what to fix/keep when
the app version replaces it as the daily surface.

### Shopping list
- Hard to read on Discord (wall of text in scrollback), no check marks — items get
  forgotten because there's no way to mark "got this."
- **Already addressed structurally** by the design spec's shopping list decision
  (aisle-grouped, checkboxes write directly to `shopping_items.checked`, instant, no
  job) — this insight validates that decision and confirms checkmarks are core
  functionality, not a "nice to have" polish item, even in a functional-only build.

### Cook mode (→ M2c scope, not M2b2)
- **Portion/ingredient changes mid-cook get no updated instructions.** Decide to double
  a recipe, or you're missing/substituting an ingredient — Discord can't regenerate the
  steps on the fly, so you're stuck following instructions written for different
  quantities/ingredients. Want: live instruction regeneration when portion or
  ingredients change mid-cook.
- **No timer.** The cook-mode spec already plans a per-step timer button (§6) — this
  confirms it's a real pain point from actual use, not a speculative nice-to-have.
- **新手最容易翻車的地方 (rookie failure points) and 主廚秘訣 (chef tips) should be
  inline with the instruction, not a separate section requiring scroll-back-and-forth.**
  The teleprompter design already plans a "chef tip line" per step — this insight
  sharpens it: the tip/warning needs to be visually merged into the same step card the
  instruction is on, not below a long scrolling document, so nothing requires
  re-reading the instruction after checking a tip.

### Ritual / plan-edit latency
- **Ritual back-and-forth (and any plan edit) feels slow.** Real cloud runs this
  session took ~100-150s per turn (craving deck, proposal, lock). On Discord this is
  masked by chat's inherently async nature — you send, scroll away, come back later. In
  an app UI, a screen that looks frozen for a multi-minute brain turn reads as broken,
  not as "thinking."
- **Implication for M2b2 (even functional-only):** some loading/waiting state is a
  functional requirement, not a polish item. The spec already anticipates this for
  drag-to-swap ("pending shimmer until brain confirms") — the same treatment likely
  needs to extend to ritual turns and any chat-driven plan edit, not just gestural ones.

## Open scope note carried into M2b2 planning

#1 and #3 above are functional requirements, not decoration, even though full visual
design was explicitly banked for M3 (2026-07-17 decision — see project memory). M2b2's
functional build should still include: persistent shopping-item checkboxes (actually
writing `checked`, not just rendering state), and *some* loading/pending indicator during
ritual turns and chat-driven plan edits — doesn't need to be pretty, needs to exist.
