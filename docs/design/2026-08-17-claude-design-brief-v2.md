# Sous — Claude Design brief v2 (visual pass)

> Paste into a fresh Claude Design project. Written 2026-08-17.
> **This replaces the 2026-07-29 brief.** That brief produced the 書與灶 design
> (`design_handoff_sous_m3/`), which was built across four passes and is now being
> rejected. §2 explains exactly why — please read it before designing, because the
> failure mode is specific and easy to repeat.

## 1. What Sous is

A native iOS app: an AI chef in your pocket. The only persona today is **小當家** 🔥 —
熱血 (fired-up), dramatic, catchphrase 「料理,是要帶給人們幸福的!」.

The app knows the household's weekly meal plan, shopping list, and cookbook. A laptop
worker (Claude running headless) is the brain; the app is SwiftUI on Supabase. It works
end-to-end today — real planning, real cooking, real ratings.

**Primary language is Traditional Chinese.** Design for CJK as the normal case, English
as secondary. Mike (the user, and the developer) cooks from this daily.

## 2. Why the previous pass failed — please read

The 2026-07-29 brief produced **書與灶 ("the book and the stove")**: the app as a finely
printed cookbook — warm uncoated paper, ink-black serif, one seal red per page, running
heads, folios, hairline rules, no border radius anywhere. Only three screens were dark
(cook mode, timers, 上菜).

It was executed faithfully and it is genuinely beautiful. It is also wrong, and the
reason is worth stating precisely:

> The handoff declared *"Talking to 小當家 is not a chat app"* and demoted conversation
> into margin notes and a slip inbox — building the app as **an object you read.** But
> the real daily use is **talking to a chef and having the thing in front of you
> change.** A book doesn't answer back.

Two consequences, both of which Mike felt without being able to name:

- **The concept made the app static.** Navigation was derived from the metaphor (a book
  has chapters) rather than from use: a home screen that is a lobby with four
  equal-weight doors, everything else behind modal sheets.
- **The app whispers while the persona shouts.** 小當家 is 熱血. 「料理,是要帶給人們幸福的!」
  is not a quiet sentence. Restrained printed elegance is a beautiful register — it is
  not *his* register.

**The trap to avoid:** do not solve this by picking a different metaphor. The metaphor
*was* the problem. What's wanted is a design whose personality lives in the chef's
presence and in how the app responds — not in a themed world the content sits inside.

### Footnote, so it isn't mistaken for a cause
The 書與灶 typography never actually shipped — the Noto Serif/Sans TC files were never
added to the bundle, so everything rendered in system Songti/PingFang fallbacks. Mike has
confirmed the concept is wrong regardless. Mentioned only so it isn't re-litigated.

## 3. How the app is actually used (corrected this session)

Ranked by real frequency:

1. **灶前 — actually cooking. Daily. The #1 surface.**
2. **排菜 — the weekly plan.** The plan **is** the real schedule; he intends to cook the
   planned dish on the planned day.
3. **買菜 — supermarket.** One-handed, in daylight.
4. **今晚煮什麼 — 6pm.** *Not* a decision surface: "just show tonight's meal image and a
   button that starts it."

**The key behaviour the old design missed entirely:**

- **Pre-cook = editing.** Reading the ingredients and steps is where he notices what's
  missing, what portions to change, what to swap or add. Those changes **regenerate the
  recipe** — quantities, the order things go in, when to add what.
- **Mid-cook = asking.** 什麼火? 多少糖? 這個可以換嗎? He wants an *answer*, not a rewrite.

Today the recipe **freezes** the moment 開始做菜 is pressed — cook mode has no input of
any kind. So the #1 daily need is not merely awkward, it is absent, and he leaves the app
to ask an AI instead.

## 4. Decisions already made (not open — please design within these)

- **Natural language in, UI change out.** 「沒豆腐了」→ the ingredient row changes and the
  step rewrites. **No reply bubble, no thread.** Chat gets no primary surface anywhere.
- **But he still speaks** — one line, in place, attached to the change (「沒豆腐?用天貝,
  更香」). Without this the app is a spreadsheet. **See §6 — this is the central design
  problem we want you to solve.**
- **Recipes are living objects.** Servings / substitution / addition all collapse into one
  mechanism: regenerate. (Portion change *cannot* be mechanical scaling — the prose has to
  be rewritten, so today the ingredient list and the steps silently disagree.)
- **Edits batch.** Changes accumulate in a tray; one commit, one regeneration (~60–90s).
  **The waiting state is a designed screen, not a spinner.**
- **Voice input**, push-to-talk, for the hands-busy moments. Voice → text → same handler.
- **Home = tonight's dish + one button.** Not four equal doors.
- **No LLM-generated UI.** A small set of known result shapes rendered natively.

## 5. Visual direction — 火 (decided)

