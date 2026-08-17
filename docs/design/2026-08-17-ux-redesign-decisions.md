# Sous UI/UX Redesign — Decisions Log

**Date:** 2026-08-17
**Status:** Working notes from brainstorming. **Not a spec yet** — the visual language is
still unresolved, and several questions below are open. Do not implement from this.
**Supersedes in spirit:** `docs/superpowers/specs/2026-08-02-m3-visual-restyle-design.md`
(書與灶 Pass 1) — see §1.

## 1. Why we're redesigning 12 days after finishing a design pass

Mike's verdict on the shipped app: the **paper concept** feels off ("colors, styles and
vibes just seems off") **and** the **flows** are wrong. Both halves, not one.

Diagnosis — one root cause for both:

> The 書與灶 handoff states outright *"Talking to 小當家 is not a chat app"* and demotes
> conversation into margin notes and a slip inbox, building the app as **a beautifully
> printed book you read.** But Mike's actual daily use is **talking to a chef and having
> the thing in front of him change.** A book doesn't answer back.

The concept is off because it made the app an *object*. The flows are off because every
destination is a chapter you open (four equal-weight doors + modal sheets), which is what
you get when navigation is derived from a metaphor instead of from use.

The handoff's instinct — "not a chat app" — was **right for the wrong reason.** It's not
a chat app because chat is a bad *interface* for these tasks. Not because a book is a
better *metaphor*. Correct derivation: fewer words, more taps, and the chef answers by
**changing the thing in front of you.**

### Note on the fonts (closed, minor)

`ios/Sous/Fonts/` contains only `.gitkeep` — zero `.otf` files, while `project.yml`
declares six under `UIAppFonts`. So `FontBook.isSerifBundled` is `false` and all four
merged passes have rendered in `STSongti-TC-Regular` / single-weight `PingFang TC`.
書與灶 is typography-driven (Sans 200/300 chrome, tracking tuned to Noto metrics), so the
app has never rendered as designed. Flagged to Mike; he confirmed the concept is wrong
regardless. **Recorded as history only** — whatever replaces 書與灶 needs its own type
actually shipped.

## 2. Real usage (from Mike, this session)

Ranked by frequency, in his words:

1. **灶前 — actually cooking. Daily. The #1 surface.**
2. **排菜 — the weekly plan.** "Quite important too." **The plan IS the actual schedule** —
   he intends to cook the planned dish on the planned day; deviating is the exception.
3. **買菜 — supermarket.** One-handed, daylight.
4. **今晚煮什麼 — 6pm.** But *not* a decision surface: "should just show tonight's meal
   image and a button that starts it as a convenience access point."

