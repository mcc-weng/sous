# Sous — Claude Design starter brief

> Paste this into a fresh Claude Design project to kick off the M3 "soul pass" design
> work. Written 2026-07-29. Supersedes nothing decided in code — this is the design
> conversation starting point, not a spec.

## What Sous is

Sous is a native iOS app: an AI chef agent in your pocket. The default (only, for now)
persona is **小當家** 🔥 — 熱血 (fired-up), dramatic, catchphrase 「料理,是要帶給人們幸福的!」
("Cooking is meant to bring people happiness!"). It replaces a Discord bot Mike currently
uses daily for the same job — the app needs to feel like a genuine upgrade over chatting
with a bot in a text channel, not just a reskin of it.

Core loop: the app knows the household's weekly meal plan, shopping list, and cookbook.
Mike chats with 小當家 to tweak the plan, gets a weekly "ritual" (Sunday planning
conversation), cooks from a teleprompter-style mode, and rates dishes afterward. A laptop
worker (Claude running headless) is the actual brain; the app is Supabase-backed
SwiftUI on top.

**Locked constraints, not open questions:**
- Dark-mode-first. (Not "dark mode supported" — the primary/default experience.)
- Primary language is Traditional Chinese (zh-Hant) — most real UI copy, all persona
  dialogue, is Chinese. Design for CJK text as the normal case, English as secondary.
- Persona-tintable: no persona-specific value (color, copy, name) may be hardcoded into a
  screen. Only 小當家 ships now, but a second persona (an English-language chef archetype)
  is planned later as a pure content/config swap — the visual system must be built so that
  swapping a persona's tint/palette is a data change, not a redesign.

## Visual direction — genuinely open, please explore with us

The original product spec described the direction in three overlapping phrases:
**「熱血廚房」softened**, **warm editorial**, **sticker pop**. These are starting points
for a conversation, not a decided direction — nobody has actually compared them side by
side yet. Please help us explore real options across that range (from restrained/editorial
to playful/high-energy) rather than assuming one.

One early, unreviewed exploration exists in this repo at `docs/design/prototype.html` and
`docs/design/design-system/` — a warm dark palette nicknamed "Ember" (deep charcoal +
ember red-orange + gold). **Treat this as one discarded sketch, not a locked decision** —
it was approved by Mike before he'd seen it compared against alternatives, which is
exactly why we're starting over here.

## Screen inventory (current app, functionally complete, visually untouched)

The app today has zero design system — no color/type/spacing tokens, just default
system styling from an earlier "unstyled by design" milestone. These 10 screens exist
and work; the design pass is about giving them an actual visual identity and, in a few
cases, redesigning the interaction itself:

1. **Auth** — Sign in with Apple. Simple, low-stakes.
2. **Kitchen Counter** (home) — presence indicator (在廚房/外出中), tonight's dish,
   quick actions, chat entry point.
3. **Chat** — free-text conversation with 小當家. See "quick-reply" below for a planned
   interaction change here.
4. **Week Board** — the week's planned dishes, day by day; drag/long-press to swap two
   days; a "start weekly ritual" entry point.
5. **Shopping List** — aisle-grouped items with checkboxes (writes instantly, no brain
   round-trip).
6. **Cookbook** — searchable grid of saved recipes, each showing a cook-count badge.
7. **Recipe Detail** — a single recipe: ingredients, steps, notes. **Redesign target** —
   see below.
8. **Cook Mode** — full-screen teleprompter: prep checklist → step-by-step instructions →
   verdict rating. **Redesign target** — see below.
9. **Onboarding** — first-run wizard (allergies, dislikes, spice, equipment, household
   size), tap-based multiple choice, not chat.
10. **Notification Settings** — a settings screen for push notification preferences.

## Two screens with real interaction changes, not just restyling

**Recipe Detail** — Mike's own reference for the target layout is a real recipe app
screenshot, structure: photo carousel at top, title + short description, a servings
+/− stepper that live-recalculates ingredient quantities, small icon-button row (unit
toggle, print, copy), ingredient list, numbered steps with any tip/warning merged
*inline* with the step it belongs to (not a separate scrolling section — this came
directly from real pain using the Discord version, where tips required scrolling back
and forth), a notes block, and a prominent "start cooking" call to action. (The
screenshot itself is available locally at
`~/.claude/image-cache/af81ea1d-3b84-41f7-9f60-ab6000e882c3/1.png` if you can attach
images directly to this project.)

**Cook Mode** gets two genuinely new pieces of functionality, not just polish:
- A **per-step timer** for steps with a duration (e.g. "bake 45 minutes") — was in the
  original product spec but never actually built.
- A **final "take a photo of the finished dish" step**, before the existing
  thumbs-up/down verdict rating — skippable, feeds the cookbook and the "cooked N times"
  history.

## Also on the table, but treat as lower-confidence / discuss before designing deeply

- **Chat quick-reply buttons** — today, ritual conversations (the weekly planning flow)
  and things like confirming "lock in this week's plan" are 100% free-text, parsed by the
  brain's judgment. Mike wants tappable buttons instead of typing for these fixed-choice
  moments, possibly as swipeable cards for the weekly "what do you feel like eating"
  options specifically. This has real backend implications (the brain needs to emit a
  structured set of choices, not just prose) that aren't settled yet — happy to explore
  the interaction/visual side here, but the data contract is being worked out separately.

## Explicitly out of scope for this design pass

Mike also wants the app to eventually feel proactive — occasional check-in messages,
noticing when household appetite/inspiration might be low, surfacing dishes trending on
social media unprompted, like a friend sending a link. **This is real, but it's new
backend capability (nothing today lets the brain start a conversation on its own), not a
visual design question** — it's being treated as a separate future milestone, not part of
this pass. Please don't design screens for it yet.

## The codebase

This repo (`sous`) will be linked/uploaded separately if useful for structural context —
but be aware it currently has **no design system to extract**: no color assets, no theme
file, a handful of scattered default-system-color calls. Its value as context is the
actual screen structure and data model (what a "recipe," a "plan day," a "cook session"
actually contain), not any existing visual language — there isn't one yet.
