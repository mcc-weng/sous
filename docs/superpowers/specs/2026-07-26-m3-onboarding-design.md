# M3 — Onboarding Design

**Status:** Approved, ready for planning.

## Context

M3's APNs pipeline shipped and merged (`docs/superpowers/plans/2026-07-25-m3-apns-pipeline.md`).
Per the original design spec (`docs/specs/2026-07-11-sous-app-design.md` §6/§9), the next
M3 sub-phase is onboarding: "Scripted persona interview: allergies → dislikes → spice →
equipment → household size → `preferences`. Doubles as future productizing funnel."

Today `preferences` is a single free-text column (`content`), read-only from the app's
perspective — there is no write policy at all (`0002_rls.sql`), and no `state_api` verb
can write it either. The one household that exists (Mike's sandbox) already has
`preferences` seeded by hand (`seed.sql`). There is no onboarding scaffold anywhere in
the iOS app — only signed-in/signed-out branching in `SousApp.swift`.

## Scope decisions made during brainstorming

- **Native step wizard, not a chat-driven interview.** The original spec's "scripted
  persona interview" reads as chat-shaped, and the ritual mode (propose/tweak/lock) is
  the existing precedent for brain-driven multi-turn flows. Rejected: onboarding directly
  affects first-impression retention, and free-text chat typing is higher-friction than
  tap-based multiple choice for a fixed set of scripted questions. Since the questions and
  choices are fully scripted (not something the brain is deciding turn-by-turn), a
  chat-bubble-styled version would only be a form wearing a chat costume — real
  engineering cost (a new interactive-chip message type woven into the permanent chat
  transcript) with no real gain in flexibility. A native step wizard reuses cook mode's
  already-established "one step, one full screen" pattern, is the standard mobile
  onboarding shape users already know how to use, and is simpler and safer to build.
- **Two coexisting write paths for `preferences`, not one.** The wizard writes directly
  (new RLS policy, instant completion, matches the retention need for a snappy finish).
  A separate `update_preferences` `state_api` verb is added for the already-agreed "just
  chat naturally" revisit path (e.g. 「我開始吃素了」mid-chat) — these are two different
  callers of the same column, not competing designs.
- **No brain involvement in the wizard itself.** Composition (structured taps → free-text
  bullet lines) happens client-side, following the exact convention already established
  in `seed.sql`. No job, no brain round-trip, on completion — same carve-out already
  established for the shopping-list checkbox (instant, no job).
- **No back-parsing existing preferences into pre-filled chips on redo.** Revisiting via
  settings re-presents the wizard empty; completing it overwrites `content`. Acceptable
  for v1 given "thin" scope; flagged as a known limitation, not a gap to silently carry.
- **All-skip still counts as complete.** If every question is skipped, `content` is
  written as a neutral placeholder (`(尚無特殊偏好)`) rather than staying empty — a
  household with genuinely no dietary restrictions shouldn't be re-prompted every launch.
- **No per-member onboarding.** `preferences` is household-scoped, not user-scoped. If
  one household member already completed onboarding, subsequent members on the same
  household just see Kitchen Counter directly.

## Architecture

Two independent pieces, plus one migration each:

1. **Onboarding wizard (iOS, new)** — a `fullScreenCover` presented when the household's
   `preferences.content` is empty, either on first launch or from a settings re-trigger.
   Writes directly to `preferences` via the Supabase client.
2. **`preferences` write RLS migration** — adds an upsert policy scoped to
   `is_member(household_id)`, mirroring the existing `shopping_items` write-policy shape.
   Required for (1) to work at all; today `preferences` has read-only RLS.
3. **`update_preferences` state_api verb (worker, new)** — upsert-by-`household_id`
   verb following the `flag_staple` pattern exactly, wired into `chat.md`'s "你的手"
   section so the brain can update preferences during ordinary chat. No RLS/migration
   needed here — `chat_allowed_tools` already blanket-allows the whole `state_api.py`
   script.
4. **`copy_pack` migration** — adds onboarding framing keys (per-question intro lines,
   encouragement, completion celebration) to existing personas' `copy_pack`, following
   `0007`'s `copy_pack || jsonb_build_object(...)` merge pattern. Chip option lists
   themselves (allergen names, equipment names, etc.) are plain data, not persona voice —
   they stay hardcoded in the wizard view, not routed through `copy_pack`.

## Component 1: Onboarding wizard

Five screens, one question each, progress dots, small 小當家 avatar + `copy_pack`-sourced
framing text per screen. Back navigation allowed; each question is individually
skippable (an omitted answer just drops that line from the composed text, not a blocker).

| # | Question | Widget | Composes to (example) |
|---|---|---|---|
| 1 | 過敏原 | Multi-select chips (甲殼類/花生/堅果/乳製品/麩質/蛋) + "其他" chip opening a single-line text field | `過敏:蝦蟹、花生` |
| 2 | 不吃的東西 | Multi-select chips (香菜/內臟/苦瓜/茄子/...) + "其他" text field | `不吃香菜、內臟` |
| 3 | 辣度 | Segmented control: 不辣／小辣／中辣／大辣 | `辣度:中辣 OK` |
| 4 | 設備 | Multi-select chips (瓦斯爐/電磁爐/烤箱/電子鍋/氣炸鍋/微波爐) | `設備:瓦斯爐、烤箱、電子鍋` |
| 5 | 人數 | Stepper, 1–8+ | `2人份` |

Final `content` is these lines joined one per line, in this fixed order, matching
`seed.sql`'s existing convention exactly — `context.py`'s `_render_preferences` and every
prompt template that reads `{preferences}` need zero changes.

If every question is skipped, `content` is written as `(尚無特殊偏好)` instead of an
empty string, so the household isn't re-prompted every launch.

**Composition logic** (structured selections → free-text lines, including the all-skip
placeholder) is a pure function, unit-testable the same way `WeekBoardLogic`/
`ShoppingListLogic` already are (`ios/Sous/*Logic.swift` + `*LogicTests.swift` pattern).

**Write:** on completion, `preferences` upsert via the Supabase client (new RLS policy
from Architecture item 2). If the write fails (offline, RLS rejection), show inline retry
— selections stay held in wizard state until a write actually succeeds; the user is never
allowed through to Kitchen Counter with an unsaved completion.

## Component 2: Trigger & gating

**First-run trigger.** `AppModel.refreshHousehold()` also fetches `preferences.content`.
If empty/default, present the wizard `fullScreenCover`, blocking Kitchen Counter until
completed. No extra local "already nagged" flag is needed — since `content` only becomes
non-empty once the wizard is actually completed (or all-skipped to the neutral
placeholder), re-launching mid-way correctly re-presents it; that's the desired "forced
once" behavior, not spam.

**Revisit entry point.** `NotificationsSettingsView` is currently the only settings-style
sheet (reached from `chipRow`). Add a "偏好設定" section there with a "重新設定偏好"
action that re-presents the same wizard `fullScreenCover`, starting empty (per the stated
redo limitation above).

## Component 3: `update_preferences` verb (chat revisit path)

```python
def update_preferences(conn, household_id: str, content: str) -> dict:
    conn.execute(
        "insert into preferences (household_id, content) values (%s, %s) "
        "on conflict (household_id) do update set content = excluded.content, "
        "updated_at = now()",
        (household_id, content),
    )
    return {"ok": True}
```

CLI wiring follows the standard 3-part pattern (`_parser()` subparser, `_dispatch()`
branch, `--content` flag) already used by every other verb in `state_api.py`. A new
bullet in `chat.md`'s "你的手" section documents it, plus a rule: if the user states a
new or changed preference in conversation, update it and confirm in character — the
brain composes free text itself for this path (unlike the wizard, which composes
client-side), since there's no fixed question/answer shape to a spontaneous chat mention.

## Testing / verification

- Unit tests: wizard composition logic (structured selections → free-text lines,
  including the all-skip placeholder and omitted-line behavior for individually skipped
  questions).
- `state_api` test: `update_preferences`, following the existing `flag_staple` test
  pattern in `worker/tests/`.
- Real-use exit check: since the real sandbox household already has non-empty seeded
  `preferences`, the forced first-run path won't organically trigger there. Verify by
  temporarily clearing `content` on a test household (not production), confirming the
  wizard forces on launch, completing it, and confirming both that `content` matches the
  composed convention and that the next real chat message's rendered context reflects it
  correctly. Separately verify the settings-triggered redo path and the chat-revisit verb
  (`「我開始吃素了」` → confirm `content` updates and the brain confirms in character).

## Out of scope (tracked for later)

- Back-parsing existing free-text `preferences` into pre-filled wizard chips for redo —
  redo always starts from a blank wizard in v1.
- Per-member preferences (household-scoped only, matching the existing schema).
- Brain enrichment of the wizard's composed text (e.g. inferring related shopping/cooking
  implications at submission time) — the wizard write is deliberately mechanical and
  brain-free, matching the shopping-checkbox precedent.
- Real per-user household provisioning — every new Apple-ID sign-in still auto-joins the
  single sandbox household today (`0002_rls.sql`'s M1 shim); onboarding doesn't change
  that. The "future productizing funnel" framing in the original spec is aspirational,
  not something this phase builds toward.
