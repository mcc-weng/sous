-- supabase/migrations/0007_notifications_apns_pipeline.sql
-- M3 APNs pipeline (docs/specs/2026-07-25-m3-apns-pipeline-design.md): schema for the
-- notif_generate -> notifications -> Edge Function -> APNs pipeline, plus the two
-- notification triggers that need no Edge Function to exist yet (ritual_prompt is
-- static copy; verdict_action just enqueues a notif_generate job).

create extension if not exists pg_cron;
create extension if not exists pg_net;

alter table notifications
  add column kind text not null
    check (kind in ('morning_nudge','prep_reminder','ritual_prompt','verdict_action')),
  add column sent_at   timestamptz,
  add column error     text,
  add column source_id uuid;

-- Not keyed on send_at::date: a household can have both a morning_nudge and a
-- same-day verdict_action (from yesterday's dinner, swept this morning) sharing a
-- date, and a date-keyed dedupe would conflate unrelated notifications. ritual_prompt
-- has no source_id (see notifications_read below for its own dedupe strategy).
create unique index notifications_dedupe on notifications (household_id, kind, source_id)
  where source_id is not null;

-- notif_generate jobs are inserted by the worker (ritual hook) and pg_cron (verdict
-- sweep), both via the service-role connection which bypasses RLS — so this isn't
-- strictly required today. But 0005_jobs_allow_ritual_kind.sql and
-- 0006_jobs_allow_recipe_intake_kind.sql are two prior instances of exactly this policy
-- going stale until a real client hit it. Adding it now avoids a third occurrence.
alter policy jobs_write on jobs
  with check (is_member(household_id) and kind in ('chat','ritual','recipe_intake','notif_generate'));

-- Existing personas need the two new copy_pack keys the ritual-prompt sweep reads.
-- Merge rather than overwrite so failure_message and any other existing keys survive.
update personas set copy_pack = copy_pack || jsonb_build_object(
  'ritual_prompt_title', '該規劃下週菜單囉!🔥',
  'ritual_prompt_body', '小當家在廚房等你 — 一起想想下週想吃什麼,幫大家排出幸福的一週!'
);

-- Fires every 15 min; the not-exists guard stops it from re-inserting on every tick
-- during the whole 17:00-17:59 household-local hour (ritual_prompt has no source_id,
-- so it isn't covered by notifications_dedupe above).
select cron.schedule(
  'ritual-prompt-sweep',
  '*/15 * * * *',
  $$
  insert into notifications (household_id, send_at, kind, title, body)
  select h.id, now(), 'ritual_prompt',
         p.copy_pack ->> 'ritual_prompt_title', p.copy_pack ->> 'ritual_prompt_body'
  from households h join personas p on p.id = h.persona_id
  where extract(dow from (now() at time zone h.timezone)) = 0   -- Sunday, household-local
    and extract(hour from (now() at time zone h.timezone)) = 17
    and not exists (
      select 1 from notifications n
      where n.household_id = h.id and n.kind = 'ritual_prompt'
        and n.send_at > now() - interval '20 hours'
    )
  $$
);

-- Sweeps plan_days rather than cook_sessions: cook_sessions has no FK to plan_days or
-- verdicts (checked all six prior migrations), while verdicts already carries
-- plan_day_id directly (ios/Sous/CookModeView.swift submits it from the view's planDay
-- context). This also catches "never opened cook mode at all," not just "opened it but
-- skipped the verdict prompt."
select cron.schedule(
  'verdict-action-sweep',
  '*/15 * * * *',
  $$
  insert into jobs (household_id, kind, payload)
  select pd.household_id, 'notif_generate',
         jsonb_build_object('notif_kind', 'verdict_action', 'plan_day_id', pd.id::text)
  from plan_days pd join households h on h.id = pd.household_id
  where pd.status != 'skipped'
    and (now() at time zone h.timezone)::date >= pd.date
    and extract(hour from (now() at time zone h.timezone)) >= 21
    and not exists (select 1 from verdicts v where v.plan_day_id = pd.id)
    and not exists (
      select 1 from jobs j
      where j.household_id = pd.household_id and j.kind = 'notif_generate'
        and j.payload ->> 'notif_kind' = 'verdict_action'
        and j.payload ->> 'plan_day_id' = pd.id::text
    )
  $$
);
