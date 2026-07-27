-- supabase/migrations/0015_presence_cook_count_copy.sql
-- Presence header (CounterView.swift) has shown hardcoded English "chef in"/"chef out"
-- since M1 — never routed through copy_pack, in letter conflict with the
-- persona-discipline rule (CLAUDE.md: "zero hardcoded persona strings in app or
-- prompts"). Separately, cook-mode completion gains a per-dish cook-count celebration
-- at milestone counts (docs/superpowers/specs/2026-07-27-presence-copy-cook-counts-design.md).
-- Merge rather than overwrite so existing keys survive, matching 0007/0013's pattern.
update personas set copy_pack = copy_pack || jsonb_build_object(
  'presence_in', '在廚房',
  'presence_out', '外出中',
  'cook_milestone_reaction', '哇,這是你第 {n} 次做這道菜了!越來越上手了呢 🔥'
);
