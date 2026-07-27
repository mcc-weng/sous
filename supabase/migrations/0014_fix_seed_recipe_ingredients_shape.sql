-- supabase/migrations/0014_fix_seed_recipe_ingredients_shape.sql
-- seed.sql's 3 hand-written recipes (蔥香雞腿飯/青醬雞胸義大利麵/麻婆豆腐) stored
-- `ingredients` as a plain string array, not the {name, qty} object shape every other
-- write path (state_api.py's save_recipe verb) has always enforced. Codable's array
-- decode is all-or-nothing: one malformed row breaks the *entire* cookbook fetch, not
-- just that row — found live during M2c2's real-device exit check (2026-07-27), where
-- the cookbook sheet silently showed zero recipes (including two correctly-shaped
-- recipe_intake results) because of these three rows. Root cause was stale seed data,
-- not the Swift model or the write path.
--
-- Also backfills `steps` (previously an empty array, decodes fine but leaves cook mode
-- with nothing to show — RecipeStep indexing on an empty array would be a real crash
-- risk the moment someone tries cook mode on one of these). Step text is transcribed
-- from each recipe's own existing body_md, not new content.
update recipes set ingredients = '[{"name":"去骨雞腿排","qty":"2 塊"},{"name":"蔥","qty":"3 支"},{"name":"薑","qty":"4 片"},{"name":"醬油","qty":"2 大匙"},{"name":"米","qty":"1.5 杯"}]'::jsonb,
  steps = '[
    {"text":"雞腿排兩面抹鹽,靜置 10 分鐘。","duration_sec":600},
    {"text":"中火煎雞皮面 6 分鐘至金黃。","tip":"聽到滋滋聲變小就翻面","duration_sec":360},
    {"text":"下蔥薑與醬油,小火燜 8 分鐘。","duration_sec":480},
    {"text":"切件鋪在白飯上,淋醬汁。"}
  ]'::jsonb
  where slug = 'scallion-chicken-rice';
update recipes set ingredients = '[{"name":"雞胸","qty":"1 塊"},{"name":"青醬","qty":"3 大匙"},{"name":"義大利麵","qty":"180g"},{"name":"蒜","qty":"2 瓣"}]'::jsonb,
  steps = '[
    {"text":"麵下鍋煮至包裝時間減 1 分鐘。"},
    {"text":"雞胸切條,中火煎 4 分鐘。","duration_sec":240},
    {"text":"下青醬與煮麵水 2 大匙,拌勻。"}
  ]'::jsonb
  where slug = 'pesto-chicken-pasta';
update recipes set ingredients = '[{"name":"板豆腐","qty":"1 盒"},{"name":"豬絞肉","qty":"150g"},{"name":"豆瓣醬","qty":"1.5 大匙"},{"name":"蒜末","qty":null},{"name":"蔥花","qty":null}]'::jsonb,
  steps = '[
    {"text":"豆腐切塊,鹽水汆燙 2 分鐘。","tip":"不易碎","duration_sec":120},
    {"text":"絞肉炒散,下豆瓣醬炒出紅油。"},
    {"text":"下豆腐與水 150ml,小火煮 5 分鐘,勾芡。","duration_sec":300}
  ]'::jsonb
  where slug = 'mapo-tofu';
