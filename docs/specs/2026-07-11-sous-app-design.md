# 小當家 App — Design Spec

**Date:** 2026-07-11
**Status:** Approved design, pre-implementation
**Product name:** **Sous** — the chef at your side (sous-chef). Persona-neutral stage name:
小當家 is the default persona inside (and what Mike's household sees); the fiery-British-chef
persona comes later as a content drop. Repo: `~/Projects/sous/` (separate from `alfred`,
matching the hard-fork architecture). Trademark/App Store collision check before public launch.

## 1. Product Concept

A native iOS app that puts a **chef agent in your pocket** — lively, personality-first,
AI-native. Not a meal planner with a chatbot; a chef you talk to, who runs your kitchen:
plans the week, teaches you to cook tonight's dish step by step with timers, keeps the
shopping list live, reacts when plans change, and nudges you with soul.

Primary goal: a better daily surface than Discord for Mike's household.
Secondary goal: productizable — multi-household, multi-persona, bilingual — without
rearchitecting.

**Design north stars:**
- **Soul first.** The persona is the product. Every screen the chef can speak on, he does.
- **Chat is the write path.** Anything can be changed by saying it (「醬油沒了」「今晚不想
  吃咖哩」) and the UI updates in real time.
- **Structure is pinned, not scrolled.** Chat history never carries state; dashboards and
  sheets do. (The anti-Discord principle.)
- **Fun, not utilitarian.** 熱血 softened one notch: fire at moments (hero card, stamps,
  milestones), calm at rest (body text, lists).

## 2. Decisions Log (how we got here)

| Decision | Choice | Rejected alternatives |
|---|---|---|
| Motivation | Better UX for household now + productize later | UX-only; product-only |
| Brain location | Laptop (existing Claude subscription), $0/mo | Full API now ($20–60/mo pre-validation); split API-chat |
| Middle layer | Supabase (Postgres/Auth/Realtime/Edge/pg_cron) | Firebase, CloudKit, own VPS |
| Platform | Native iOS (SwiftUI) | PWA (timers/lock-screen too weak), React Native |
| Isolation | Two households: production (Discord/markdown, frozen) + app (Supabase-native sandbox) | Shared state (rejected: gf must see zero change) |
| App brain state | **Fork**: Supabase-native brain; reads = one-way render into prompt, writes = typed `state_api` tool calls | Materialize md↔rows round-trip (rejected: bidirectional parse was the riskiest component and served only code reuse) |
| Navigation | **D ・ Kitchen Counter** — chat-first single root with pinned dashboard | Pure tabs (A/C/E), pure chat (B — scrollback buries structure) |
| Surface opening | Bottom sheets (~85%, detents), chef summonable inside sheet | Full-screen rooms (kept for cook mode only), swipeable counter |
| Cook mode | Teleprompter (one step per screen) v1 → stage-lanes later | Live checklist ("productivity app" feel) |
| Art direction | 熱血廚房 softened; final visuals via Claude Design pass | Warm editorial, sticker pop |
| Personas at v1 | 小當家 only, but persona layer from day one (zero hardcoded persona strings) | Two personas day one (doubles copy/testing) |
| Agent frameworks | None — Claude Code/Agent SDK is the runtime, Postgres queue is the orchestrator | LangGraph, CrewAI |

## 3. System Architecture

```
┌─ iOS app (SwiftUI) ─────────────────────┐
│ Kitchen Counter UI                       │
│ reads:  Supabase realtime subscriptions  │
│ writes: chat_messages, checkboxes,       │
│         verdicts, cook_sessions, jobs    │
└──────────────┬──────────────────────────┘
               │
┌──────────────┴──────────────────────────┐
│ Supabase (free tier)                     │
│ Postgres + Auth (Sign in with Apple)     │
│ + Realtime + Storage                     │
│ + pg_cron + Edge fn → APNs push          │
└──────────────┬──────────────────────────┘
               │ jobs / state rows
┌──────────────┴──────────────────────────┐
│ Laptop worker (new daemon, sibling of    │
│ listener.py)                             │
│ claim job → render context from rows →   │
│ run brain (claude --print, forked        │
│ prompts, state_api tools) → rows update  │
└─────────────────────────────────────────┘
```

**Household isolation.** Production household (Mike + gf): today's Discord/markdown/git
system, frozen — no new features (one deletion: fridge snap leaves the ritual prompt).
App household: Supabase rows only. Discord never touches Supabase. Graduation later =
one-time, one-way markdown→rows import script.

**Job lifecycle (the canonical flow).**
1. App inserts `chat_messages` row + `jobs` row (kind=`chat`).
2. Worker (realtime subscription; ~20s polling fallback) claims atomically via
   `FOR UPDATE SKIP LOCKED` → `status='running'`.
3. Worker assembles context *deterministically* (no LLM lookups): persona prompt_pack,
   current plan, preferences, cookbook index, last ~20 messages, open shopping items —
   rendered into the prompt (generalization of `listener.py build_prompt`).
4. Brain session: `claude --print`, tool allowlist = `state_api.py` subcommands (+ Read
   for bundled reference files). Model mutates state only through vetted verbs.
5. Reply inserted as `chat_messages` row (with optional `cards` JSONB rich attachments);
   job marked `done` with result summary.
6. UI updates via existing realtime subscriptions — no bespoke refresh paths.

**Failure handling.** Stuck `running` jobs past per-kind timeout → sweeper requeues
(max 2 attempts) → `failed` + apologetic in-character chef message (lesson from the
2026-06-14 and 2026-07-04 timeout incidents: never leave the user talking to a void).
`state_api` verbs are idempotent/safe to re-run. Worker heartbeat → `households.
worker_seen_at` → presence (「主廚在廚房/外出中」); dead worker = queue waits, app is
honest about it.

**Notifications survive laptop sleep.** Brain pre-generates notification content into
`notifications` (send_at, title, body, deeplink) during scheduled generation jobs (as
today's nudge/prep system does); pg_cron + Edge function deliver via APNs on time
regardless of laptop state.

**API migration path (productization).** Worker is a stateless job consumer: move the
same loop into cloud containers, swap `claude --print` (subscription) for Claude Agent
SDK (API key), N workers × M households via the same atomic claim. Add billing/rate
limits/observability as side boxes. Model tiering per job kind (chat→Haiku-class,
ritual/enrichment→Sonnet-class) is a config field. App, schema, job contract, and
notifications pipeline unchanged. Chat-mode direct-to-Postgres tools are already the
end-state pattern (no interim architecture to unwind).

## 4. Data Model

All household-scoped tables carry `household_id` + RLS (member-only). Worker uses the
service key. App writes are limited to app-owned tables/columns (marked ★).

**Identity & config**
- `households` — id, name, persona_id, timezone, worker_seen_at
- `household_members` — user_id (Supabase auth) × household_id, role
- `personas` (global) — name, language, tint, avatar, `prompt_pack` (system-prompt
  fragment), `copy_pack` JSONB (notification/UI copy templates). Row 1: 小當家.

**Kitchen state (brain-owned; app mutates only via jobs)**
- `recipes` — slug, title, `source_block` (verbatim 📌 原始食譜), `body_md` (teaching
  card), `ingredients` JSONB, `steps` JSONB `[{stage, text, duration_sec?, tip?}]`
  (powers teleprompter + timers; enrichment prompt gains structured-output requirement)
- `plan_weeks` — week_of, status, reasoning
- `plan_days` — date, dish, recipe_id?, mode (batch/fast/leftover/play), prep_note,
  nutrition JSONB, reasoning, status (planned/cooked/skipped)
- `shopping_items` — week_id, name (English, searchable), qty, section, ★`checked`,
  source recipe refs
- `staples` — name, `flagged_low`
- `preferences` — single row per household (JSONB or text)
- `inbox_items` — cravings/feedback/notes awaiting next ritual (mirror of inbox.md)

**Interaction (★app-owned; brain reads, never authors)**
- `chat_messages` — sender (user/chef), content, `cards` JSONB, job_id?
- `cook_sessions` — recipe_id, started_at, completed_at, step ticks (streaks/history
  are derived — no separate table)
- `verdicts` — plan_day_id, rating (神作/不錯/普通/翻車), note?

**Machinery**
- `jobs` — kind (chat/ritual/recipe_intake/notif_generate/…), payload JSONB, status
  (queued/running/done/failed), attempts, result JSONB, claimed_at
- `notifications` — send_at, title, body, deeplink, status
- `device_tokens` — user_id, token, platform

## 5. App Brain (fork, Supabase-native)

- **Prompts:** copied from `prompts/` (the accumulated cooking/planning wisdom is the
  asset), adapted per mode: file reads → rendered context blocks; file writes/Discord
  posts → `state_api` calls / chat cards. Ritual prompt is the largest adaptation —
  budget accordingly.
- **`scripts/state_api.py`** — the one vetted write seam (spirit of plan.py/capture.py/
  save_recipe.py): subcommands with typed args doing explicit SQL. Initial verbs:
  `get-plan`, `set-plan`, `update-day`, `swap-days`, `save-recipe`, `add-shopping-item`,
  `remove-shopping-item`, `flag-staple`, `capture-inbox`, `clear-inbox`,
  `queue-notification`, `post-card`. The model can only invoke verbs — no free-form
  state writes, nothing to parse back.
- **Modes (forked from existing):** `chat` (front door for everything conversational,
  incl. live edits), `ritual` (weekly planning), `recipe_intake` (share-sheet drops;
  Gemini pre-fetch logic ported from listener), `notif_generate` (pre-generates
  morning/prep/ritual/verdict notification content on schedule).
- **Frameworks:** none. Agent runtime = Claude Code now / Agent SDK later; orchestrator
  = the job queue. Anything fancier must prove itself against those two. No vector DB —
  context is a few KB of structured rows, assembled deterministically.

## 6. Surfaces & UX

**Kitchen Counter (home, the only root screen).** Pinned layer that never scrolls away:
presence header (小當家 🔥・在廚房/外出中), Tonight hero card (dish, mode, prep
countdown, 開始料理 →), chip row (📅 本週 ・ 🛒 買菜 N ・ 📖 食譜 ・ 🔥 streak). Below:
chat with docked input. Wireframe intent: `.superpowers/brainstorm/` session mockups.

**Sheets (week / shopping / cookbook).** ~85% bottom sheets, swipe up = full, down =
dismiss. Clean content; small chef avatar in corner — tap to summon input bar over the
sheet; replies appear as inline bubbles; mutations animate in live.
- **Week board:** vertical days, tonight highlighted, mode tags + prep + nutrition
  lines. Drag-to-swap → swap job → pending shimmer until brain confirms. Tap day →
  recipe card. All edits land as jobs (gestural or conversational).
- **Shopping list:** aisle-grouped; checkboxes write ★`checked` directly (no job —
  instant at Woolies). Checked items sink + strikethrough. Cart status line display-only.
- **Cookbook:** searchable card grid, verdict history + 上次煮 per recipe; recipe view =
  teaching card + 📌 原始食譜 + 「排進菜單」 (→ inbox job).

**Cook mode (full screen — the one non-sheet).** 備料 checklist gate → teleprompter:
one step per screen, huge type, per-step timer button, chef tip line, progress segments.
Timers continue via local notifications when backgrounded (「⏱ 燉煮好了!回來下一步 🔥」).
Screen stays awake. Escape hatches: 「出狀況了」→ chat overlay carrying cook context
(current recipe + step in the rendered context; step-aware answers), step-list jump.
Finish → 上菜 celebration (persona stamp, streak +1) → tees up verdict.
*Evolution path (post-v1): stage + parallel lanes (「同時可做」) once recipes carry
parallel-track structure.*

**Post-dinner verdict.** Push ~1h after cook session completes (20:30 fallback):
「今晚的○○如何?」 with notification actions 🤩/👍/😐/👎 — one tap from lock screen →
`verdicts` row + inbox item. Optional note in-app.

**Share-sheet recipe drop.** Share an IG/YT/web link → 小當家 extension → `recipe_intake`
job → push when the enriched card lands (「新菜學會了!」) → cookbook + inbox craving.

**Staple flagging.** Cook mode + chat: 「醬油快沒了」→ `flag-staple` → next week's list +
chip badge.

**Weekly ritual.** Sunday 16:00 push → chat; brain reconciles inbox + verdicts, proposes
the week as a rich card; conversational tweaks (two-touchpoint rule survives); 「鎖定!」
→ plan + shopping rows written; board updates live.

**Onboarding (thin).** Scripted persona interview: allergies → dislikes → spice →
equipment → household size → `preferences`. Doubles as future productizing funnel.

**Streaks/history.** Derived from `cook_sessions` + `verdicts`: stats card in cookbook
sheet, persona reactions at milestones. No new machinery.

## 7. Persona Layer

Persona = data package: name, avatar, accent tint, language, `prompt_pack` (voice for
the brain), `copy_pack` (notification/UI copy templates). Discipline from day one: **no
persona strings hardcoded in app or prompts** — all voice/copy flows through the layer.
v1 ships 小當家 only; the English chef (fiery British archetype — *not* Gordon Ramsay by
name/likeness) becomes a pure content drop later. Theme system is persona-tintable
(token layer), one set of bones.

## 8. Scope

### In v1
Kitchen Counter + chat ・ live conversational editing ・ week board / shopping / cookbook
sheets ・ teleprompter cook mode + timers ・ in-app weekly ritual ・ share-sheet recipe
drop ・ post-dinner verdict push ・ staple flagging ・ notifications + presence ・ persona
layer (小當家) ・ thin onboarding ・ streaks (derived).

### Deferred (real value, wrong time)
| Feature | Why it waits |
|---|---|
| Widgets + Live Activities | User call ("later"); needs stable timer model first. Top v1.x candidate. |
| Stage-lanes cook mode | Needs parallel-track recipe structure; teleprompter proves the surface first. |
| Voice control | Hard (speech, kitchen noise) for unproven interaction; big tap targets first. |
| Second persona | Content drop once layer exists; double copy/testing before an English user exists. |
| 裝車/Woolies fill in-app | Laptop-bound, brittle, account-risky — stays production-Discord. App shows status at most. |
| Streaming replies | Whole messages simpler and in-character; revisit if slow. |
| Billing / cloud workers / rate limits | Productization machinery before PMF. Sockets exist in the architecture. |
| Android / web / iPad | One platform until the product deserves two; backend is client-agnostic. |
| Nutrition dashboards | Per-day line ships; dashboards unproven. |
| Multi-cook collaborative mode | Speculative; someday-list. |

### Cut (decided against)
| Item | Why |
|---|---|
| Fridge snap (app AND Discord ritual) | Vision inventory too inaccurate to trust (user call). Remove from ritual prompt. |
| Materialization (md↔rows round-trip) | Replaced by fork; bidirectional parse was the riskiest component, served only reuse. |
| LangGraph / CrewAI | Agent SDK is the runtime; Postgres queue is the orchestrator. Frameworks add deps, not capability. |
| Vector DB / RAG | KBs of structured rows; deterministic assembly beats retrieval at this scale. |
| Discord in app household | Hard isolation requirement. |
| Scripted Woolies login | Standing account-risk rule. |
| Full-API brain now | $20–60/mo pre-validation; fork makes later swap weeks, not a rewrite. |

## 9. Milestones

**M1 「會說話的骨架」— talking skeleton.** Supabase schema + RLS + Sign in with Apple.
Worker v0: claim loop, heartbeat, chat mode e2e (context render → brain → reply row),
read-only tools. Ugly SwiftUI app: auth, counter, chat, realtime.
*Exit: message 小當家 from the phone; he answers knowing the sandbox week.*
(Architecture risk lives here — hence first.)

**M2 「完整的一週」— full loop.** `state_api` write verbs + chat live edits. Ritual mode
ported (propose/tweak/lock). Week + shopping sheets. Structured recipe steps +
enrichment update + share-sheet intake. Cook mode teleprompter + timers.
*Exit: one real week — Sunday ritual through Friday dinner — planned, shopped, cooked
entirely in the app (sandbox household; Discord serves the real week in parallel).*

**M3 「有靈魂」— soul pass.** APNs pipeline (morning nudge, prep reminders, ritual
prompt, verdict actions). Presence states. Claude Design system applied as
persona-tintable token layer. Onboarding interview. Streaks + milestone reactions.
*Exit: gf-ready — hand over TestFlight without apologizing.*

**Design handoff (parallel with M1/M2):** write `docs/design/brief.md` for the Claude
Design pass — concept + soul, persona system, screen inventory with locked structural
decisions, flows as storyboards, copy voice samples, constraints (iOS/SwiftUI,
dark-mode-first, sheet detents, Dynamic Type), pointer to session mockups. Structure
locked; pixels open. Output lands on the M1 walking skeleton as a token layer + screen
polish phase.

## 10. Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Chat latency when laptop asleep | Honest presence (「主廚外出中」), queued jobs, pre-generated notifications unaffected. If it hurts in practice → API swap is the contained fix. |
| Ritual prompt adaptation regresses planning quality | Port incrementally; compare app-household ritual output against production Discord output for the same week (they run in parallel by design). |
| Brain timeout mid-multi-tool job (2026-07-04 class) | Per-kind timeouts, sweeper requeue (max 2), idempotent verbs, failure → in-character apology message. |
| Structured steps enrichment quality (timers wrong/missing) | Steps JSONB optional per recipe; cook mode degrades to card text; verdict/feedback loop flags bad cards. |
| Supabase free-tier limits | Household-scale data is tiny; realtime connections few. Revisit at productization (paid tier is a productization cost, not a now cost). |
| Two-brain divergence (Discord vs app wisdom) | Accepted consciously: Discord frozen, app is the future; lessons file ports at graduation. |

## 11. Verification

Per household rule (verify via real use, not sandboxes): each milestone's exit test is a
*real-use* checkpoint (M1 real chat, M2 a real week cooked, M3 gf-ready). Unit tests
where logic is mechanical: `state_api` verbs (against a local/branch Supabase), job
claim/requeue semantics, notification scheduling, streak derivation. Prompt-level: same-
week parallel comparison Discord vs app ritual. The `state_api` seam gets tests before
prompts depend on it.
