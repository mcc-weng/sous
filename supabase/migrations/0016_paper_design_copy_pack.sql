-- supabase/migrations/0016_paper_design_copy_pack.sql
-- M3 visual restyle (Pass 1a): new copy_pack keys for the 書與灶 paper design,
-- and the seal-red persona tint. Does not touch presence_in/presence_out — kept
-- per docs/superpowers/specs/2026-08-02-m3-visual-restyle-design.md §3.

update personas set tint = '#9B2C1E' where id = '00000000-0000-0000-0000-00000000000a';

update personas set copy_pack = copy_pack || jsonb_build_object(
  'app_subtitle', '你的私廚,在口袋裡',
  'book_title', '私廚手記',
  'inbox_title', '與小當家的往來',
  'ritual_invite', '該排下週的菜單了,陪我聊幾句就好。',
  'thinking_stages', jsonb_build_array('看菜單…', '配菜…', '寫清單…'),
  'wait_leave_ok', '你可以先去忙 —— 排好我會放進便條通知你。',
  'lock_hero', '這一週,我來安排',
  'lock_signoff', '放心去過你的一週',
  'failure_message', '可惡…廚房出了點狀況,再讓我試一次。',
  'offline_note', '打勾照樣有效,回到訊號範圍我再同步。',
  'empty_book', '這本書還沒有第一道菜'
) where id = '00000000-0000-0000-0000-00000000000a';
