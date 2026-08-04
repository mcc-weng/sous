-- supabase/migrations/0018_recipe_servings.sql
-- Pass 1b (Recipe Detail redesign): the base serving count the servings stepper
-- rescales ingredient quantities from/to. Backfilled to 2 for existing rows because
-- recipe_intake.md already normalizes every recipe to 份量換算到 2 人份 today — this is
-- an accurate fact about existing data, not a guess. See
-- docs/superpowers/specs/2026-08-04-m3-visual-restyle-pass1b-recipe-detail-design.md.

alter table recipes add column servings smallint not null default 2;