Mike reviewed eight directions over three rounds. **Chosen: 火 — fire as the app's entire
visual language**, on a clean, modern, uncluttered base.

Rejected: paper/書與灶, all-dark ember, loud Taiwanese 熱炒, warm minimal,
editorial-photographic, plain modern minimalism (his words: *"too stock standard, no
personality, no uniqueness"*), a drawn character, editorial markup, and a stamping seal.

Why fire: it is the subject matter, it is the persona (熱血), and it is the one thing a
cooking app can own that isn't a metaphor draped over the content. Heat is what cooking
*is*.

**The discipline that keeps it from being a filter: heat must always carry information.**
A glow that merely sits there is decoration, and decoration is exactly how minimal apps
end up looking stock.

### 5.1 The governing rule — heat means "now"

Heat is a **tense**, not a category. Present tense is hot, past cools, future stays
neutral. Both corollaries below were tested against Mike and are settled:

- **Do** apply heat to the current step, a running timer, and 小當家 while he is working.
- **Do not** tint a list of upcoming steps by their 火候 — it reads as a striped table,
  because five future steps cannot all be happening. *Tried and rejected.*
- **Do not** map heat to calendar position. A Wednesday is not hotter than a Thursday;
  heat tracks **activity**, never schedule. *Tried and rejected.*

火候 still belongs in a recipe's step list — as a coloured **word** (小火 / 中火 / 大火),
never a row wash.

### 5.2 The palette

A physical temperature ladder, not "a brand colour plus neutrals." Every warm value in the
app comes from it and means the same thing everywhere. Values are approved starting
points — refine them.

| Rung | Hex | Means |
| --- | --- | --- |
| 暗紅 | `#8E2F14` | barely lit, low, receding |
| 橙 | `#E0561A` | medium |
| 焰 | `#FF8A2A` | high — the primary accent |
| 金 | `#FFB454` | peak |
| 白熱 | `#FFE1A8` | flare, highlight |

The cold end — three specific calls Mike approved, and the ones that decide whether this
theme works or looks like a filter:

- **灰 ash `#A9A29A`, not grey.** Spent things must read *used up*, not *switched off*.
  Neutral grey is what makes interfaces look disabled and dead; ash is a warm grey with a
  faint bloom.
- **炭 charcoal `#14100D` with a slight grain, not flat black.** Grain is what lets a glow
  look like it is landing on something.
- **青 `#3D5A52` as the single cool counterpoint** — raw, fresh, uncooked, prep, water.
  Used sparingly. An all-fire palette goes monotone fast, and fire needs something to be
  hot *against*.

Base surface: a very slightly warm off-white (around `#FAF8F4`) — warm, but explicitly
**not** the cream of the rejected paper design.

**The ladder is reserved.** This is the most important constraint in the palette, because
getting it wrong is what turns the theme into a filter. The five warm rungs are for
**live-heat states only** — the current step, a running timer, 小當家 working or landing a
change, 開火. Ordinary chrome (buttons, labels, links, selected states, section headers)
uses 墨 ink, 灰 ash, and 青 — **not** the ladder. If 焰 is also the accent colour on every
button, then nothing on the screen means "hot right now" any more, because everything is
orange. Scarcity is what makes the signal work.

### 5.3 火種 — the pilot light. This is how presence works.

One small flame, always in the same corner, always lit. It grows while he is thinking,
flickers when he commits a change, and **goes out only when he genuinely cannot answer** —
the laptop is asleep, the worker process is down.

This resolves something two designs have now failed at. 書與灶 tried a "hollow seal" and it
never read cleanly; the pass before that had a 爐火已點 status chip that was deleted for
being un-book-like. A pilot light is what a kitchen already uses to mean *the gas is on*:
no words, no badge, no chip. It maps exactly onto the `households.worker_seen_at` value
the app already tracks.

Accessibility: it needs a spoken label describing **capability**, never appearance — e.g.
「小當家目前無法回覆」, never "grey icon."

### 5.4 Heat as his pulse

Thinking = a dull red that **breathes**, slowly. Committing a change = a flare up the
ladder, then settling. Finished or old = cooled to 灰, still readable but clearly past.

This is where the app's aliveness comes from. He is not present because a badge says
online — he is present because the screen has a temperature and it changes.

### 5.5 開火 — the one signature transition

Pressing 開始做菜 is an **ignition**, not a fade. The room darkens first, a hard click
lands in the middle of the dark, and light arrives **last**, from the bottom edge. ~600ms.
Reversed coming home: light leaves first, warmth lingers.

**Heat always rises from the bottom and fades upward.** Never a glow floating in the middle
of a card.

This also settles dark-versus-light without a rule anyone has to memorise: the stove is
dark because that is where the fire is and a glow needs somewhere to land. Everywhere else
is light, because heat there is a *signal* rather than the environment.

### 5.6 Type — open, and it matters more than usual here

No previous pass discussed type at all. In a minimal app the face **is** the identity, and
"system font" is precisely how you arrive at the stock feeling Mike is trying to escape.

Two questions we want your answer to:

1. Does the dish name get a display face distinct from the UI, or does one confident
   grotesque carry everything?
2. Quantities and timers want a real tabular face with character — they are what gets read
   at a glance from across a counter.

Constraint: specify CJK faces with **weight ranges that actually ship.** The last pass
called for Sans 200/300 and rendered in single-weight PingFang.

### 5.7 Sound — four, and no more

Cooking apps are almost all silent, and the phone is across the counter with wet hands.

- 開火 — a gas click
- a timer landing — a real ting, not a beep
- 小當家 committing a change — one soft thud
- checkmarks — **silence.** Ticking things off stays instant and quiet.

### 5.8 Considered and cut — please don't re-propose

- Tinted step lists by 火候, and temperature mapped to days of the week / replacing badges
  and counts (§5.1)
- **煙痕 / seasoning** — pages accumulating carbon as cook count rises. Liked in the
  abstract, cut.
- A coloured brush-stroke rule as his mark — *"too simple and boring"*
- 手改 editorial markup, 印 a stamping seal, 他本人 a drawn 小當家

## 6. Still open — motion

Motion is the one part of the system without an answer, and it matters: Mike's original
complaint included wanting the app to feel *"more free, more dynamic and lively,"* and
motion is the primary lever for that. 書與灶 had the least of it.

We sketched **鍋氣** (things arrive by wok-toss — up, over, land, settle) and **熱氣** (the
wait state as the shimmer of air above a burner). Mike didn't take either, so treat the
territory as **open** rather than those two as rejected.

One hard requirement whatever the treatment: **the 60–90s recipe regeneration wait is a
designed screen, not a spinner.**

## 7. Hard constraints

- **No photography exists.** Every image in the previous handoff was a hatched
  placeholder, and that hasn't changed. Recipes come from the brain and from Instagram
  intake; a dish only gets a real photo after it's been cooked once and photographed at
  上菜. **A no-photo state is the common case, not the edge case** — any design where
  images carry the emotional load will be broken most of the time. If you want to argue
  for photography, say concretely where the images come from.
- **Persona-tintable.** No persona-specific value (colour, copy, name, glyph) may be
  hardcoded in a screen. A second persona is planned as a pure content/config swap.
- **CJK first.** Wide letter-tracking is the first thing that destroys Chinese
  legibility at size — the last design leaned on .3–.5em tracking heavily.
- **Real device is an iPhone 13 mini (375pt)**, not a 402pt Pro. Design to the small one.
- **Ship fonts you actually name**, and prefer faces with real weight ranges for CJK —
  the last pass specified weights that the fallback faces could not produce.
- iOS 17+ SwiftUI. Dynamic Type and VoiceOver are requirements, not polish.
- **Colour is never the sole carrier of meaning.** This applies with extra force to a
  temperature language: every heat state also needs a word (大火, 想菜中, 火熄了). Design
  it so a colour-blind user loses nothing.
- **`RecipeStep` has no heat level today** — it carries `text`, `stage`, `durationSec`,
  `tip`. Per-step 火候 needs a new field plus both write paths (the `save-recipe` verb and
  the `recipe_intake` pipeline). Flagged as a dependency, not a blocker: design it and
  we'll add the field.

## 8. Screens to design

| Screen | Status |
| --- | --- |
| 今晚 (home) | Redesign — tonight's dish, one action, no four-door lobby |
| **Pre-cook / recipe (adjust)** | **New and most important** — servings, substitution, addition, the change tray, the regenerated-diff view |
| 灶前 (cook mode) | Keep the teleprompter + timers; add the ask-in-place surface |
| 想菜中 (regenerating) | New — a designed 60–90s wait, not a spinner |
| 臨時想煮 (off-plan improvise) | New — supply ingredients, get a dish. Shape undecided |
| 上菜 / 講評 | Restyle only — see the caution below before designing the verdict |
| 本週 (plan) · 採買 (shopping) | Restyle. Shopping must work one-handed in daylight |
| 食譜本 (cookbook) · 設定 · onboarding | Restyle |

**Caution on 講評 (the verdict).** The previous handoff moved the rating from the user to
小當家, with the user reacting 我同意 / 我不服. That decision predates this session and was
**not re-confirmed** under the new model — and it sits awkwardly against §2 and §4: a
brain-assigned verdict with agree/disagree buttons is precisely a message you read and
reply to, which is the frame we're rejecting. Restyle the screen; treat the grading
mechanic as an open product question rather than a settled input.

## 9. What we are not asking for

- A metaphor or a themed world. See §2.
- Information-architecture changes beyond §4 — that's settled.
- Anything that requires photography we don't have.
