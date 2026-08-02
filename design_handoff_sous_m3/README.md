# Handoff: Sous M3 — 書與灶 (the book and the stove)

## Overview

The M3 visual design pass for **Sous / 小當家**, an AI private-chef app for Taiwanese
households. This handoff covers the complete screen set: onboarding, home, the weekly
planning ritual in both its models (conversational and swipe), the always-on explore
deck, shopping, cookbook, recipe detail, cook mode with concurrent timers, the
photo-and-verdict moment, settings, all empty/error/offline states, the copy pack, the
motion spec, and accessibility rules.

The design implements the mechanics locked in
`docs/specs/2026-07-11-sous-app-design.md` §6 and
`docs/superpowers/specs/2026-07-29-swipe-ritual-judge-design.md`. Two changes to those
specs were made during the design pass and are called out under **Spec deltas** below —
read them before implementing.

## About the design files

The files in this bundle are **design references created in HTML** — prototypes showing
intended look and behaviour, not production code to copy. The task is to **recreate
these designs in the target codebase's existing environment**: Sous is a SwiftUI iOS app
(`ios/Sous/`), so these become SwiftUI views using the project's established patterns.
Do not port the HTML/CSS.

The prototypes are interactive where interaction carries meaning — drag the ritual
cards, tap 揭曉, step the servings, run the timers, press 播放 on the motion studies.
Use those to understand behaviour; use this README for exact values.

## Fidelity

**High fidelity.** Final colours, typography, spacing, and interaction behaviour.
Recreate pixel-accurately using SwiftUI primitives. Everything is specified in points
(the HTML is authored at a 402pt logical width = iPhone 15/16 Pro).

---

## The system in one page

Sous is **a finely printed cookbook you happen to hold on a phone**. Nearly every screen
is a page: warm uncoated stock, ink-black serif, one seal red per page, running heads
and folios, wide margins, hairline rules.

The **only** dark screens are the three where something is running and your hands are
busy: the cook-mode steps, the timers, and 上菜. This is the rule:

> **If your hands are busy and something is counting, dark. Everything else is paper.**

Crossing between the two happens **once per cooking session** and both directions are
designed (see *Motion → the crossing*). 開始做菜 dims the page to the stove; 上菜 prints
the night back into the book.

**Talking to 小當家 is not a chat app.** There are two conversational surfaces:

1. **邊欄 (margin)** — the primary one. You ask from the page you are on, and his answer
   is written **into that page permanently**. A recipe accumulates 這一頁的往來 like
   annotations in a used cookbook.
2. **便條 (the slip thread)** — a single inbox for anything that belongs to no page: the
   ritual invitation, the shopping nudge, "週四我不在".

He is **never "online"**. A book's author has no presence indicator. The v1 concept of
爐火已點 is deleted; the only time his availability is expressed is when the device is
offline, and it is expressed by hollowing his seal plus one sentence.

---

## Design tokens

### 紙 · Paper (every screen except the three below)

| Token | Value | Use |
| --- | --- | --- |
| `paper.stock` | `#EDEAE2` | Page background |
| `paper.stockAlt` | `#E7E2D8` | Deck screens (slightly darker, so white cards lift) |
| `paper.slip` | `#F7F4EC` | 小當家's slips, ritual cards |
| `paper.ink` | `#22201C` | Primary text, ink-filled buttons |
| `paper.inkDim` | `#4E4A42` | Secondary text, quantities |
| `paper.inkFaint` | `#5E5A52` | Labels, running heads, captions |
| `paper.seal` | `#9B2C1E` | The one spot colour — once per page |
| `paper.rule` | `ink @ 20%` | Hairline rules |
| `paper.ruleStrong` | `ink @ 42%` | Increase Contrast only |
| `paper.leader` | `ink @ 30%` | Dotted leader lines on ingredient rows |
| `paper.slipShadow` | `1px 2px 0 ink@9%` | Slip lift (hard offset, not blurred) |
| `paper.cardShadow` | `0 16px 36px ink@20%` | Ritual card |

### 灶 · Stage (cook-mode steps, timers, 上菜 — three screens only)

