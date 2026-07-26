-- Vault secrets the delivery-tick cron job (migration 0008) reads via
-- vault.decrypted_secrets, per Supabase's documented pattern
-- (docs/guides/functions/schedule-functions). Values match the project URL and anon
-- key already committed in ios/Sous/Config.swift -- the anon key is designed to be
-- public/embeddable (protected by RLS, not secrecy), so committing it here is no
-- different from its existing use in the iOS client.
select vault.create_secret('https://ftobrcxtbtdjgrrkavzb.supabase.co', 'project_url');
select vault.create_secret(
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZ0b2JyY3h0YnRkamdycmthdnpiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODM4MjQyNDksImV4cCI6MjA5OTQwMDI0OX0.kQCCdK4tAijGApu9rGkq6A9DHsMLn6advJy7wgwFYOY',
  'publishable_key'
);
