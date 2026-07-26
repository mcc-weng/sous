-- supabase/migrations/0012_preferences_write_policy.sql
-- preferences has been read-only from the app's perspective since 0002_rls.sql — the
-- one household that exists today got its `content` by hand via seed.sql, never
-- through a real write path. M3 onboarding
-- (docs/superpowers/specs/2026-07-26-m3-onboarding-design.md) needs the wizard to
-- upsert preferences directly from iOS on completion, for an instant completion feel
-- with no job/brain round-trip — mirroring the "for all" grant already used for
-- household-owned data (cook_rw, verdict_rw in 0002_rls.sql) rather than a narrower
-- single-command policy.
create policy preferences_write on preferences for all to authenticated
  using (is_member(household_id)) with check (is_member(household_id));