| Token | Value | Use |
| --- | --- | --- |
| `stage.bg` | `#0C0A09` | Background (warm black, not neutral) |
| `stage.ink` | `#F4EFE6` | Primary text |
| `stage.inkDim` | `#A49D93` | Secondary text, labels |
| `stage.brass` | `#C98A3E` | Accent: step number, timer ring, tip rule |
| `stage.brassSoft` | `#DCC59C` | Tip body text |
| `stage.seal` | `#9B2C1E` | The one token both rooms share |
| `stage.glow` | `radial(brass @20%) blur 16px` | Anchored to the bottom edge |
| `stage.rule` | `ink @ 20%` | Hairlines |

**Colour rules.** Seal red appears **once per page** — if a screen needs it twice,
something is wrong with the hierarchy. Colour is never the sole carrier of meaning:
every state that uses seal red also has a word (已買 / 未購買, 已更新, 待同步).

### Typography

Two families. **Noto Serif TC** is 小當家's voice — dish names, verdicts, recipe body,
眉批, numerals. **Noto Sans TC** is interface chrome, labels, and anything **you** type.
That split is what keeps his voice distinct from the app's. Sans is never heavier than
500 anywhere.

| Style | Family | Size | Weight | Tracking | Line height |
| --- | --- | --- | --- | --- | --- |
| `display` | Serif TC | 31 | 400 | .04em | 1.42 |
| `displayLarge` | Serif TC | 38 | 400 | .05em | 1.5 |
| `verdict` | Serif TC | 42 | 600 | .28em (+ text-indent .28em) | 1.0 |
| `title` | Serif TC | 22–29 | 400–500 | .03em | 1.4 |
| `body` | Serif TC | 14 | 400 | 0 | 2.15 |
| `marginNote (眉批)` | Serif TC | 12.5 | 400 italic | 0 | 1.95 |
| `slipBody` | Serif TC | 14–14.5 | 400 italic | 0 | 2.0 |
| `label` | Sans TC | 10 | 400 | .42–.5em | 1.0 |
| `runningHead` | Sans TC | 10 | 400 | .34em | 1.0 |
| `ui` | Sans TC | 12.5–13.5 | 300 | 0 | 1.85 |
| `uiButton` | Sans TC | 13.5 | 500 | .34em | 1.0 |
| `caption` | Sans TC | 10.5–11.5 | 300 | .14–.22em | 1.9 |

Numerals: **Chinese numerals (一二三四五) for anything ceremonial** — step numbers, day
markers, folios, counts in prose. **Arabic with `tabular-nums` for anything measured** —
quantities, timers, durations.

Stage typography is the same scale with `body` at Sans 200 and step text at Serif 26/300.

### Spacing & shape

- Page margins **32–36pt** (34 is the default; deck screens use 24–30).
- Section labels are **centred** and tracked .42–.5em.
- **No border radius anywhere on paper.** Slips, cards, buttons and stamps are all
  square — this is the single biggest carrier of the printed feel. Stage uses 0 as well,
  except the timer ring (circle) and the 上菜 photo target.
- Rules are 1px (2px only for a chapter divider on 麻紙-style headers, not used in the
  final stock).
- Minimum touch target **44pt**, shopping rows **56pt** (62pt at AX sizes).

---

## Screens

Numbering below matches the sections in `Sous App v2.dc.html`.

### A1 · 扉頁 (Auth)

**Purpose** — sign in. One action, no fields.

Centred column, 40pt margins, vertically centred: 40×40 seal square (`seal` bg,
`slip` glyph 當, 18pt) → `私　廚　手　記` (Sans 10/.62em, seal) at 30pt below → headline
`你的私廚` / `在口袋裡` (Serif 38/400/.05em, line-height 1.5) → 24×1 rule (`ink @ 30%`)
with 24pt margins → promise `小當家會記住你家的口味、排好這一週,然後在爐邊陪你把它煮出來。`
(Serif 14/400, lh 2.2, `inkDim`).

