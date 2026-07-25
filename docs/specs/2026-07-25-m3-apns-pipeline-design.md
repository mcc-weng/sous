# M3 — APNs Pipeline Design

> First sub-phase of M3 「有靈魂」— soul pass (`docs/specs/2026-07-11-sous-app-design.md`
> §9). M3 bundles five largely-independent subsystems (APNs pipeline, presence upgrade,
> Claude Design token layer, onboarding interview, streaks/milestone reactions) — too
> much for one spec. This doc covers only the APNs pipeline. Sequencing decision for the
> rest of M3: **APNs → Onboarding → Presence/streaks → Claude Design pass (consolidated,
> last)**, because the Claude Design pass is meant to land "as a token layer + screen
> polish phase" (spec §9) across a screen inventory that doesn't fully exist until
> onboarding and streak UI are built — designing tokens first would mean designing
> against screens that don't exist yet.

## Scope

Four notification types, all built in this one phase (spec §9, locked): morning nudge,
prep reminders, ritual prompt, verdict actions. They share one delivery mechanism, so
building the pipeline once and wiring all four costs barely more than building one.

Not in scope for this phase: per-household configurable notification timing (fixed
defaults for now — no settings UI exists until onboarding lands), and the polished
onboarding-integrated permission flow (a minimal standalone toggle stands in for it,
below).

**Fixed timing defaults** (household-timezone, from `households.timezone`; checked
`worker/prompts/` for an existing fixed dinner-time assumption to reuse — none exists,
so this phase introduces the first one): morning nudge 07:30; ritual prompt Sunday
17:00; prep reminder 15:00 (2h before the 17:00 dinner-prep default); verdict-action
sweep considers a `plan_days` row eligible once household-local time passes that date's
21:00 (17:00 dinner-prep default + ~4h buffer for eating/cleanup) with no matching
`verdicts` row.

## Starting state (verified against the codebase, not assumed)

- `notifications` and `device_tokens` tables **already exist** (`supabase/migrations/0001_schema.sql`),
  fully RLS'd (`0002_rls.sql`). `jobs.kind`'s comment already lists `notif_generate` as
  an anticipated kind. The data model was planned ahead of the rest of M3.
- Nothing consumes or populates these tables yet: no Edge Functions directory, no
  `pg_cron`/`pg_net` extensions enabled, no worker job handler, no iOS registration code,
  no APNs credentials configured.
- `project.yml` already has `DEVELOPMENT_TEAM: 9D37X3YV25` set (paid Apple Developer
  Program membership, confirmed ready to generate an APNs Auth Key). Neither
  `Sous.entitlements` nor `SousShareExtension.entitlements` has the Push Notifications
  capability yet.
- Persona-voiced copy already has an established mechanism: `personas.prompt_pack`
  (brain context) and `personas.copy_pack` (static strings, e.g. `failure_message` used
  in `worker/sous_worker/main.py:25`). Notification copy should flow through the same
  mechanism — no hardcoded persona strings (project rule).
- No `AppDelegate`/`UIApplicationDelegateAdaptor` exists in `SousApp.swift` yet. No
  Settings-like view exists in `ios/Sous/`. `CounterView` presents feature surfaces via
  `.sheet(isPresented:)` (WeekBoard, ShoppingList, Cookbook) — the pattern any new sheet
  should match.

## Architecture

Two independent stages, connected only through the `notifications` table.

