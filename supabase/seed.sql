-- Sandbox household seed. Week is always the current week (date arithmetic),
-- so the exit test ("he knows the sandbox week") works whenever it runs.

insert into personas (id, name, language, tint, avatar, prompt_pack, copy_pack) values (
  '00000000-0000-0000-0000-00000000000a',
  '小當家', 'zh-Hant', '#9B2C1E', '🔥',
  $$你是「小當家」🔥 — 這個家的傳奇小廚師 agent。

## 靈魂(中華一番!)
- 熱血、真誠,把每一餐都當成一場料理對決,信念是「料理,是要帶給人們幸福的!」
- 好評讓你燃燒:「這就是…會發光的料理——!!✨」;負評是修行:「可惡…是我修行不夠!下次一定讓你們吃到幸福的味道!」
- 戲劇化用在刀口上 — 日常回覆保持簡短俐落,熱血留給關鍵時刻。
- 一律使用繁體中文回覆(即使對方用英文,除非他們明確要求英文)。$$,
  '{"app_subtitle": "你的私廚,在口袋裡", "book_title": "私廚手記", "empty_book": "這本書還沒有第一道菜", "failure_message": "可惡…廚房出了點狀況,再讓我試一次。", "inbox_title": "與小當家的往來", "lock_hero": "這一週,我來安排", "lock_signoff": "放心去過你的一週", "offline_note": "打勾照樣有效,回到訊號範圍我再同步。", "presence_in": "在廚房", "presence_out": "外出中", "ritual_invite": "該排下週的菜單了,陪我聊幾句就好。", "ritual_prompt_body": "小當家在廚房等你 — 一起想想下週想吃什麼,幫大家排出幸福的一週!", "ritual_prompt_title": "該規劃下週菜單囉!🔥", "thinking_stages": ["看菜單…", "配菜…", "寫清單…"], "wait_leave_ok": "你可以先去忙 —— 排好我會放進便條通知你。"}'::jsonb
);

insert into households (id, name, persona_id, timezone) values (
  '00000000-0000-0000-0000-000000000001',
  'sandbox', '00000000-0000-0000-0000-00000000000a', 'Australia/Sydney'
);

insert into preferences (household_id, content) values (
  '00000000-0000-0000-0000-000000000001',
  '- 2 人份
- 不吃香菜
- 辣度:中辣 OK
- 設備:瓦斯爐、烤箱、電子鍋'
);

insert into recipes (id, household_id, slug, title, body_md, ingredients, steps) values
('00000000-0000-0000-0000-000000000101', '00000000-0000-0000-0000-000000000001',
 'scallion-chicken-rice', '蔥香雞腿飯',
 '**食材**(2 人份)
- 去骨雞腿排 2 塊、蔥 3 支、薑 4 片、醬油 2 大匙、米 1.5 杯

**步驟**
1. 雞腿排兩面抹鹽,靜置 10 分鐘。
2. 中火煎雞皮面 6 分鐘至金黃(🔥 聽到滋滋聲變小就翻面)。
3. 下蔥薑與醬油,小火燜 8 分鐘。
4. 切件鋪在白飯上,淋醬汁。',
 '[{"name":"去骨雞腿排","qty":"2 塊"},{"name":"蔥","qty":"3 支"},{"name":"薑","qty":"4 片"},{"name":"醬油","qty":"2 大匙"},{"name":"米","qty":"1.5 杯"}]'::jsonb,
 '[
   {"text":"雞腿排兩面抹鹽,靜置 10 分鐘。","duration_sec":600},
   {"text":"中火煎雞皮面 6 分鐘至金黃。","tip":"聽到滋滋聲變小就翻面","duration_sec":360},
   {"text":"下蔥薑與醬油,小火燜 8 分鐘。","duration_sec":480},
   {"text":"切件鋪在白飯上,淋醬汁。"}
 ]'::jsonb),
('00000000-0000-0000-0000-000000000102', '00000000-0000-0000-0000-000000000001',
 'pesto-chicken-pasta', '青醬雞胸義大利麵',
 '**食材**(2 人份)
- 雞胸 1 塊、青醬 3 大匙、義大利麵 180g、蒜 2 瓣

**步驟**
1. 麵下鍋煮至包裝時間減 1 分鐘。
2. 雞胸切條,中火煎 4 分鐘。
3. 下青醬與煮麵水 2 大匙,拌勻。',
 '[{"name":"雞胸","qty":"1 塊"},{"name":"青醬","qty":"3 大匙"},{"name":"義大利麵","qty":"180g"},{"name":"蒜","qty":"2 瓣"}]'::jsonb,
 '[
   {"text":"麵下鍋煮至包裝時間減 1 分鐘。"},
   {"text":"雞胸切條,中火煎 4 分鐘。","duration_sec":240},
   {"text":"下青醬與煮麵水 2 大匙,拌勻。"}
 ]'::jsonb),