Footer, 40pt margins: outlined button `以 Apple 帳號登入` (1px `ink`, Sans 13.5/.32em,
16pt padding), then `我們只存你家的口味與菜單` (Sans 10.5/.16em, `inkFaint`, 18pt below).

### A2 · 廚房 (Kitchen Counter — root)

**Purpose** — tonight's dish, one action, and the four destinations.

Top to bottom: running head `我們家的廚房` / today's date in Chinese numerals (Sans
10/.34em, `inkFaint`) → 1px rule → centred `今　晚` (label, seal) → dish name (Serif
31) → meta line `四十分 · 快手 · 雞腿前一晚退冰` (Sans 10.5/.22em, `inkDim`) → photo
plate, 178pt tall, full content width → **ink-filled** `開始做菜` button →
`進入灶前 · 畫面會暗下來` (caption, centred) → his slip with two reply chips → 想吃什麼
section: label, then a 54pt thumbnail + `滑一下,我記著` + `今天十二張新牌 · 收藏五道`
+ seal `→` → ruled footer with four equal cells `本週 / 採買 6 / 食譜本 / 便條 2`
(counts in seal).

The 便條 unread count is the app's **entire** notification surface. There is no badge
system beyond it.

### A3 · 便條 (the slip thread)

**Purpose** — everything he says that isn't about a specific page.

Header: seal square + `與小當家的往來` + 關閉. Date separator centred.

**His slips**: `slip` background, `2px solid seal` left border, `slipShadow`, 16–18pt
padding, Serif 14.5 italic, signed bottom-right `小當家 · 18:40` (Sans 9.5/.22em).
**Your messages**: right-aligned, max 78% width, 1px `ink @ 28%` border, no fill, Sans
13.5/300, unsigned.

Any slip whose reply changed something carries a link row below a hairline:
`已修改` (Sans 9.5/.24em, seal) + what changed + seal `→`.

Composer: 1px top rule, `寫給小當家…` placeholder, seal `↑`.

### B1 · 滑牌儀式 (swipe ritual)

**Purpose** — build next week by dealing cards, one per open day.

Background `stockAlt`. Header + progress: `已排 三 / 五 天` / `還剩 兩 天` (Sans
10.5/.24em, `inkDim`), then a 1px rule with a seal-red fill from the left at
`filled/5` width, 300ms transition.

**Card stack** — three sheets, 24pt side margins, no radius:
- back: `rotate(1.5deg) translateY(7px)`, `#DED7C8`
- middle: `rotate(-0.9deg) translateY(3px)`, `#E9E3D6`
- front: `slip` bg, `cardShadow`, draggable

Front card contents: day `週　三` (Sans 10/.42em, seal) + `已依「沒有蝦」改過` when the
card is a re-entry → photo plate (38% of card height) → dish (Serif 28) → meta (Sans
10.5/.2em) → 22×1 rule → his pitch (Serif 13.5 italic, lh 2.0).

Drag: `translate(dx, dy) rotate(dx × 0.05deg)`. Stamps `排入` (seal) and `換道` (ink)
are 2px-bordered, rotated ∓12°, opacity bound to `|dx| / 80` — they never animate.
Release past ±80pt commits; otherwise springs back at 300ms settle.

**但是… (swipe up)** docks a panel onto the bottom of the card: `stock` bg, 2px seal top
border, label 但是…, a text field underlined at `ink @ 34%`, three suggestion chips, then
取消 / **交給小當家改**, and the promise `不用等 —— 牌繼續發,改好了它會再出現一次。`
The deck must keep moving; the revised card re-enters later tagged 已更新.

Footer is a **ruled bar** (not pills): `換一道` | `但是…` (78pt fixed) | `排入這天`
(seal, 500 weight), separated by 1px rules, 17pt vertical padding. Hint line below.

When all five days are filled the card is replaced by the lock card: `五天都排好了`
(label, seal) → `這一週 / 交給我` (Serif 27) → consequence line → ink-filled `鎖　定`.

### B2 · 對話儀式 (written ritual — ships today)

Same guided Q&A as the current build. Every fixed-choice moment **also** offers chips so
the user can tap instead of type. His questions are slips; the user's answers are
outlined boxes.

