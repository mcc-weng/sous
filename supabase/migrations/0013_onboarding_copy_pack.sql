-- supabase/migrations/0013_onboarding_copy_pack.sql
-- Onboarding wizard framing copy (docs/superpowers/specs/2026-07-26-m3-onboarding-design.md)
-- — the wizard itself is a native SwiftUI form with no brain involved, but every piece
-- of user-facing text still flows through copy_pack per the persona-discipline rule
-- (CLAUDE.md: "zero hardcoded persona strings in app or prompts"). Merge rather than
-- overwrite so existing keys (failure_message, ritual_prompt_title, ritual_prompt_body)
-- survive, matching 0007's pattern.
update personas set copy_pack = copy_pack || jsonb_build_object(
  'onboarding_intro', '歡迎加入我的廚房!先讓我認識你一下,幾個小問題,一下就好 🔥',
  'onboarding_q_allergies', '你有沒有什麼過敏原,我要小心別放進菜單裡?',
  'onboarding_q_dislikes', '有沒有什麼你不喜歡吃的?我幫你避開。',
  'onboarding_q_spice', '口味吃辣嗎?',
  'onboarding_q_equipment', '家裡有哪些廚房設備?',
  'onboarding_q_household_size', '平常煮飯大概幾人份?',
  'onboarding_complete', '都記住了!以後煮菜通通照你的喜好來,想到什麼隨時再跟我說一聲 🔥'
);
