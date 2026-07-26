-- Fix: the delivery-tick cron job (0008) sent only an `apikey` header, matching
-- Supabase's documented example verbatim -- but this project's function gateway
-- rejects calls with 401 UNAUTHORIZED_NO_AUTH_HEADER unless an `Authorization: Bearer`
-- header is also present (confirmed live via net._http_response during the manual
-- delivery spike, 2026-07-25 -- every prior tick returned this exact error). Adding
-- both headers, the standard pattern for anon-key-authenticated Supabase requests.
select cron.unschedule('delivery-tick');

select cron.schedule(
  'delivery-tick',
  '* * * * *',
  $$
  select net.http_post(
      url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url')
             || '/functions/v1/deliver-notifications',
      headers := jsonb_build_object(
        'Content-type', 'application/json',
        'apikey', (select decrypted_secret from vault.decrypted_secrets where name = 'publishable_key'),
        'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'publishable_key')
      ),
      body := '{}'::jsonb
  ) as request_id;
  $$
);