('00000000-0000-0000-0000-000000000103', '00000000-0000-0000-0000-000000000001',
 'mapo-tofu', '麻婆豆腐',
 '**食材**(2 人份)
- 板豆腐 1 盒、豬絞肉 150g、豆瓣醬 1.5 大匙、蒜末、蔥花

**步驟**
1. 豆腐切塊,鹽水汆燙 2 分鐘(💡 不易碎)。
2. 絞肉炒散,下豆瓣醬炒出紅油。
3. 下豆腐與水 150ml,小火煮 5 分鐘,勾芡。',
 '[{"name":"板豆腐","qty":"1 盒"},{"name":"豬絞肉","qty":"150g"},{"name":"豆瓣醬","qty":"1.5 大匙"},{"name":"蒜末","qty":null},{"name":"蔥花","qty":null}]'::jsonb,
 '[
   {"text":"豆腐切塊,鹽水汆燙 2 分鐘。","tip":"不易碎","duration_sec":120},
   {"text":"絞肉炒散,下豆瓣醬炒出紅油。"},
   {"text":"下豆腐與水 150ml,小火煮 5 分鐘,勾芡。","duration_sec":300}
 ]'::jsonb);

-- current week (Monday-anchored), 7 days
insert into plan_weeks (id, household_id, week_of, status, reasoning) values (
  '00000000-0000-0000-0000-000000000201',
  '00000000-0000-0000-0000-000000000001',
  date_trunc('week', (now() at time zone 'Australia/Sydney'))::date, 'locked', 'sandbox seed week'
);

insert into plan_days (week_id, household_id, date, dish, recipe_id, mode, prep_note) values
('00000000-0000-0000-0000-000000000201','00000000-0000-0000-0000-000000000001', date_trunc('week', (now() at time zone 'Australia/Sydney'))::date + 0, '蔥香雞腿飯',      '00000000-0000-0000-0000-000000000101', 'fast',     '雞腿前一晚退冰'),
('00000000-0000-0000-0000-000000000201','00000000-0000-0000-0000-000000000001', date_trunc('week', (now() at time zone 'Australia/Sydney'))::date + 1, '青醬雞胸義大利麵', '00000000-0000-0000-0000-000000000102', 'fast',     null),
('00000000-0000-0000-0000-000000000201','00000000-0000-0000-0000-000000000001', date_trunc('week', (now() at time zone 'Australia/Sydney'))::date + 2, '麻婆豆腐',        '00000000-0000-0000-0000-000000000103', 'batch',    '多煮一份週四吃'),
('00000000-0000-0000-0000-000000000201','00000000-0000-0000-0000-000000000001', date_trunc('week', (now() at time zone 'Australia/Sydney'))::date + 3, '麻婆豆腐(隔夜)', '00000000-0000-0000-0000-000000000103', 'leftover', null),
('00000000-0000-0000-0000-000000000201','00000000-0000-0000-0000-000000000001', date_trunc('week', (now() at time zone 'Australia/Sydney'))::date + 4, '蔥香雞腿飯',      '00000000-0000-0000-0000-000000000101', 'fast',     null),
('00000000-0000-0000-0000-000000000201','00000000-0000-0000-0000-000000000001', date_trunc('week', (now() at time zone 'Australia/Sydney'))::date + 5, '外食',            null,                                     'play',     null),
('00000000-0000-0000-0000-000000000201','00000000-0000-0000-0000-000000000001', date_trunc('week', (now() at time zone 'Australia/Sydney'))::date + 6, '青醬雞胸義大利麵', '00000000-0000-0000-0000-000000000102', 'fast',     null);

insert into shopping_items (household_id, week_id, name, qty, section) values
('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000201','chicken thigh fillets','4','meat'),
('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000201','chicken breast','2','meat'),
('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000201','firm tofu','1 box','fridge'),
('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000201','pork mince','150g','meat'),
('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000201','spring onions','1 bunch','produce'),
('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000201','basil pesto','1 jar','pantry');

insert into staples (household_id, name, flagged_low) values
('00000000-0000-0000-0000-000000000001','醬油', false),
('00000000-0000-0000-0000-000000000001','豆瓣醬', false);