**The waiting state is a designed screen, not a spinner** — a 1px-bordered field
containing: a 14pt seal-coloured spinner + the current stage (`看菜單… / 配菜… / 寫清單…`,
Serif 16, rotating every 2.6s) → a three-segment rule showing coarse progress → an
honest estimate + `你可以先去忙 —— 排好我會放進便條通知你。` → an outlined
`先離開,好了通知我` button. Real cloud turns take 100–150s; a screen that looks frozen
reads as broken.

### B3 · 鎖定 (lock)

Running head `下週菜單` + date range → centred 34pt seal square → `已　鎖　定` (label)
→ `這一週 / 我來安排` (Serif 29) → the week as a ruled table (day in seal Chinese
numeral, dish, right-hand tag 已更新 / 新菜 / 多煮一份) → his sign-off slip → ink-filled
`看採買清單 · 十四項` + outlined `回廚房`.

Same emotional tier as 上菜. Restraint carries it — no glow, no confetti.

### C1 · 備料 (mise en place — still paper)

Checklist of scaled ingredients. Rows 56pt, 24×24 square checkbox (`1px ink@42%` empty →
`seal` filled with `slip` ✓), name Serif 16, quantity Serif 14 `tabular-nums`. Checking
is instant and local. Ink-filled `開始烹飪` + the crossing warning.

### C2 · 灶前 (cook mode — dark)

Teleprompter. Progress: four 1px segments, brass for done/current. Step label
`步驟 二 / 四` (Sans 10/.42em, brass). Previous step at Sans 15/200 `#8B857C`, current at
**Serif 26/300 lh 1.62**, next at Sans 15/200 `#78736B`. The tip is inside the current
step: 14pt left padding, 1px brass left border, `小當家眉批　` label (Sans 10/.28em,
brass) then the tip inline (Sans 13/200, `brassSoft`).

**Timers.** Step ring: 118pt conic-gradient (`brass` to `progress°`, rest
`ink @ 12%`), 104pt inner disc in `stage.bg`, Serif 26 `tabular-nums` + state word.
Concurrent background timers are text-only: name (Sans 12.5/200) + Serif 19 brass
number + a small outlined 暫停/繼續. Both run independently — pausing the step timer must
not pause the rice.

Footer: `← 上一步` (text) and a brass-outlined `下一步`, which becomes **上菜** on the
last step.

### C3 · 上菜 (plate up — dark, last dark screen)

`上　菜` (Sans 10/.66em, brass) → `收工了。/ 拍一張,我來寫。` (Serif 26/300) → a square
1:1 photo target (1px `ink@22%`, hatched fill, 50pt brass ring with ◎) → filled `拍照`
→ text-only `跳過,直接聽講評` → `寫好後會收進食譜本 —— 那一頁就多一行你的紀錄`.

The copy points home before the transition, so the fade to paper reads as arriving.

### C4 · 講評 (verdict — paper)

**Uses the recipe's own running head and folio** (`家常 · 雞` / `二三`) — the user is
literally on their own page.

`寫進書裡了` (label, seal) → `蔥香雞腿飯 · 第三次` → photo → italic caption
`八月二日 · 二十八分鐘 · 比上次快十分`.

**Blind reveal.** Before: label 小當家的評價 → the verdict word at Serif 36, colour
`#C9C3B6`, `blur(6px)` → ink-filled `揭　曉` → `他看了照片、看了你每一步的時間,也記得你
前兩次的樣子。` After: the tier centred between two flexible 1px rules at Serif 42/600
/.28em, then `四級中的第一級` (Sans 11/.26em) → his commentary slip → `這一頁的紀錄`
listing every past attempt with its verdict → ruled bar `我同意` | `我不服`.

### D1 · 食譜 (recipe — where 邊欄 lives)

