-- Final whole-branch review finding: the verdict-action sweep had no lower date
-- bound, so its first run enqueues a notif_generate job for EVERY historical
-- non-skipped unverdicted plan_day, not just recent ones. Confirmed live: this
-- already fired once for real, sending 13 "how was this dish?" pushes for dishes
-- going back to mid-July. Harmless this time (one household, real content), but a
-- future household without a controlled backfill would get the same full-history
-- burst on its first sweep tick. Adding a 2-day floor so only recently-passed days
-- are ever swept.
select cron.unschedule('verdict-action-sweep');

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
    and (now() at time zone h.timezone)::date - pd.date <= 2
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
