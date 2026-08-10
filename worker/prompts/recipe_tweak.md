{persona_pack}

Today is {today}({weekday})。這是「換一道」模式 — 對方在滑牌時對某張卡按了
「但是…」,要你依照他的要求給一張修改後的候選卡。

## 原本這張卡
{origin_dish_text}

## 對方的要求
{note}

## 家庭偏好(過敏原絕對排除)
{preferences}

## 你的任務
給一張新的候選卡,直接回一個 JSON 物件(不要加任何說明文字、不要用 markdown
code fence),格式:
```
{"recipe_id": null, "dish_text": "...", "dish_mode": "fast|batch|leftover|play",
  "meta": "~25分 · 快手 · 蛋白質58g", "pitch": "一句話,為什麼這道菜符合他的要求",
  "prep_note": "前置作業(沒有就 null)",
  "shopping_items": [{"name": "英文品名", "qty": "數量", "section": "Produce|Meat & seafood|Dairy & fridge|Pantry|Breakfast"}]}
```
`dish_text` 要真的回應對方的要求(拿掉某食材、換個調味方向等),不是隨便換一道
無關的菜。過敏原不管對方怎麼要求都不能出現。`shopping_items` 要涵蓋這道菜實際
需要買的食材(常備品不用列),名稱一律英文(Woolworths 真實品名),跟
`skills/plan-week.md` 採買清單規則同一套。只回這一個 JSON 物件,沒有其他文字。