**Off-plan improvisation** ("suddenly want something not part of the plan — supply the
ingredients we want to cook with and it gives us the meal and instructions") is the
**escape hatch for when the plan breaks down**, not the front door.

## 3. The correction that reshaped the design

Mike's flow, corrected from an earlier wrong reading (which had put editing mid-cook):

- **Pre-cook = editing.** Reading the ingredients and steps is where he notices what's
  missing, what portions to change, what to replace or add. Changes here regenerate the
  recipe — "the portions of salt, order of cooking, when to put ingredients."
- **Mid-cook = asking.** 什麼火? 多少糖? 這個可以換嗎? He wants an *answer*, not a rewrite.

Two surfaces, two interactions, two very different costs. This matters because it moves
the expensive call off the stove.

## 4. Decisions

### D1 — Natural language in, UI change out (not chat)

Chat and natural language are separable and we want only one of them:

- **Chat** = a thread; the transcript is the interface; reading his reply is the deliverable.
- **NL command** = you say a thing, **the app changes**. No bubble, no thread.

We want the second. "沒豆腐了" → the ingredient row changes and the step rewrites; there is
no message to read.

**But he still speaks** — one line, in place, attached to the change (「沒豆腐?用天貝,
更香」), then it fades. Otherwise the persona dies and the app is a spreadsheet. This is
the handoff's 眉批 component, which works far better bolted to a *change* than to a page.

**Chat gets no primary surface anywhere in the app.**

### D2 — Recipes are living objects, not immutable records

Today the recipe **freezes** the instant you press 開始做菜. `CookModeView` has five
phases (`.prep → .cooking → .plateUp → .verdict → .done`) and **no input of any kind** in
any of them — no field, no stepper, no affordance to change anything. Servings live only
in `RecipeDetailView` as local `@State`, cosmetic, never reaching cook mode.

So the #1 daily use case is not awkward — it's **absent**. That's why Mike leaves the app
and asks an AI instead.

**Live bug this exposes:** `Ingredient` has structured `qtyValue`/`qtyUnit` so quantities
scale mechanically, but `RecipeStep.text` is plain prose (「加兩大匙醬油」) with no link to
the ingredients it names. Bump servings 2→4 in Recipe Detail today and the ingredient
list doubles while **the steps still say 兩大匙.** The screens silently disagree.

Consequence: **portion change cannot be solved by scaling.** The prose must be rewritten.
So "change portions → rewrite instructions" isn't a feature on top of scaling — it is the
only correct way to do scaling at all. Servings / substitution / addition all collapse
into **one** mechanism: regenerate the recipe.

### D3 — Pre-cook screen: hybrid of brief-then-read and edit-in-place

Mike's pick. Split by *when you know the thing*:

- **Things you know before looking** (servings, 不吃辣, 趕時間, 要帶便當) → a brief-style
  pre-flight, chips + one free-text/voice line.
- **Things you only notice while reading the list** (「oh, I'm out of tofu」) → edit in
  place on the ingredient rows, marked up (struck through / 換的 / 加的).

Forcing the second kind into a pre-flight means answering a question you can't answer yet.

### D4 — Edits batch; one regeneration

Three edits × ~90s each is unusable. Three edits → **one** regeneration is fine. The
screen accumulates changes in a tray and commits them together. Reuses the 但是… pattern
already built for the swipe deck (Pass 2a).

### D5 — Latency splits by surface

Earlier framing overweighted this. Corrected:

| Need | Surface | Cost |
| --- | --- | --- |
| Full recipe regeneration | Pre-cook, standing at the counter | ~60–90s is **fine** — designed waiting state, you go wash rice |
| 什麼火? 多少糖? | Mid-cook, hands busy | Must be **fast**. Short answer, no regeneration — small fast model |

Pre-computation is still worth considering for predictable cases (instruction variants at
1/2/3/4/6 servings; a recipe's 5–8 likely substitutions), but is no longer load-bearing
now that the heavy call moved off the stove.

**Open cost decision:** a fast mid-cook path likely means a cloud API call, breaking
CLAUDE.md's "$0/mo, Claude subscription" premise. Precedent exists —
`worker/sous_worker/gemini_intake.py` already calls Gemini Flash with `GEMINI_API_KEY`.
Mike's call, not to be designed around silently.

### D6 — No LLM-generated UI; polymorphic results instead

Rejected dynamic/generated UI: you'd wait ~90s to render a *form*, and it can't be
tested. Accepted: a small set of **known result shapes** the app renders natively — one
dish / several to choose from / "you're one ingredient short, plan around that instead?"

### D7 — Voice: yes, scoped

- Voice → text → **the same NL handler.** Not a parallel voice assistant.
- **Push-to-talk, not a wake word** (extractor fan, kitchen noise). Wake word is a v2 argument.
- Cook mode is the canonical hands-busy case, so voice is the *correct* input there, not a gimmick.
- **Must verify before speccing:** on-device `SFSpeechRecognizer` quality for **zh-TW**,
  especially mixed 中英 cooking vocabulary. On-device is free and fast; if zh-TW needs a
  server round-trip the economics change. Not asserted either way yet.

### D8 — IA

- **Home** = tonight's dish image + 開始做菜. One image, one button. **Not four equal doors.**
- **Off-plan improvise** = its own entry, reached when the plan breaks down.
- **灶前** = the daily surface; ask, don't edit.
- **排菜 / 買菜** = reached when relevant, not permanent tenants of the home screen.

Pass 2a's swipe foundation **stays load-bearing** — the plan is the real schedule (§2).

### D9 — Visual language: 火 (fire) on a clean modern base

Chosen after three rounds over eight directions. Full detail lives in
`docs/design/2026-08-17-claude-design-brief-v2.md` §5 — that document is the reference,
not this summary.

- **The discipline:** heat must always carry information. A glow that just sits there is
  decoration, and decoration is how minimal apps end up looking stock.
- **The governing rule:** **heat means "now."** A tense, not a category. Present tense is
  hot, past cools, future is neutral. Two things were explicitly tried and rejected on
  this basis — tinting a list of *upcoming* steps by 火候 (reads as a striped table), and
  mapping temperature to days of the week (a Wednesday is not hotter than a Thursday).
  Heat tracks **activity**, never schedule.
- **Palette:** a physical ladder 暗紅 → 橙 → 焰 → 金 → 白熱. Cold end deliberately
  **灰 (ash), not grey** — spent must read *used up*, not *switched off*; **炭 (charcoal
  with grain), not flat black** — grain gives a glow somewhere to land; and **青 as the one
  cool counterpoint**, because fire needs something to be hot against.
- **火種 (pilot light) is how presence works** — always lit, grows when he's thinking, out
  only when he genuinely can't answer. Maps onto `households.worker_seen_at`. This closes a
  problem two prior designs failed at (書與灶's hollow seal, and the deleted 爐火已點 chip).
- **Heat is his pulse** — thinking breathes, committing flares, finished cools to 灰. This
  is where the aliveness comes from.
- **開火 is the one signature transition** — ignition, not a fade: dark first, a click in
  the dark, light last from the bottom. Heat always rises from the bottom edge.
- **Type is open and unusually important** — never discussed in any prior pass, and
  "system font" is precisely the stock feeling being escaped.
- **Four sounds only** — gas click, timer ting, one thud when he commits, silence on
  checkmarks.
- **Cut:** 煙痕 (pages accumulating carbon by cook count), a brush-stroke mark, 手改
  editorial markup, 印 a stamping seal, 他本人 a drawn character.

## 5. Open questions

1. **Motion is the one unresolved part of the visual system.** 鍋氣 (arrive by wok-toss)
   and 熱氣 (waiting as heat-shimmer) were sketched and not taken, so the territory is open
   rather than those two rejected. This matters — "more free, more dynamic and lively" was
   part of Mike's original complaint and motion is the main lever for it. Handed to Claude
   Design as an open question.
2. **Does tonight's regenerated version persist?** New recipe, a variant of the original,
   or discarded after cooking? Does it update `shopping_items`? Does the cook history
   record which version you actually cooked?
3. **Shape of the off-plan improvise flow** — agreed it's the escape hatch; not designed.
4. **`recipe_tweak` doesn't fit.** It returns a *new candidate card* (`dish_text`, `pitch`,
   `shopping_items`) for the swipe deck — it swaps one dish for another. It does **not**
   regenerate the ingredients and steps of a recipe. Recipe regeneration is a new job kind.
5. **No pantry/fridge entity exists.** Tables are `recipes / plan_weeks / plan_days /
   shopping_items / staples / …`. `staples` is "things we always have, keep them off the
   list" — static, not "what's in there right now."
6. **What happens to `RecipeDetailView` vs `CookModeView.prep`?** Both list ingredients
   today, redundantly. Mike's "before I press start cooking I look at the ingredients and
   instructions" describes Recipe Detail. Likely a collapse: read/adjust, then gather.

## 6. Proposed sequencing

Four workstreams; do not attempt as one spec.

1. **Adaptive recipe + pre-cook screen** — daily, #1, concrete gap, includes the D2 bug.
2. **Mid-cook ask** — smaller; depends on the fast-path decision (D5).
3. **Off-plan improvise** — needs a fridge entity.
4. **Visual language** — last, deliberately: by then we know what the app *does*, which is
   what should drive how it looks.

Order not yet confirmed by Mike.