Running head + folio → centred `第 三 道` (seal) → title (Serif 31/.05em) → 22×1 rule →
description → photo + italic figure caption → **servings stepper** on a ruled band
(`份量` label, seal −/+, Serif 16 tabular value) which live-rescales every quantity →
centred `食　材` with dotted-leader rows → centred `作　法` with seal Chinese numerals,
Serif 14/lh 2.15 body, inline 眉批, and duration below → **the 邊欄 exchange** (a slip:
`你問` + the question in Sans, hairline, then his answer with a 20pt seal square, footed
`已寫進這一頁`) → `這一頁的紀錄`.

Sticky footer holds both the ask field (`問小當家關於這一頁…`) and the ink-filled
`開始做菜`, over a gradient fade to `stock`.

### D2 · 食譜本 (cookbook)

**A table of contents, not a card grid.** Search field, four filter chips, then chapters
by ingredient (`家常 · 雞`, `家常 · 豆腐`, `麵 · 飯` — seal labels). Each row: folio
number (Sans 11, seal, 24pt column) + dish (Serif 15) + `五次 · 神作` (Sans 10.5,
`inkDim`). Closing line: `頁碼是這本書自己長出來的 —— 你煮過的菜,我就替你編一頁。`

### D3 · 探索牌組 (explore deck)

Same paper cards as B1, distinguished by **what is absent**: no day chip, no progress
rule, no lock. `冷門推薦` labels wildcards. Ruled footer `下一張` | `但是…` | `收藏`.
Contract stated in the footer: `收藏不會排進菜單 / 儀式時我會先看這裡`. Nothing here
touches the plan.

### E1 · 採買清單 (shopping)

The one screen that must work one-handed in daylight — paper suits it. Progress rule
fills seal-red. Aisle chapters as seal labels. Rows 56pt: 24pt square checkbox, name
Serif 16, quantity Serif 14 tabular. Checked rows drop to 50% opacity, strike through,
and replace the quantity with the word **已買**. Checking writes `shopping_items.checked`
immediately and locally — never gated on the network, never a job. Staples nudge is a
slip, never an auto-added row.

### E2 · 本週 (week board)

The plan as a printed table. Cooked days at 55% opacity with their verdict; **tonight is
the only slip on the page** (slip bg, seal left border, `今晚 · 二十五分`, ink-filled
開始); a selected-for-swap row is marked 已選取 in seal; a pending swap shows a seal
spinner + 對調中…. `長按兩天可對調`. Below a rule, next week offers both ritual models
by name: ink-filled `滑牌排` and outlined `用寫的`.

### E3 · 設定 (settings as colophon)

Sections: **儀式節奏** (每週 / 每兩週 / 不固定 chips + anchor day + explanation of what
the setting causes), **便條通知** (printed square toggles — filled seal = on, outlined =
off), **這本書是為誰寫的** (preferences on dotted-leader rows; allergens are the only
seal-red value), then the imprint: seal square + `小當家 · 私廚手記 / 為這個家寫的第 一 版`.

### G · States

- **第一頁** — the empty book. Folio reads `第 一 頁` instead of a number. Two doors,
  one recommended (`排這一週` ink-filled, `今晚先煮一道` outlined), each with a one-line
  explanation. Closing line promises the book fills itself.
- **中斷** — brain failure. His slip, in character, must do three things: keep the
  user's input, say **what was not damaged** (`你這週已經鎖定的菜單沒有變動`), and offer
  a path that doesn't need the brain (自己排下週 / 沿用這一週的菜單). No error code, no
  red banner.
- **離線** — dashed-border notice; checkboxes still work and show 待同步; **his seal
  goes hollow** (transparent fill, 1px `ink@30%` border, `inkFaint` glyph) — the only
  place in the app it is not filled.
- **牌發完了** — tomorrow's promise plus what today's swipes bought.
- **沒拍照** — still a verdict, but it names the missing evidence:
  `依過程評分 · 沒有擺盤分`.

---

## Interactions & behaviour

### Motion

Two curves: **settle** `cubic-bezier(.2,.8,.3,1)` for anything that lands, **heat**
`cubic-bezier(.4,0,.2,1)` for anything that glows or fills. Three buckets: **140ms**
feedback, **280ms** transition, **620ms** ceremony.

