# Sous — AI Chef Agent App

A native iOS app: a chef agent in your pocket. **Sous** (as in sous-chef) is the
persona-neutral stage; **小當家** 🔥 is the default chef persona inside — 熱血, dramatic,
「料理,是要帶給人們幸福的!」. Forked from the `alfred` household system
(`~/Projects/alfred`) — alfred stays frozen as Mike's personal Discord/markdown setup;
Sous is the clean, productizable rebuild.

**Design spec (source of truth):** `docs/specs/2026-07-11-sous-app-design.md`
Read it before any architecture or feature work.

## Architecture (one paragraph)
SwiftUI iOS app ↔ Supabase (Postgres + Auth + Realtime + pg_cron/Edge→APNs) ↔ laptop
worker daemon that claims `jobs` rows, renders household context from rows into prompts,
runs the brain via `claude --print` (Claude subscription, $0/mo), and writes state back
exclusively through typed `state_api.py` verbs. No agent frameworks; no md↔rows
round-tripping — reads render one-way, writes are tool calls.

## Layout
- `ios/` — SwiftUI app (Kitchen Counter home, sheets, teleprompter cook mode)
- `worker/` — laptop daemon, forked prompts (`worker/prompts/`), `state_api.py`
- `supabase/` — schema migrations, RLS policies, edge functions
- `docs/` — specs, design brief for the Claude Design pass

## Rules
- **Hard isolation from alfred:** never read/write alfred's `state/` or Discord. Prompts
  were *copied* at fork time; improvements do not auto-flow between the systems.
- **Persona discipline:** zero hardcoded persona strings in app or prompts — all voice/
  copy flows through the persona layer (`personas.prompt_pack` / `copy_pack`).
- **Writes only via `state_api.py`** — the brain never free-writes state.
- Milestones M1 (talking skeleton) → M2 (full loop) → M3 (soul pass); each has a
  real-use exit test in the spec. Verify via real use, not sandboxes.
- `.env` holds secrets (Supabase service key, APNs key) — never commit, never print.