**Stage 1 — Content generation.** Needs the brain, needs the laptop worker awake, but
has hours of buffer before the actual send time — this buffer is what makes the pipeline
resilient to "laptop asleep" (spec §10 risk table: *"queued jobs, pre-generated
notifications unaffected"*).

- New job kind `notif_generate`, handled by the worker's existing dispatch loop
  (`worker/sous_worker/main.py`), same as `chat`/`ritual`/`recipe_intake`.
- New `state_api` verb `schedule_notification(conn, household_id, send_at, kind, title,
  body, source_id=None, deeplink=None) -> dict`, following the exact shape of existing
  verbs in `worker/state_api.py` (plain function, CLI-dispatched) — the brain's only way
  to write into `notifications`. `source_id` is the `plan_days.id` or `cook_sessions.id`
  driving this notification (see dedupe index below); omitted for `ritual_prompt`.
- Three trigger points, one per generation path:
  - **Morning nudge + prep reminders** — generated as a single batch immediately after
    ritual lock. When the worker finishes a `ritual` job's `set_plan` call, it enqueues
    **one** `notif_generate` job with `{week_id}` payload; the brain loops the week's
    days in one turn and calls `schedule_notification` once per day. The laptop is
    already awake for ritual, so this piggybacks for free.
  - **Ritual prompt** — doesn't need the brain. It's a fixed weekly beat ("time to plan
    the week"), not state-dependent content. `pg_cron` inserts the `notifications` row
    directly via SQL using static `copy_pack` text, on a fixed weekly schedule.
  - **Verdict actions** — `pg_cron` sweeps `plan_days` every ~15 min for rows whose date
    has passed 21:00 household-local with `status != 'skipped'` and no matching
    `verdicts` row, and inserts a `notif_generate` job per hit (mentions the dish by
    name, so it goes through the brain). Sweeping `plan_days` rather than `cook_sessions`
    is deliberate: `cook_sessions` has no FK to `plan_days` or `verdicts` (checked all six
    migrations — no join path exists), while `verdicts` already carries `plan_day_id`
    directly (`ios/Sous/CookModeView.swift` submits it from the view's `planDay` context).
    Sweeping `plan_days` also catches "never opened cook mode at all," not just "opened
    it but skipped the verdict."

**Stage 2 — Delivery.** Cloud-only, laptop-independent.

- `pg_cron` fires every ~1 min, calling a new Supabase Edge Function
  (`supabase/functions/deliver-notifications/`, Deno — no functions directory exists yet)
  via `net.http_post`.
- The function selects `notifications` where `status='scheduled' and send_at <= now()`,
  builds an ES256 APNs provider JWT from a `.p8` key held as an Edge Function secret,
  sends via APNs HTTP/2 to each `device_tokens` row belonging to the household's members,
  and updates `status`/`sent_at`/`error`.
- `pg_cron` and `pg_net` extensions are not enabled anywhere in this project yet — this
  phase enables them.

## Data model changes

New migration (`0007_...sql`, following the existing numbered pattern):

- `notifications`: add `kind text not null` (`morning_nudge` / `prep_reminder` /
  `ritual_prompt` / `verdict_action`), `sent_at timestamptz`, `error text`, and
  `source_id uuid` (nullable — the `plan_days.id` driving a `morning_nudge`/
  `prep_reminder`/`verdict_action`; null for `ritual_prompt`, which has no per-instance
  source row). Add a dedupe index:
  `unique (household_id, kind, source_id) where source_id is not null` so a retried
  `notif_generate` job can't double-schedule a notification for the same underlying
  event. Deliberately **not** keyed on `send_at::date` — a household can have both a
  `morning_nudge` and a same-day `verdict_action` (from yesterday's dinner, swept this
  morning) sharing a date, and a date-keyed dedupe conflates unrelated notifications.
- `jobs_write` RLS policy: add `notif_generate` to the allowed `kind` list. Inserts will
  actually come from the worker/`pg_cron` (service-role, bypasses RLS), so this isn't
  strictly required today — but `0005_jobs_allow_ritual_kind.sql` and
  `0006_jobs_allow_recipe_intake_kind.sql` are two prior instances of exactly this policy
  going stale until a real client hit it. Adding it now avoids a third occurrence.
- Enable `pg_cron` and `pg_net` extensions.
- `device_tokens` needs no schema changes — existing shape (`token` PK, `user_id`,
  `platform`) is sufficient.

## Components

**iOS**:
- Add `UIApplicationDelegateAdaptor` to `SousApp.swift` for
  `didRegisterForRemoteNotificationsWithDeviceToken`.
- Add `aps-environment: development` to `Sous.entitlements`.
- New minimal `NotificationsSettingsView`: a toggle that requests `UNUserNotificationCenter`
  authorization, calls `registerForRemoteNotifications()`, and on success upserts
  `device_tokens` directly (RLS already allows `user_id = auth.uid()` — same "app-owned
  column" pattern as shopping-item checkboxes; no brain/state_api involvement needed).
  Presented as a `.sheet` from `CounterView`'s toolbar, matching the existing
  WeekBoard/ShoppingList/Cookbook pattern. This stands in for the real onboarding
  permission flow until the Onboarding phase lands.

**Worker**:
- New `notif_generate` job handler in `main.py`'s dispatch.
- New prompt template in `worker/prompts/` for notification copy generation.
- New `schedule_notification` verb in `worker/state_api.py`.
- Ritual-completion hook enqueuing the batch `notif_generate` job (see Architecture).

**Supabase**:
- New `supabase/functions/deliver-notifications/` Edge Function.
- `.p8` APNs Auth Key, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID` stored as Edge
  Function secrets (never committed — same rule as `.env`).
- `pg_cron` schedules: delivery tick (~1 min), ritual-prompt weekly insert, verdict-action
  sweep (~15 min).

## Error handling

- **Delivery failures** (in the Edge Function): APNs `410 Unregistered` / `400
  BadDeviceToken` → delete the stale `device_tokens` row, mark the notification `failed`
  with `error` set. A household can have multiple devices; the `notifications` row is
  household-level, marked `sent` if *any* device succeeds, `failed` only if all fail.
  Rows stuck `scheduled` more than 24h past `send_at` (Edge Function down, key
  misconfigured) are force-marked `failed` with `error='expired'` on the next tick — a
  safety valve against infinite retry.
- **Generation failures**: `notif_generate` jobs reuse the existing `jobs` retry/requeue
  machinery (`attempts`, sweeper) already in place for every job kind — no new mechanism.

## Testing

- Unit tests for `schedule_notification` (state_api verb) and the `notif_generate` job
  handler/prompt rendering, matching existing patterns in `worker/tests/`.
- Edge Function JWT-building and payload-building logic tested as pure functions; the
  actual APNs HTTP call isn't meaningfully unit-testable.
- Real-device exit test (household rule: verify via real use, not sandboxes): manually
  insert a `notifications` row with `send_at = now()` via `psql` and confirm delivery to
  a real device within ~1 min of the cron tick. Separately confirm each real trigger path
  at least once: a real ritual lock produces the week's batch of `notif_generate` jobs,
  and a past `plan_days` row without a verdict gets picked up by the sweep.