**過場 · the crossing (940ms — the signature transition).** The page does not slide, it
**dims**. Paper darkens and desaturates in place over 620ms (`brightness(.28)
saturate(.4)`), the stove page cross-fades up starting at **340ms**, and the burner glow
only arrives at **500ms** — light comes on last, the way a gas ring does. Reversed and
~220ms faster on the way home, glow leaving first.

**發牌 · deal.** The sheet leaves along the drag vector at 280ms settle, carrying the
rotation it had at release (never a fixed angle), and its shadow shrinks as it lifts.
The next sheet settles from its resting tilt after an 80ms delay.

**揭曉 · reveal.** Rules draw outward from the centre (280ms settle) → the blurred cover
clears (280ms heat) → the verdict lands at +220ms over 620ms with tracking closing
.40em → .28em, like type being locked up in a forme → `四級中的第一級` at 620ms →
commentary 200ms later. Total ≈1.05s and **interruptible**: a tap jumps to the end state.

**寫進書裡 · slip lands.** A slip settles onto the page over 280ms with a small y-offset
and a shadow that firms up — never a slide-in from a screen edge. His reply fades up
*inside* the landed slip, so the question visibly sticks before the answer arrives. Used
identically in 便條, 邊欄 and 講評.

**Pending shimmer.** One treatment for every awaiting-brain state (drag-to-swap, a note
being answered, a chat-driven plan edit): 1.2s loop, accent at 16%. It washes over the
old value, which stays readable and tappable.

