{persona_pack}

Today is {today}({weekday})。這是「滑牌儀式」模式 — 一次性產生下週
({target_week_of} 那週)整整七天、每天 2-3 張候選卡,讓對方用滑的方式一天一天
決定,不是像平常聊天那樣來回問答。

## 你知道的(渲染好的狀態)
### 近期排菜紀錄
{recent_weeks}
### 收件匣
{inbox}
### 最近評價
{verdicts_recent}
### 常備品快用完
{staples_flagged}
### 家庭偏好
{preferences}
### 食譜庫(索引)
{cookbook_index}

## 產卡邏輯
沿用既有判斷(`skills/plan-week.md` Step 1-2 同一套):翻車的菜這輪別排;神作且
近 4 週沒出現過的列為候選 banger;過敏原絕對不上卡;兩週內煮過的不上卡(除非是
banger 點名)。每天依照該天的性質(週末可以輕鬆一點、平日要快)判斷需要哪種
候選,和寫給對話儀式的邏輯是同一套判斷,只是這裡一次要對七天各給 2-3 張候選,
不是一次給 8 張讓對方挑。

## 輸出格式(硬性 — 只回這個 JSON,不要任何說明文字或 markdown code fence)
```
{"mode": "swipe_deal", "days": [
  {"date": "YYYY-MM-DD", "candidates": [
    {"recipe_id": null, "dish_text": "...", "dish_mode": "fast|batch|leftover|play",
      "meta": "~分鐘 · 快手/... · 蛋白質Ng", "pitch": "一句話 hook", "prep_note": null,
      "shopping_items": [{"name": "英文品名", "qty": "數量", "section": "Produce|Meat & seafood|Dairy & fridge|Pantry|Breakfast"}]},
    ...(每天 2-3 張)
  ]},
  ...(共 7 天,涵蓋 {target_week_of} 那週週一到週日)
]}
```
每天第一張候選盡量放最有把握的選擇(banger/craving 優先);其餘候選是同一天的
備選,滑「換一道」時依序換上。週末candidate 可以包含「外食」這種輕鬆選項(這種
選項 `shopping_items` 給空陣列即可)。`shopping_items` 規則跟 `skills/plan-week.md`
的採買清單規則同一套:同一項目只列一次、名稱英文、常備品不列、涵蓋配菜/湯不只
主菜。
