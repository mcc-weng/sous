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

## Why this pass exists — the actual goal, not just the task list

The app already works end-to-end (real chat, real meal planning, real cooking flow) but
has zero visual identity and several interactions that are more effortful than they need
to be. Two things should both be true when this pass is done:

1. **Faster, more efficient, more convenient than the Discord version it replaces.**
   Concretely: fewer moments that require typing when a tap would do (see quick-reply /
   swipe below), less scrolling back and forth mid-task (the inline chef-tip decision
   under Cook Mode exists for this reason), momentum — starting the weekly ritual or
   starting to cook should feel like one clear action, not a multi-step negotiation.
2. **It should feel alive — like it has a soul, not like a form.** This is a tone goal for
   *everything you design in this pass*, even though the specific proactive-messaging
   features below are out of scope for now. Small, specific touches matter here: 小當家
   reacting with real warmth to a cooking milestone, the presence indicator feeling like
   a person is actually there rather than a status field, microcopy that sounds like a
   chef talking to you and not an app labeling a button. If two otherwise-equal layouts
   differ on which one feels more like "a friend in the kitchen" versus "a utility app,"
   pick the former.

Concrete interaction references Mike likes and wants reflected here: the cook-mode-style
recipe screen in the Claude app (photo carousel, servings/unit controls, print/copy,
clear "start cooking" action, step layout) — see the Recipe Detail section below — and
swipe gestures for picking-from/dismissing a small set of suggested options rather than
typing a reply.

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
system styling from an earlier "unstyled by design" milestone. These screens exist and
work; the design pass is about giving them an actual visual identity and, in a few
cases, redesigning the interaction itself. **Updated 2026-07-29**: two new full-screen
surfaces (Explore Deck, Ritual Swipe Session, see the dedicated section below) are being
designed *in addition to* everything already in this inventory — including the current
ritual Q&A screens, which still need full designs, not placeholders. It isn't decided
yet whether the swipe session replaces the Q&A ritual in the same release or ships as a
later follow-on, so both need to exist as finished designs. Full mechanics/data-model
spec: `docs/superpowers/specs/2026-07-29-swipe-ritual-judge-design.md`.

1. **Auth** — Sign in with Apple. Simple, low-stakes.
2. **Kitchen Counter** (home) — presence indicator (在廚房/外出中), tonight's dish,
   quick actions, chat entry point, and (new) a prominent peek card into the Explore
   Deck — see below. Exact layout budget across hero card / chip row / peek card is
   yours to solve.
3. **Chat** — free-text conversation with 小當家. The weekly ritual currently runs as a
   guided text Q&A here — **please still design this as originally planned**, it's
   real, shipped functionality. Separately, there's a new possible entry point: an
   in-character chat message with a CTA button that would launch a new Ritual Swipe
   Session (see below) instead of the Q&A. Design both — it isn't decided yet which one
   ships first, so both need to exist as real, finished designs, not one placeholder and
   one real screen.
4. **Week Board** — the week's planned dishes, day by day; drag/long-press to swap two
   days; its existing "開始本週儀式" button currently launches the guided Q&A ritual —
   design that as today. It may eventually launch the new Ritual Swipe Session instead
   (see below); same "design both, undecided which ships first" note applies.
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

## Screens with real interaction changes, not just restyling

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
  history, *and* now feeds a chef "judge" commentary (see the new Ritual Swipe Session
  section below for the competition-show framing this supports).

## New surfaces: Explore Deck and Ritual Swipe Session

Two new full-screen surfaces (same tier as Cook Mode — not a sheet, full immersion, no
tab bar chrome). Both use the same three-gesture card mechanic: **swipe right** = like,
**swipe left** = pass, **swipe up** = opens a short text field docked to the card for a
"yes, but" note (e.g. "沒有蝦", "想要辣一點"), then closes back into the deck.

**Explore Deck** — reachable anytime via the peek card on Kitchen Counter (see item 2
above). Ambient, low-stakes, no day/plan commitment — this is browsing for fun and
signal, framed as "what looks good today," not a task. Occasional cards are wildcard/
novel dishes 小當家 is suggesting fresh, distinct visually from your usual rotation
(a subtle badge/treatment, e.g. "新嘗試" — exact treatment up to you).

**Ritual Swipe Session** — launched from the chat CTA button or the Week Board's
ritual button. Same card mechanic, but every right/up swipe assigns that dish to a
specific day, building the week live as you swipe (some visible sense of "day 3 of 5
filled" matters here — a progress indicator, not just a raw card stack). Ends in a
lock/confirm moment equivalent to today's 鎖定! — this is the emotional high point,
worth real design attention (confetti-tier moment, matches the "上菜" celebration
already planned for Cook Mode). A swiped-up modification note doesn't resolve
instantly — the card the user modified may reappear a few positions later in the deck
once 小當家 has an answer, so consider a subtle re-entry treatment (e.g., a small
"updated" tag) distinct from a fresh card.

**Judge/competition framing** — this is where the Culinary Class Wars / MasterChef tone
Mike wants should show up most: the post-cook verdict moment (existing 4-tier rating,
now with the optional photo from Cook Mode) gets a chef commentary line generated from
the rating + how the cook session went + history with that dish — framed as 小當家
"judging" the dish, with drama coming from comparing this attempt to the user's *own*
past attempts of the same recipe ("第三次做,比上次快了十分鐘"). No new numeric score —
the existing 4-tier rating is the score, the commentary is the theater around it.

## Explicitly out of scope for this design pass

Mike also wants the app to eventually feel proactive — occasional check-in messages,
noticing when household appetite/inspiration might be low, surfacing dishes trending on
social media unprompted, like a friend sending a link. **This is real, but it's new
backend capability (nothing today lets the brain start a conversation on its own), not a
visual design question** — it's being treated as a separate future milestone, not part of
this pass. Please don't design screens for it yet.

Also out of scope, don't design for these: **multiplayer/social battles** (comparing
against another household's cook of the same dish — needs a social phase that doesn't
exist yet) and **demographic-based recipe recommendation** (inferring taste from
ethnicity/location/age — not needed at this household's scale, and conflicts with a
standing architecture decision against recommendation-algorithm complexity). Both are
parked, not designed.

## What we need out of this project

The goal isn't a handful of inspirational sketches — it's a comprehensive,
implementation-ready set of screens, flows, and a real design system (tokens +
components), covering all 10 screens above, that gets handed back to a Claude Code
session afterward to actually build in SwiftUI. Treat "would an engineer know exactly
what to build from this" as the bar, not "does this look nice as a single screen."
That means: settle the visual direction first (don't half-explore three directions and
stop), then carry it consistently across every screen, including the ones that are just
restyled rather than redesigned — a screen with no new interaction still needs the same
level of finish as Recipe Detail or Cook Mode, not an afterthought.

## The codebase

This repo (`sous`) will be linked/uploaded separately if useful for structural context —
but be aware it currently has **no design system to extract**: no color assets, no theme
file, a handful of scattered default-system-color calls. Its value as context is the
actual screen structure and data model (what a "recipe," a "plan day," a "cook session"
actually contain), not any existing visual language — there isn't one yet.
