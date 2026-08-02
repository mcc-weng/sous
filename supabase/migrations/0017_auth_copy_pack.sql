-- supabase/migrations/0017_auth_copy_pack.sql
-- Foundation correction: Task 4's Auth screen restyle (paper design) left two
-- persona-voiced strings hardcoded in AuthView.swift instead of routed through
-- copy_pack, unlike the other 11 keys added in 0016_paper_design_copy_pack.sql.
-- Closes that gap before Task 5+ copies the same mistake into more screens.

update personas set copy_pack = copy_pack || jsonb_build_object(
  'auth_privacy_note', '我們只存你家的口味與菜單',
  'auth_promise', '小當家會記住你家的口味、排好這一週,然後在爐邊陪你把它煮出來。'
) where id = '00000000-0000-0000-0000-00000000000a';