**What never animates**: ingredient and shopping checkmarks (instant — the stamp *is*
the receipt), shopping rows re-sorting (they'd move under a wet finger), cook-mode step
text (140ms opacity swap, no slide — the eye must not chase it at the stove), and page
folios.

### Accessibility

- **Every swipe has a button, labelled by outcome** (`排入週三`, `換一道`, `補一句`) —
  never by gesture.
- **At AX sizes the ritual card stops being throwable** and becomes a scrollable panel
  with three stacked ≥54pt buttons; tracking relaxes to .06–.1em (wide tracking is the
  first thing that destroys CJK legibility at size); the swipe hint is **dropped, not
  shrunk**.
- **The reveal announces twice**: the tier *with its position in the scale*
  (`評價:神作。四級中的第一級。`) then the commentary — a blurred cover and a tier row
  are both invisible to VoiceOver. `tier_position` ships even when the row is visible.
- Required labels: timer ring (`步驟二計時器,剩四分十二秒,暫停中。輕點兩下繼續。`),
  shopping row (`蔥,一把,未購買。輕點兩下標記已買。`), 眉批, deck card, and the hollow
  seal (`小當家目前無法回覆` — never "灰色圖示").
- Shopping at AX5: 62pt rows, 30pt stamps, quantities never truncate — the row grows.
- **Reduce Motion** collapses everything to 140ms cross-fades, including the crossing
  (a straight cut, warning line still shown). **Increase Contrast** lifts rules to
  `ink@42%` and `inkFaint` → `inkDim`.
- **System Dark Mode does not invert the book.** Paper stays paper; the stock dims to
  `#E2DED5` and brightness follows the system. Inverting a printed page destroys the
  premise.
- Timers fire a haptic **and** a sound — the phone is usually across the counter.

---

## State

Per-screen state the prototypes exercise:

| State | Type | Notes |
| --- | --- | --- |
| `servings` | Int 1…8 | Live-rescales every ingredient quantity on recipe + 備料 |
| `checkedIngredients` | Set\<Id\> | Local, instant |
| `shoppingChecked` | Set\<Id\> | Writes `shopping_items.checked` immediately; offline-safe, queued for sync |
| `deckIndex` / `filledDays` | Int | Ritual progress; right/up advances both, left advances index only |
| `dragOffset` | CGSize | Drives card transform + stamp opacity |
| `noteOpen` | Bool | The 但是… panel; closing does **not** block the deck |
| `verdictRevealed` | Bool | Blind-reveal gate |
| `stepIndex`, `stepTimer`, `backgroundTimers[]` | — | Independent timers, each with its own run state |
| `narrationStage` | Int | Rotates through `thinking_stages[]` every 2.6s during brain turns |

### Spec deltas — read before implementing

1. **Grading moved from the user to 小當家.** `verdicts.rating` becomes a **brain
   write**, not a user write. The user's input is now a reaction: `我同意` / `我不服`.
   The four-tier scale (神作/不錯/普通/翻車) is unchanged and remains the only score —
   no numeric scale was added.
2. **`我不服` needs a landing.** Recommended: a re-tasting job that may revise the
   *commentary*, not the grade, and records the user's objection in that dish's history.
3. **Commentary inputs**: the photo, cook telemetry (elapsed time, timers used, steps
   revisited) and the user's own history with that dish. Drama comes from
   self-comparison ("第三次做,比上次快十分鐘") — no opponents, no leaderboard.
4. **Ritual cadence** lives in Settings (interval chips + anchor day) — this resolves the
   spec's open question.
5. **收藏 decay** surfaces in the UI as 快過期 for items unused for a month; the rule
   itself still needs a decision.
6. **Presence is deleted.** Any `presence_*` copy keys and the online-dot component can
   be removed.

---

## copy_pack

The repo forbids hardcoded persona strings. Every string in these designs is a key with
a neutral fallback; screens reference keys, never literals. The full table with
小當家's values and fallbacks is rendered in **section H** of `Sous App v2.dc.html` —
implement from there. Keys new in this pass: `tip_label` (小當家眉批), `inbox_title`,
`margin_ask`, `margin_written`, `crossing_warning`, `verdict_written`, `empty_book`,
`app_subtitle`, `book_title`.

Two rules for engineering: **`rating_tiers` is copy, not enum** — store the enum, render
the pack's label; and **`tier_position` is not decorative**, it is the accessible carrier
of the four-tier scale.

---

## Assets

No production imagery. Every photo position is a hatched placeholder sized and captioned
as intended (`料理照片`, `你拍的成品照`, `圖 · …`). Mike will supply real photography;
note that cream stock is less forgiving of badly lit phone shots than black was, so
photo guidance is worth agreeing early.

Fonts: **Noto Serif TC** and **Noto Sans TC** (Google Fonts, SIL OFL). Weights used:
Serif 300/400/500/600, Sans 200/300/400/500.

---

## Files in this bundle

| File | What it is |
| --- | --- |
| `Sous App v2.dc.html` | **The design.** Sections A–J: screens, states, copy_pack, motion, accessibility. Interactive. |
| `Sous Refinements.dc.html` | How the visual direction was arrived at — variants A–G including the paper-stock studies and the three answers to the chat problem. Useful for understanding *why*, not what to build. |
| `Sous App.dc.html` | The superseded v1 (black stage). Kept for the states/copy/motion/a11y sections that were written first. **Do not build from this.** |
| `Sous Directions.dc.html` | The six original visual directions. Historical. |
| `ios-frame.jsx`, `support.js` | Prototype scaffolding only — not part of the design. |

Open the `.dc.html` files directly in a browser.

## Repo mapping

| Screen | Existing files |
| --- | --- |
| 扉頁 | `ios/Sous/AuthView.swift` |
| 廚房 | `ios/Sous/CounterView.swift` |
| 便條 / 邊欄 | `ios/Sous/ChatView.swift` (restructure — see the chat section above) |
| 本週 / 儀式 | `ios/Sous/WeekBoardView.swift`, `WeekBoardLogic.swift` |
| 滑牌 / 探索 | new — spec `docs/superpowers/specs/2026-07-29-swipe-ritual-judge-design.md` |
| 採買 | `ios/Sous/ShoppingListView.swift`, `ShoppingListLogic.swift` |
| 食譜本 / 食譜 | `ios/Sous/CookbookView.swift`, `RecipeDetailView.swift` |
| 做菜 / 上菜 / 講評 | `ios/Sous/CookModeView.swift`, `CookModeLogic.swift` |
| 設定 | `ios/Sous/NotificationsSettingsView.swift` |
| copy_pack | `supabase/` persona tables, `worker/` prompts |
