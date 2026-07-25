-- supabase/migrations/0008_delivery_tick_cron.sql
-- Delivery tick: fires every ~1 min, calls deliver-notifications via pg_net, following
-- Supabase's documented pattern (docs/guides/functions/schedule-functions) exactly —
-- project_url and publishable_key must already exist in Vault (see above) or every
-- tick's net.http_post silently no-ops (its errors don't surface anywhere).
select cron.schedule(
  'delivery-tick',
  '* * * * *',
  $$
  select net.http_post(
      url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url')
             || '/functions/v1/deliver-notifications',
      headers := jsonb_build_object(
        'Content-type', 'application/json',
        'apikey', (select decrypted_secret from vault.decrypted_secrets where name = 'publishable_key')
      ),
      body := '{}'::jsonb
  ) as request_id;
  $$
);
