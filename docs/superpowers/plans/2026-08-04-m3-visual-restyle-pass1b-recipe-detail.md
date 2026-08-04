# M3 Visual Restyle — Pass 1b: Recipe Detail (D1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restyle `RecipeDetailView` to the 書與灶 paper design system and give it the
real (if new) servings-rescale, unit-toggle, photo-carousel, and print/copy features
`docs/superpowers/specs/2026-08-04-m3-visual-restyle-pass1b-recipe-detail-design.md`
scoped, none of which the current plain-`GroupBox` view has.

**Architecture:** A `recipes.servings` column plus optional structured
`qty_value`/`qty_unit` fields on each ingredient (backfilled/populated by
`worker/prompts/recipe_intake.md` going forward, `nil` on old recipes — no backfill of
the per-ingredient values) feed a new pure-logic file, `RecipeScalingLogic.swift`, that
does all rescale/unit-conversion math. `RecipeDetailView` wires that logic to a local
servings-stepper `@State` and unit-toggle `@State` — nothing here writes back to the
server; it's a display-time computation over data already on the `Recipe`/`Ingredient`
the view already has. The photo carousel ships as a placeholder-only component this
pass (real data — `cook_sessions.photo_url` — doesn't exist until Pass 1c).

**Tech Stack:** SwiftUI (iOS 17+, existing project), XCTest, Python 3.11+/psycopg3 +
pytest (worker), Supabase Postgres migration (SQL). No new dependencies — `ShareLink`
(native SwiftUI, iOS 16+) covers the print icon without a `UIActivityViewController`
wrapper.

## Global Constraints

- **Paper-first**: `PaperTokens.stock` background, no dark mode branch — D1 isn't one of
  Cook Mode's three dark screens. See parent design spec §3b.
- **No border radius anywhere** — slips, cards, buttons, stamps are square.
- **Persona-tintable**: the seal/accent colour is `model.personaTint`
  (`AppModel.swift`), never a hardcoded hex. `PaperTokens.sealFallback` is only
  `AppModel`'s own starting/fallback value — views read `model.personaTint`.
- **Traditional Chinese primary**: `serifFontName(bundled: FontBook.isSerifBundled)` for
  dish names/verdicts/body, `sansFontName(bundled: FontBook.isSansBundled)` for
  interface chrome/labels — both from `DesignTokens.swift`, already bundled (Pass 1a
  Task 3).
- **copy_pack discipline applies to persona voice, not generic UI chrome.** Established
  precedent (`CookbookView.swift`'s hardcoded "搜尋食譜", "沒有符合的食譜", filter chip
  labels): plain interface labels that aren't the chef "speaking" can be hardcoded
  Chinese strings directly. 拷貝/列印/公制/英制/份量 etc. in this plan follow that same
  precedent — no new `copy_pack` migration needed for them.
- Minimum touch target 44pt.
- **Real device target**: iPhone 13 mini, 375pt logical width — verify every new layout
  actually fits there, not just at the simulator's default 402pt.
- Design reference: `design_handoff_sous_m3/README.md` §D1 and the live canvas
  `design_handoff_sous_m3/Sous App v2.dc.html` (lines ~481–558) — the canvas is the
  higher-fidelity source when the README's prose is ambiguous.
- Build/test command shape (iOS): `cd ios && xcodegen generate && xcodebuild ... -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' ...`
  — always run `xcodegen generate` first; this project's `.xcodeproj` is generated from
  `project.yml`.
- Build/test command shape (worker): `cd worker && uv run pytest tests/<file>.py -v`.

---

## Task 1: Migration — `recipes.servings`

**Files:**
- Create: `supabase/migrations/0018_recipe_servings.sql`

**Interfaces:**
- Produces: `recipes.servings smallint not null default 2` — every existing row gets `2`
  automatically (Postgres backfills `ADD COLUMN ... DEFAULT` for existing rows), which is
  factually accurate today since `recipe_intake.md` already normalizes every recipe to
  2人份 (see design spec's "backfills cleanly" note).
- Consumes: nothing.

- [ ] **Step 1: Write the migration**

```sql
-- supabase/migrations/0018_recipe_servings.sql
-- Pass 1b (Recipe Detail redesign): the base serving count the servings stepper
-- rescales ingredient quantities from/to. Backfilled to 2 for existing rows because
-- recipe_intake.md already normalizes every recipe to 份量換算到 2 人份 today — this is
-- an accurate fact about existing data, not a guess. See
-- docs/superpowers/specs/2026-08-04-m3-visual-restyle-pass1b-recipe-detail-design.md.

alter table recipes add column servings smallint not null default 2;
```

- [ ] **Step 2: Apply locally and verify**

Run: `supabase db reset`

Expected: migration applies cleanly, seed re-runs after it.

Run:
```bash
docker exec -it $(docker ps -qf "name=supabase_db") psql -U postgres -c \
  "select title, servings from recipes limit 5;"
```

Expected: `servings` column exists, value `2` for every seeded recipe.

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/0018_recipe_servings.sql
git commit -m "feat(db): add recipes.servings for Pass 1b servings rescale"
```

---

## Task 2: `worker/state_api.py` — `save_recipe` gains `servings`

**Files:**
- Modify: `worker/state_api.py:237-264` (`save_recipe` function), `:372-380` (`save-recipe`
  CLI subparser), `:423-430` (`save-recipe` dispatch)
- Test: `worker/tests/test_state_api.py`

**Interfaces:**
- Consumes: `recipes.servings` column (Task 1).
- Produces: `save_recipe(conn, household_id, title, ingredients, steps, source_block, body_md="", slug=None, servings=2) -> dict` —
  same return shape as today (`{"ok", "id", "slug", "created"}`), `servings` stored
  alongside the existing columns. Raises `ValueError` (message contains `"servings"`)
  when `servings < 1`.

- [ ] **Step 1: Write the failing tests**

Append to `worker/tests/test_state_api.py`, directly after `test_save_recipe_inserts_new`
(after line 484):

```python
def test_save_recipe_defaults_servings_to_two(conn, api_hid):
    state_api.save_recipe(
        conn, api_hid, title="蒜炒飯", slug="garlic-rice",
        ingredients=[{"name": "rice", "qty": "2 cups"}],
        steps=[{"text": "fry it"}], source_block="orig",
    )
    row = conn.execute(
        "select servings from recipes where household_id = %s and slug = %s",
        (api_hid, "garlic-rice"),
    ).fetchone()
    assert row[0] == 2


def test_save_recipe_stores_explicit_servings(conn, api_hid):
    state_api.save_recipe(
        conn, api_hid, title="紅燒獅子頭", slug="lion-head",
        ingredients=[{"name": "pork", "qty": "500g"}],
        steps=[{"text": "simmer it"}], source_block="orig", servings=4,
    )
    row = conn.execute(
        "select servings from recipes where household_id = %s and slug = %s",
        (api_hid, "lion-head"),
    ).fetchone()
    assert row[0] == 4


def test_save_recipe_rejects_invalid_servings(conn, api_hid):
    with pytest.raises(ValueError, match="servings"):
        state_api.save_recipe(
            conn, api_hid, title="x", slug="x",
            ingredients=[{"name": "a"}], steps=[{"text": "a"}],
            source_block="s", servings=0,
        )
```

Also append, directly after `test_cli_save_recipe` (after line 555):

```python
def test_cli_save_recipe_passes_servings(conn, api_hid):
    ingredients_json = json.dumps([{"name": "rice", "qty": "2 cups"}])
    steps_json = json.dumps([{"text": "fry it"}])
    proc = _run_cli(
        ["save-recipe", "--title", "蒜炒飯", "--slug", "garlic-rice-2",
         "--source-block", "orig", "--ingredients", ingredients_json,
         "--steps", steps_json, "--servings", "6"],
        api_hid,
    )
    assert proc.returncode == 0, proc.stderr
    out = json.loads(proc.stdout)
    assert out["ok"] is True
    row = conn.execute(
        "select servings from recipes where household_id = %s and slug = %s",
        (api_hid, "garlic-rice-2"),
    ).fetchone()
    assert row[0] == 6
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd worker && uv run pytest tests/test_state_api.py -k "servings" -v`

Expected: FAIL — `save_recipe() got an unexpected keyword argument 'servings'` /
`unrecognized arguments: --servings`.

- [ ] **Step 3: Implement — `save_recipe` function**

Replace `worker/state_api.py:237-264`:

```python
def save_recipe(conn, household_id: str, title: str, ingredients: list, steps: list,
                source_block: str, body_md: str = "", slug: str | None = None,
                servings: int = 2) -> dict:
    if not ingredients:
        raise ValueError("ingredients must be a non-empty list")
    for ing in ingredients:
        if "name" not in ing:
            raise ValueError('each ingredient needs a "name"')
    if not steps:
        raise ValueError("steps must be a non-empty list")
    for st in steps:
        if "text" not in st:
            raise ValueError('each step needs "text"')
    if servings < 1:
        raise ValueError("servings must be at least 1")
    resolved_slug = _slugify(slug or title)
    if not resolved_slug:
        raise ValueError("empty slug after deriving from title — pass an explicit "
                         "--slug for non-Latin titles")
    row = conn.execute(
        "insert into recipes (household_id, slug, title, source_block, body_md, "
        "ingredients, steps, servings) values (%s, %s, %s, %s, %s, %s, %s, %s) "
        "on conflict (household_id, slug) do update set "
        "title = excluded.title, source_block = excluded.source_block, "
        "body_md = excluded.body_md, ingredients = excluded.ingredients, "
        "steps = excluded.steps, servings = excluded.servings "
        "returning id::text, (xmax = 0) as inserted",
        (household_id, resolved_slug, title, source_block, body_md,
         Jsonb(ingredients), Jsonb(steps), servings),
    ).fetchone()
    return {"ok": True, "id": row[0], "slug": resolved_slug, "created": row[1]}
```

- [ ] **Step 4: Implement — CLI subparser**

In `worker/state_api.py`, after the existing `sr.add_argument("--steps", ...)` at line
380, add:

```python
    sr.add_argument("--servings", type=int, default=2,
                    help="base serving count this recipe's quantities assume (default 2)")
```

- [ ] **Step 5: Implement — CLI dispatch**

Replace `worker/state_api.py:429-430`:

```python
        return save_recipe(conn, household_id, args.title, ingredients, steps,
                           args.source_block, body_md=args.body_md, slug=args.slug,
                           servings=args.servings)
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd worker && uv run pytest tests/test_state_api.py -v`

Expected: PASS, full file (no regressions in the other `save_recipe`/CLI tests).

- [ ] **Step 7: Commit**

```bash
git add worker/state_api.py worker/tests/test_state_api.py
git commit -m "feat(worker): save_recipe accepts servings, defaults to 2"
```

---

## Task 3: `worker/prompts/recipe_intake.md` — structured ingredient quantities

**Files:**
- Modify: `worker/prompts/recipe_intake.md` (lines 24, 31)
- Test: `worker/tests/test_prompts.py`

**Interfaces:**
- Consumes: `save_recipe`'s `servings` param and `qty_value`/`qty_unit` ingredient keys
  (Task 2; `qty_value`/`qty_unit` were already accepted implicitly since `save_recipe`
  only validates `"name"` is present on each ingredient dict — any extra keys pass
  through to the JSONB column untouched).
- Produces: prompt instructs the brain to emit `qty_value`/`qty_unit` when a quantity
  parses cleanly, and to pass `--servings` explicitly.

- [ ] **Step 1: Write the failing test**

Append to `worker/tests/test_prompts.py`, directly after
`test_recipe_intake_prompt_keeps_all_placeholders` (end of file):

```python
def test_recipe_intake_prompt_documents_structured_quantities():
    assert "qty_value" in RECIPE_INTAKE_PROMPT
    assert "qty_unit" in RECIPE_INTAKE_PROMPT


def test_recipe_intake_prompt_documents_servings_flag():
    assert "--servings" in RECIPE_INTAKE_PROMPT
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd worker && uv run pytest tests/test_prompts.py -k recipe_intake_prompt_documents -v`

Expected: FAIL — `qty_value`/`--servings` not found in prompt text.

- [ ] **Step 3: Update the prompt**

In `worker/prompts/recipe_intake.md`, replace line 24:

```
- 份量換算到 2 人份;換不乾淨的(1 顆蛋、一撮鹽)就照原樣寫,不要編造假分數。
```

with:

```
- 份量換算到 2 人份(`save-recipe` 一定要帶 `--servings 2`);換不乾淨的(1 顆蛋、
  一撮鹽)就照原樣寫,不要編造假分數。
- **每項食材,能明確拆出數字+單位就順便給 `qty_value`/`qty_unit`**(例如
  `qty:"300g"` → `qty_value:300, qty_unit:"g"`;`qty:"2 大匙"` →
  `qty_value:2, qty_unit:"大匙"`)。拆不乾淨的(1 顆蛋、一撮鹽、少許)—— 跟上面
  「份量」規則一樣的判斷 —— 只留 `qty`,不要硬拆或編數字。
```

And replace line 31:

```
  `.venv/bin/python state_api.py save-recipe --title "<繁中標題>" --slug "<英文-kebab-slug>" --source-block "<原文食材+步驟,未改動>" --body-md "<選填的整體心得/秘訣>" --ingredients '[{"name":"...","qty":"..."}]' --steps '[{"text":"...","duration_sec":180,"tip":"..."}]'`
```

with:

```
  `.venv/bin/python state_api.py save-recipe --title "<繁中標題>" --slug "<英文-kebab-slug>" --source-block "<原文食材+步驟,未改動>" --body-md "<選填的整體心得/秘訣>" --ingredients '[{"name":"...","qty":"...","qty_value":...,"qty_unit":"..."}]' --steps '[{"text":"...","duration_sec":180,"tip":"..."}]' --servings 2`
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd worker && uv run pytest tests/test_prompts.py -v`

Expected: PASS, full file (no regressions — `test_recipe_intake_prompt_is_persona_neutral`
and `test_recipe_intake_prompt_keeps_all_placeholders` still pass since neither edit
touches persona strings or `{placeholder}` tokens).

- [ ] **Step 5: Commit**

```bash
git add worker/prompts/recipe_intake.md worker/tests/test_prompts.py
git commit -m "feat(worker): recipe_intake emits structured ingredient quantities"
```

---

## Task 4: iOS models — `Ingredient.qtyValue`/`qtyUnit`, `Recipe.servings`

**Files:**
- Modify: `ios/Sous/Models.swift:95-98` (`Ingredient`), `:112-128` (`Recipe`)
- Modify: `ios/SousTests/CookbookLogicTests.swift:5-8` (`makeRecipe` helper — breaks
  once `Recipe`'s memberwise initializer gains a parameter)
- Test: Create `ios/SousTests/ModelsTests.swift`

**Interfaces:**
- Produces: `Ingredient.qtyValue: Double?`, `Ingredient.qtyUnit: String?` (JSON keys
  `qty_value`/`qty_unit`); `Recipe.servings: Int` (JSON key `servings`, non-optional —
  the DB column is `not null default 2`, Task 1).
- Consumes: nothing new at compile time; decodes data from Task 1/2/3's schema.

- [ ] **Step 1: Write the failing tests**

Create `ios/SousTests/ModelsTests.swift`:

```swift
import XCTest
@testable import Sous

final class ModelsTests: XCTestCase {
    func testIngredientDecodesStructuredQuantityFields() throws {
        let json = """
        {"name": "雞胸肉", "qty": "300g", "qty_value": 300, "qty_unit": "g"}
        """.data(using: .utf8)!
        let ingredient = try JSONDecoder().decode(Ingredient.self, from: json)
        XCTAssertEqual(ingredient.name, "雞胸肉")
        XCTAssertEqual(ingredient.qty, "300g")
        XCTAssertEqual(ingredient.qtyValue, 300)
        XCTAssertEqual(ingredient.qtyUnit, "g")
    }

    func testIngredientDecodesWithoutStructuredQuantityFields() throws {
        let json = """
        {"name": "鹽", "qty": "一撮"}
        """.data(using: .utf8)!
        let ingredient = try JSONDecoder().decode(Ingredient.self, from: json)
        XCTAssertEqual(ingredient.name, "鹽")
        XCTAssertNil(ingredient.qtyValue)
        XCTAssertNil(ingredient.qtyUnit)
    }

    func testRecipeDecodesServingsField() throws {
        let json = """
        {"id": "\(UUID().uuidString)", "slug": "test", "title": "測試",
         "source_block": null, "body_md": "", "ingredients": [], "steps": [],
         "created_at": "2026-08-04T00:00:00Z", "servings": 4}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let recipe = try decoder.decode(Recipe.self, from: json)
        XCTAssertEqual(recipe.servings, 4)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ios && xcodegen generate && xcodebuild test -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' -only-testing:SousTests/ModelsTests 2>&1 | tail -30`

Expected: FAIL to compile — `Ingredient`/`Recipe` have no member `qtyValue`/`servings`.

- [ ] **Step 3: Update `Ingredient`**

Replace `ios/Sous/Models.swift:95-98`:

```swift
struct Ingredient: Codable, Equatable, Hashable {
    let name: String
    let qty: String?
    let qtyValue: Double?
    let qtyUnit: String?

    enum CodingKeys: String, CodingKey {
        case name, qty
        case qtyValue = "qty_value"
        case qtyUnit = "qty_unit"
    }
}
```

- [ ] **Step 4: Update `Recipe`**

Replace `ios/Sous/Models.swift:112-128`:

```swift
struct Recipe: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    let slug: String
    let title: String
    let sourceBlock: String?
    let bodyMd: String
    let ingredients: [Ingredient]
    let steps: [RecipeStep]
    let createdAt: Date
    let servings: Int

    enum CodingKeys: String, CodingKey {
        case id, slug, title, ingredients, steps, servings
        case sourceBlock = "source_block"
        case bodyMd = "body_md"
        case createdAt = "created_at"
    }
}
```

- [ ] **Step 5: Fix the now-broken `makeRecipe` test helper**

Replace `ios/SousTests/CookbookLogicTests.swift:5-8`:

```swift
    private func makeRecipe(_ title: String) -> Recipe {
        Recipe(id: UUID(), slug: title, title: title, sourceBlock: nil, bodyMd: "",
               ingredients: [], steps: [], createdAt: Date(), servings: 2)
    }
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd ios && xcodegen generate && xcodebuild test -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' -only-testing:SousTests/ModelsTests -only-testing:SousTests/CookbookLogicTests 2>&1 | tail -30`

Expected: PASS, both test targets.

- [ ] **Step 7: Commit**

```bash
git add ios/Sous/Models.swift ios/SousTests/ModelsTests.swift ios/SousTests/CookbookLogicTests.swift
git commit -m "feat(ios): add structured ingredient quantities and recipe servings"
```

---

## Task 5: `RecipeScalingLogic.swift` — rescale + unit conversion math

**Files:**
- Create: `ios/Sous/RecipeScalingLogic.swift`
- Test: Create `ios/SousTests/RecipeScalingLogicTests.swift`

**Interfaces:**
- Consumes: `Ingredient` (Task 4).
- Produces: `enum UnitSystem { case metric, imperial }`; `isDiscreteUnit(_ unit: String) -> Bool`;
  `rescaledValue(qtyValue:unit:fromServings:toServings:) -> Double`;
  `convert(value:unit:to:) -> (value: Double, unit: String)?`;
  `formattedQuantity(value:unit:) -> String`;
  `displayQuantity(ingredient:currentServings:baseServings:unitSystem:) -> String` — the
  entry point Task 9 (`RecipeDetailView`'s ingredient rows) calls.

- [ ] **Step 1: Write the failing tests**

Create `ios/SousTests/RecipeScalingLogicTests.swift`:

```swift
import XCTest
@testable import Sous

final class RecipeScalingLogicTests: XCTestCase {
    private func ingredient(qty: String? = nil, qtyValue: Double? = nil,
                            qtyUnit: String? = nil) -> Ingredient {
        Ingredient(name: "test", qty: qty, qtyValue: qtyValue, qtyUnit: qtyUnit)
    }

    func testRescaledValueScalesContinuousUnitUp() {
        XCTAssertEqual(rescaledValue(qtyValue: 300, unit: "g", fromServings: 2, toServings: 4), 600.0)
    }

    func testRescaledValueRoundsContinuousUnitToOneDecimal() {
        XCTAssertEqual(rescaledValue(qtyValue: 1.5, unit: "cup", fromServings: 4, toServings: 2), 0.8)
    }

    func testRescaledValueRoundsDiscreteUnitToWholeNumber() {
        XCTAssertEqual(rescaledValue(qtyValue: 1, unit: "顆", fromServings: 2, toServings: 3), 2.0)
    }

    func testRescaledValueNeverGoesBelowOneForDiscreteUnits() {
        XCTAssertEqual(rescaledValue(qtyValue: 1, unit: "顆", fromServings: 4, toServings: 1), 1.0)
    }

    func testConvertWeightMetricToImperial() {
        let result = convert(value: 300, unit: "g", to: .imperial)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.unit, "oz")
        XCTAssertEqual(result!.value, 10.58, accuracy: 0.01)
    }

    func testConvertVolumeRoundTrips() {
        let toImperial = convert(value: 236.588, unit: "ml", to: .imperial)!
        XCTAssertEqual(toImperial.unit, "cup")
        XCTAssertEqual(toImperial.value, 1.0, accuracy: 0.01)
        let backToMetric = convert(value: toImperial.value, unit: toImperial.unit, to: .metric)!
        XCTAssertEqual(backToMetric.value, 236.588, accuracy: 0.5)
    }

    func testConvertReturnsNilForDiscreteUnits() {
        XCTAssertNil(convert(value: 2, unit: "顆", to: .imperial))
    }

    func testFormattedQuantityDropsDecimalForWholeNumbers() {
        XCTAssertEqual(formattedQuantity(value: 600.0, unit: "g"), "600 g")
    }

    func testFormattedQuantityKeepsOneDecimalForFractional() {
        XCTAssertEqual(formattedQuantity(value: 0.8, unit: "cup"), "0.8 cup")
    }

    func testDisplayQuantityRescalesWhenStructuredDataPresent() {
        let ing = ingredient(qty: "300g", qtyValue: 300, qtyUnit: "g")
        let result = displayQuantity(ingredient: ing, currentServings: 4, baseServings: 2, unitSystem: .metric)
        XCTAssertEqual(result, "600 g")
    }

    func testDisplayQuantityFallsBackToFreeTextWhenNoStructuredData() {
        let ing = ingredient(qty: "1 顆蛋")
        let result = displayQuantity(ingredient: ing, currentServings: 4, baseServings: 2, unitSystem: .metric)
        XCTAssertEqual(result, "1 顆蛋")
    }

    func testDisplayQuantityConvertsUnitSystem() {
        let ing = ingredient(qty: "300g", qtyValue: 300, qtyUnit: "g")
        let result = displayQuantity(ingredient: ing, currentServings: 2, baseServings: 2, unitSystem: .imperial)
        XCTAssertEqual(result, "10.6 oz")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ios && xcodegen generate && xcodebuild test -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' -only-testing:SousTests/RecipeScalingLogicTests 2>&1 | tail -30`

Expected: FAIL to compile — none of these functions exist yet.

- [ ] **Step 3: Implement**

Create `ios/Sous/RecipeScalingLogic.swift`:

```swift
// ios/Sous/RecipeScalingLogic.swift
import Foundation

enum UnitSystem {
    case metric
    case imperial
}

/// Count-noun units where a fractional serving reads as absurd ("1.5 顆蛋") — the same
/// judgment call `recipe_intake.md` already makes when it leaves quantities like this as
/// free text rather than a computed fraction.
private let discreteUnits: Set<String> = ["顆", "支", "片", "瓣", "把", "條", "塊"]

func isDiscreteUnit(_ unit: String) -> Bool {
    discreteUnits.contains(unit)
}

/// Grams-per-unit for weight, ml-per-unit for volume — canonical bases used to convert
/// between any two units of the same kind without an N×N conversion table.
private let weightUnitsInGrams: [String: Double] = ["g": 1, "kg": 1000, "oz": 28.3495, "lb": 453.592]
private let volumeUnitsInMl: [String: Double] = ["ml": 1, "l": 1000, "cup": 236.588,
                                                  "tbsp": 14.7868, "tsp": 4.92892, "fl oz": 29.5735]

/// Rescales a quantity from one servings baseline to another. Discrete units round to
/// the nearest whole number (minimum 1) so scaling never invents a fake fraction like
/// "1.5 顆"; continuous units round to 1 decimal place.
func rescaledValue(qtyValue: Double, unit: String, fromServings: Int, toServings: Int) -> Double {
    guard fromServings > 0 else { return qtyValue }
    let raw = qtyValue * Double(toServings) / Double(fromServings)
    if isDiscreteUnit(unit) {
        return max(1, raw.rounded())
    }
    return (raw * 10).rounded() / 10
}

/// Converts a continuous-unit quantity between metric and imperial via a shared base
/// unit (grams for weight, ml for volume). Returns `nil` for discrete or unrecognized
/// units — callers display those unconverted, since the unit toggle only touches
/// convertible continuous units.
func convert(value: Double, unit: String, to system: UnitSystem) -> (value: Double, unit: String)? {
    if let perUnit = weightUnitsInGrams[unit] {
        let grams = value * perUnit
        let targetUnit = system == .metric ? "g" : "oz"
        guard let targetPerUnit = weightUnitsInGrams[targetUnit] else { return nil }
        return (grams / targetPerUnit, targetUnit)
    }
    if let perUnit = volumeUnitsInMl[unit] {
        let ml = value * perUnit
        let targetUnit = system == .metric ? "ml" : "cup"
        guard let targetPerUnit = volumeUnitsInMl[targetUnit] else { return nil }
        return (ml / targetPerUnit, targetUnit)
    }
    return nil
}

/// Formats a numeric quantity for display: whole numbers drop the decimal point.
func formattedQuantity(value: Double, unit: String) -> String {
    if value == value.rounded() {
        return "\(Int(value)) \(unit)"
    }
    return "\(String(format: "%.1f", value)) \(unit)"
}

/// The single entry point `RecipeDetailView` calls per ingredient row: rescales for the
/// current serving count, then converts for the active unit system, falling back to the
/// ingredient's free-text `qty` unchanged when there's no structured quantity to work
/// with (old recipes, or quantities `recipe_intake.md` couldn't cleanly parse).
func displayQuantity(ingredient: Ingredient, currentServings: Int, baseServings: Int,
                     unitSystem: UnitSystem) -> String {
    guard let qtyValue = ingredient.qtyValue, let qtyUnit = ingredient.qtyUnit else {
        return ingredient.qty ?? ""
    }
    let rescaled = rescaledValue(qtyValue: qtyValue, unit: qtyUnit,
                                 fromServings: baseServings, toServings: currentServings)
    if let converted = convert(value: rescaled, unit: qtyUnit, to: unitSystem) {
        return formattedQuantity(value: converted.value, unit: converted.unit)
    }
    return formattedQuantity(value: rescaled, unit: qtyUnit)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ios && xcodegen generate && xcodebuild test -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' -only-testing:SousTests/RecipeScalingLogicTests 2>&1 | tail -30`

Expected: PASS, all 12 tests.

- [ ] **Step 5: Commit**

```bash
git add ios/Sous/RecipeScalingLogic.swift ios/SousTests/RecipeScalingLogicTests.swift
git commit -m "feat(ios): add RecipeScalingLogic for servings rescale + unit conversion"
```

---

## Task 6: Extract shared `folioText` into `CookbookLogic.swift`

**Files:**
- Modify: `ios/Sous/CookbookLogic.swift`
- Modify: `ios/Sous/CookbookView.swift:244, 269-280` (remove local copy, use shared one)
- Test: `ios/SousTests/CookbookLogicTests.swift`

**Interfaces:**
- Produces: `folioText(_ n: Int) -> String` (moved from `CookbookView`, unchanged
  behavior) — Task 8 (`RecipeDetailView`'s running head) also calls this.
- Consumes: nothing new.

**Why:** `RecipeDetailView`'s running head needs the identical digit-by-digit folio
format `CookbookView` already implements privately (`CookbookView.swift:269-280`).
Duplicating it in a second file risks the two silently drifting; extracting it once here
keeps both screens' folio numbers guaranteed identical.

- [ ] **Step 1: Write the failing test**

Append to `ios/SousTests/CookbookLogicTests.swift`, inside `CookbookLogicTests`:

```swift
    func testFolioTextRendersDigitByDigit() {
        XCTAssertEqual(folioText(23), "二三")
    }

    func testFolioTextRendersSingleDigit() {
        XCTAssertEqual(folioText(5), "五")
    }

    func testFolioTextHandlesZeroAsLiteral() {
        XCTAssertEqual(folioText(0), "0")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios && xcodegen generate && xcodebuild test -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' -only-testing:SousTests/CookbookLogicTests 2>&1 | tail -30`

Expected: FAIL to compile — `folioText` isn't visible outside `CookbookView` yet (it's
currently `private`).

- [ ] **Step 3: Move `folioText`/`folioDigits` into `CookbookLogic.swift`**

Append to `ios/Sous/CookbookLogic.swift`:

```swift

private let folioDigits = ["〇", "一", "二", "三", "四", "五", "六", "七", "八", "九"]

/// Folios read like page numbers — digit-by-digit ("二三" for 23), not the cardinal
/// grammar `chineseNumeral` (CounterView.swift) uses for spoken counts. Shared between
/// `CookbookView` (D2, every row) and `RecipeDetailView` (D1, the one recipe it shows).
func folioText(_ n: Int) -> String {
    guard n > 0 else { return "\(n)" }
    return String(n).compactMap { $0.wholeNumberValue.map { folioDigits[$0] } }.joined()
}
```

- [ ] **Step 4: Remove the now-duplicate copy from `CookbookView.swift`**

Delete `ios/Sous/CookbookView.swift:269-280`:

```swift
    private static let folioDigits = ["〇", "一", "二", "三", "四", "五", "六", "七", "八", "九"]

    /// Folios read like page numbers — digit-by-digit ("二三" for 23) — not the
    /// cardinal grammar `chineseNumeral` (CounterView.swift) uses for spoken counts
    /// like dates or the header's "十四 道" ("fourteen dishes"). Matches the mock's own
    /// folio style (二三/二七/三一/四二/四五) and keeps every folio a fixed
    /// glyph-per-digit width, so it can't overflow the 24pt folio column the way a
    /// 3-glyph cardinal reading ("二十三") could for any recipe count ≥ 20.
    private func folioText(_ n: Int) -> String {
        guard n > 0 else { return "\(n)" }
        return String(n).compactMap { $0.wholeNumberValue.map { Self.folioDigits[$0] } }.joined()
    }
```

(The call site at `CookbookView.swift:244`, `Text(folioText(folio))`, needs no change —
it now resolves to the free function in `CookbookLogic.swift` instead of the deleted
private method, same signature.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd ios && xcodegen generate && xcodebuild test -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' -only-testing:SousTests/CookbookLogicTests 2>&1 | tail -30`

Expected: PASS, all tests including the 3 new ones.

Also build the full app to confirm `CookbookView` still compiles against the moved
function:

Run: `cd ios && xcodebuild build -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' 2>&1 | tail -20`

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add ios/Sous/CookbookLogic.swift ios/Sous/CookbookView.swift ios/SousTests/CookbookLogicTests.swift
git commit -m "refactor(ios): share folioText between Cookbook and Recipe Detail"
```

---

## Task 7: `RecipePhotoCarousel.swift` — placeholder-only carousel component

**Files:**
- Create: `ios/Sous/RecipePhotoCarousel.swift`

**Interfaces:**
- Produces: `struct RecipePhotoCarousel: View` — a self-contained component Task 10
  drops into `RecipeDetailView`. Takes no data this pass (placeholder-only, per the
  design spec — `cook_sessions.photo_url` doesn't exist until Pass 1c); built so wiring
  a real photo array in later is a prop/binding addition, not a rebuild.
- Consumes: `PaperTokens`, `Spacing` (`DesignTokens.swift`), `model.personaTint` (passed
  in as a `Color` parameter — this view has no `AppModel` dependency of its own, keeping
  it a pure presentation component).

**Design reference:** No mockup for this — it's new UI per the design spec's brainstorm
(tap zones, not swipe; progress-segment bars, not arrows). Placeholder count: 2 slots
(matches "at least 2" from brainstorming), all rendering the same hatched-placeholder
treatment Pass 1a established (`CookbookView`'s empty state / the handoff's "no
production imagery" placeholders).

This task is not TDD-shaped — it's a new pure-SwiftUI view with no logic to unit test
(same precedent as Pass 1a's screen-restyle tasks). It has an explicit acceptance bar
instead.

- [ ] **Step 1: Implement**

Create `ios/Sous/RecipePhotoCarousel.swift`:

```swift
// ios/Sous/RecipePhotoCarousel.swift
import SwiftUI

/// Tap-to-advance photo carousel for Recipe Detail (D1) — placeholder-only in Pass 1b
/// (see docs/superpowers/specs/2026-08-04-m3-visual-restyle-pass1b-recipe-detail-design.md
/// "Scope decisions"): `cook_sessions.photo_url` doesn't exist until Pass 1c, so there's
/// no real photo data to query yet. Tap zones instead of swipe because swipe is reserved
/// for the separate swipe-ritual gesture elsewhere in the app.
struct RecipePhotoCarousel: View {
    let accentColor: Color
    private let placeholderCount = 2
    @State private var index = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ZStack {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [PaperTokens.ink.opacity(0.06), .clear],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                Text("料理照片")
                    .font(.system(size: 10, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(PaperTokens.inkFaint)
            }
            .frame(height: 194)
            .overlay(alignment: .topLeading) { progressSegments }
            .overlay(tapZones)

            Text("圖 · 之後煮這道菜的照片會顯示在這裡。")
                .font(.system(size: 11.5))
                .italic()
                .foregroundStyle(PaperTokens.inkDim)
        }
    }

    private var progressSegments: some View {
        HStack(spacing: 3) {
            ForEach(0..<placeholderCount, id: \.self) { i in
                Rectangle()
                    .fill(i == index ? accentColor : PaperTokens.ink.opacity(0.18))
                    .frame(height: 2)
            }
        }
        .padding(8)
    }

    private var tapZones: some View {
        HStack(spacing: 0) {
            Color.clear.contentShape(Rectangle()).onTapGesture { advance(by: -1) }
            Color.clear.contentShape(Rectangle()).onTapGesture { advance(by: 1) }
        }
    }

    private func advance(by delta: Int) {
        let next = index + delta
        guard next >= 0, next < placeholderCount else { return }
        index = next
    }
}
```

- [ ] **Step 2: Build**

Run: `cd ios && xcodegen generate && xcodebuild build -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' 2>&1 | tail -20`

Expected: `BUILD SUCCEEDED`.

**Acceptance:** Not wired into any screen yet (Task 10 does that) — this task's bar is
just that it compiles standalone. Right-half tap advances `index` (clamped at
`placeholderCount - 1`), left-half tap decrements (clamped at `0`); the active progress
segment tints `accentColor`, inactive ones stay faint ink.

- [ ] **Step 3: Commit**

```bash
git add ios/Sous/RecipePhotoCarousel.swift
git commit -m "feat(ios): add placeholder-only RecipePhotoCarousel component"
```

---

## Task 8: `RecipeDetailView.swift` — paper restyle shell

**Files:** Modify `ios/Sous/RecipeDetailView.swift` (currently 102 lines — the whole
file).

**Design reference:** README "D1 · 食譜 (recipe — where 邊欄 lives)" and
`Sous App v2.dc.html` lines 481-558 — **excluding** the 邊欄 exchange block (lines
533-541) and anything photo-carousel/icon-row/servings/unit-related (those are Tasks
9-10; the mockup shows a single static photo and no icon row, per the design spec).

**Running head:** the mockup's left slot shows a fabricated ingredient-based category
("家常 · 雞") that doesn't exist anywhere in `Recipe`'s schema — same data gap
`CookbookView` already hit and resolved by omitting the fabricated label (see
`CookbookView.swift`'s file-header scope note). Follow the same precedent here: omit the
left slot, show only the folio (right-aligned, `folioText` from Task 6) computed the
same way `CookbookView` computes it — 1-based position of `recipe` in
`model.recipes.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }`.

**Seal "第 X 道" numeral:** reuses that *same* folio number (there's no second, distinct
"dish number" concept anywhere in the data model — inventing one would fabricate data
the same way the chapter label would), just read cardinally via `chineseNumeral`
(`CounterView.swift`) instead of digit-by-digit: `"第 \(chineseNumeral(folio)) 道"`.

**Native navigation bar:** the current file uses `.navigationTitle(recipe.title)`, which
draws a system nav bar (back chevron + title) on top of the page. That's redundant with
the mockup's own in-content running head/title and breaks the "printed page" framing the
same way it would have for D2 — `CookbookView` already resolved this for itself with
`.toolbar(.hidden, for: .navigationBar)`. Since `RecipeDetailView` is pushed as a child
of `CookbookView`'s own `NavigationStack`, apply the same modifier here and drop
`.navigationTitle(...)` entirely; `NavigationStack`'s interactive edge-swipe-to-pop
keeps working even with the bar hidden, so back navigation isn't lost, just its chrome.

**Tokens/copy:** `PaperTokens.stock` background, `model.personaTint` for the seal
numeral and folio, `serifFontName`/`sansFontName` via `FontBook`, `Spacing.pageMargin`.
No new `copy_pack` keys — "食　材"/"作　法"/"這一頁的紀錄" etc. are structural labels
matching `CookbookView`'s precedent for hardcoded UI-chrome Chinese strings.

**What stays exactly as-is (don't touch):** `loadVerdicts()`, the `verdicts` `@State`
and its Supabase query, `showCookMode` + the `.fullScreenCover` presenting
`CookModeView(recipe: recipe, planDay: nil)`, `relativeDateString(_:)`. This task is
restyling their presentation, not their data flow.

**Scope guard:** the mockup's 邊欄 exchange block (你問/answer/已寫進這一頁) is **not**
built here — confirmed excluded in the design spec (`ChatMessage` has no `recipe_id`).
If implementing this task seems to require adding a recipe-chat query, stop — that's
Pass 2 territory, not this task.

This task is not TDD-shaped (same reasoning as Pass 1a's screen tasks — no meaningful
unit test for visual layout). Explicit acceptance bar below in place of tests.

- [ ] **Step 1: Restyle**

Rewrite `ios/Sous/RecipeDetailView.swift`'s structure (excluding the servings/unit
band and photo carousel, which Tasks 9-10 add) to:
- Running head: folio only (right-aligned), hairline rule below — mirrors
  `CookbookView.header`'s shape.
- Centered seal `第 X 道` (`model.personaTint`, sans, tracked wide).
- Centered title (`recipe.title`, serif 31pt, tracked `.05em`).
- 22×1pt rule, centered.
- `recipe.bodyMd` as description text below the rule, if non-empty (the mockup shows a
  short description here; `Recipe` has no separate description field, so reuse
  `bodyMd` — it's already free-text "整體心得/秘訣" content, the closest existing field).
- Centered "食　材" label, then ingredient rows: name + dotted leader + `ingredient.qty`
  **unchanged for now** — Task 9 replaces this with the rescaled `displayQuantity(...)`
  call once the stepper/toggle state exists.
- Centered "作　法" label, then numbered steps: seal-tint Chinese numeral (reuse
  `chineseNumeral` for `1...`), step text (serif 14pt, line-height ~2.15), inline 眉批
  tip block (`step.tip`, left border seal-tint) when present, duration line
  (`step.durationSec`, formatted as e.g. "十分鐘" via `chineseNumeral` or plain "10
  分鐘" — either is acceptable, match `chineseNumeral`'s existing style if used
  elsewhere for durations, otherwise plain digits) when present.
- "這一頁的紀錄" section: existing `verdicts` array rendered per the mockup's list
  style (seal Chinese numeral bullet + relative date + rating), replacing the current
  `GroupBox("上次煮 · ...")`.
- Existing `cookedCount` line, existing "開始做菜" button (relabel from "開始煮" to
  match the mockup's copy), same `showCookMode` binding — restyle to the mockup's
  sticky-footer ink-filled button treatment, but the ask-field shown in the mockup's
  sticky footer is **not** built (that's the excluded 邊欄 entry point).

- [ ] **Step 2: Build**

Run: `cd ios && xcodegen generate && xcodebuild build -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' 2>&1 | tail -20`

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Run full test suite**

Run: `cd ios && xcodebuild test -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' 2>&1 | tail -30`

Expected: PASS, same count as after Task 6 plus Tasks 4/5's new tests — no regressions.
(`loadVerdicts()`'s query is untouched, so no verdict-loading test exists to break.)

**Acceptance:** Visually matches README D1 (minus servings/unit/photo-carousel/icon-row,
Tasks 9-10) at both 402pt and 375pt (iPhone 13 mini simulator or real device). Folio
number matches the recipe's actual alphabetical position in `model.recipes` (spot-check
against `CookbookView`'s folio for the same recipe — they must agree, since both derive
from the same sort). Tapping "開始做菜" still launches `CookModeView` exactly as before.

- [ ] **Step 4: Commit**

```bash
git add ios/Sous/RecipeDetailView.swift
git commit -m "feat(ios): restyle Recipe Detail to paper design system"
```

---

## Task 9: Servings stepper + live ingredient rescale + unit toggle

**Files:** Modify `ios/Sous/RecipeDetailView.swift` (post-Task 8 version).

**Interfaces:**
- Consumes: `RecipeScalingLogic.swift`'s `displayQuantity`, `UnitSystem` (Task 5);
  `recipe.servings` (Task 4).
- Produces: nothing new for later tasks — this is the leaf interactive behavior.

**Design reference:** README D1's `份量` band (`Sous App v2.dc.html` lines 499-505) for
the stepper's visual shape (ruled band, `−`/value/`+`, seal-tint buttons). The unit
toggle has no mockup (design spec: designed fresh) — place it as a small text toggle
(e.g. `公制`/`英制`, tap to flip) directly above or beside the ingredient list header,
not inside the servings band (keeps the servings band visually matching the mockup
exactly; the toggle is new chrome, kept visually distinct).

- [ ] **Step 1: Add state**

In `RecipeDetailView`, alongside the existing `@State` properties, add:

```swift
    @State private var currentServings: Int
    @State private var unitSystem: UnitSystem = .metric

    init(recipe: Recipe) {
        self.recipe = recipe
        _currentServings = State(initialValue: recipe.servings)
    }
```

(`recipe` changes from a plain `let` property to needing this explicit `init` only
because `currentServings`'s initial value depends on it — `@State` properties can't read
`self` in their default-value position. `model`/`verdicts`/`showCookMode` keep their
existing declarations unchanged below this.)

- [ ] **Step 2: Servings stepper view**

Add, in the position Task 8 left the ingredient section's "band" (per the mockup, above
"食　材"):

```swift
    private var servingsBand: some View {
        HStack(alignment: .center) {
            Text("份量")
                .font(.custom(sansName, size: 10))
                .tracking(3.2)
                .foregroundStyle(PaperTokens.inkFaint)
            Spacer()
            Button {
                if currentServings > 1 { currentServings -= 1 }
            } label: {
                Text("−").font(.system(size: 19)).foregroundStyle(model.personaTint)
            }
            .frame(minWidth: 44, minHeight: 44)
            Text("\(currentServings) 人份")
                .font(.custom(serifName, size: 16))
                .monospacedDigit()
                .frame(minWidth: 58)
            Button {
                currentServings += 1
            } label: {
                Text("+").font(.system(size: 19)).foregroundStyle(model.personaTint)
            }
            .frame(minWidth: 44, minHeight: 44)
        }
        .padding(.vertical, 14)
        .overlay(Rectangle().stroke(PaperTokens.rule, lineWidth: 1).frame(height: 1), alignment: .top)
        .overlay(Rectangle().stroke(PaperTokens.rule, lineWidth: 1).frame(height: 1), alignment: .bottom)
    }
```

(`serifName`/`sansName` — reuse the same computed properties Task 8 already added,
matching `CookbookView`'s `serifName`/`sansName` pattern. `currentServings` floors at 1,
per the design spec's rescale rules never producing a value below that.)

- [ ] **Step 3: Unit toggle view**

```swift
    private var unitToggle: some View {
        Button {
            unitSystem = (unitSystem == .metric) ? .imperial : .metric
        } label: {
            Text(unitSystem == .metric ? "公制" : "英制")
                .font(.custom(sansName, size: 10.5))
                .tracking(1.5)
                .foregroundStyle(PaperTokens.inkDim)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .overlay(Rectangle().stroke(PaperTokens.ink.opacity(0.24), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
    }
```

- [ ] **Step 4: Wire both into the layout, replace static ingredient quantity display**

Insert `servingsBand` between the photo section and the "食　材" heading (Task 8's
placeholder ordering already puts photo before ingredients). Place `unitToggle`
trailing-aligned next to the "食　材" heading (`HStack` wrapping the existing centered
label — the toggle sits to its right, not centered, so it doesn't disturb the mockup's
centered section-label rhythm).

Replace the ingredient row's quantity text (Task 8 left it as
`Text(ingredient.qty ?? "")`) with:

```swift
Text(displayQuantity(ingredient: ingredient, currentServings: currentServings,
                     baseServings: recipe.servings, unitSystem: unitSystem))
```

- [ ] **Step 5: Build and manually verify**

Run: `cd ios && xcodegen generate && xcodebuild build -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' 2>&1 | tail -20`

Expected: `BUILD SUCCEEDED`.

Run: `cd ios && xcodebuild test -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' 2>&1 | tail -30`

Expected: PASS, no regressions (the rescale *math* is already covered by
`RecipeScalingLogicTests`, Task 5 — this task is view wiring, verified manually below).

**Acceptance:** In the simulator, open a recipe with at least one structured-quantity
ingredient (seed one via `worker/state_api.py save-recipe ... --servings 2` with a
`qty_value`/`qty_unit` ingredient, or use one already produced by Task 2/3's test
fixtures against the local stack). Tapping `+` increases the displayed quantity for
every ingredient that has `qtyValue` set, proportionally; ingredients without it stay
fixed. Tapping `公制`/`英制` converts weight/volume ingredients' units and values (e.g.
`300 g` ⇄ `10.6 oz`); discrete-unit ingredients (顆/支/etc.) are unaffected by the
toggle. `−` stops decrementing below `1`.

- [ ] **Step 6: Commit**

```bash
git add ios/Sous/RecipeDetailView.swift
git commit -m "feat(ios): wire servings stepper and unit toggle to live rescale"
```

---

## Task 10: Photo carousel integration + print/copy icon row

**Files:** Modify `ios/Sous/RecipeDetailView.swift` (post-Task 9 version).

**Interfaces:**
- Consumes: `RecipePhotoCarousel` (Task 7); `displayQuantity` (Task 5, reused for the
  copy/print text builder).

- [ ] **Step 1: Replace the photo placeholder with the carousel**

Task 8's photo section (a static hatched rectangle, matching the mockup's single-photo
treatment) is replaced with:

```swift
RecipePhotoCarousel(accentColor: model.personaTint)
```

- [ ] **Step 2: Build the shareable/copyable recipe text**

Add a private helper:

```swift
    private func formattedRecipeText() -> String {
        var lines = [recipe.title, ""]
        lines.append("食材（\(currentServings) 人份）")
        for ingredient in recipe.ingredients {
            let qty = displayQuantity(ingredient: ingredient, currentServings: currentServings,
                                      baseServings: recipe.servings, unitSystem: unitSystem)
            lines.append(qty.isEmpty ? ingredient.name : "\(ingredient.name)　\(qty)")
        }
        lines.append("")
        lines.append("作法")
        for (i, step) in recipe.steps.enumerated() {
            lines.append("\(i + 1). \(step.text)")
        }
        return lines.joined(separator: "\n")
    }
```

- [ ] **Step 3: Copy + print icon row**

Add, positioned per the mockup's implied icon-row placement (near the title/description,
above the photo — the design spec calls this "new, not in the mockup," so exact
placement is an implementation call; top-trailing of the description block is
reasonable and doesn't collide with any mockup element):

```swift
    private var iconRow: some View {
        HStack(spacing: 18) {
            Spacer()
            Button {
                UIPasteboard.general.string = formattedRecipeText()
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.success)
                showCopyToast = true
            } label: {
                Label("拷貝", systemImage: "doc.on.doc")
                    .font(.custom(sansName, size: 11))
                    .foregroundStyle(PaperTokens.inkDim)
            }
            .frame(minHeight: 44)
            ShareLink(item: formattedRecipeText()) {
                Label("列印", systemImage: "printer")
                    .font(.custom(sansName, size: 11))
                    .foregroundStyle(PaperTokens.inkDim)
            }
            .frame(minHeight: 44)
        }
    }
```

Add the toast state alongside the other `@State` properties:

```swift
    @State private var showCopyToast = false
```

Render a minimal toast (any lightweight approach is fine — e.g. a conditional `Text`
overlay that auto-dismisses):

```swift
    .overlay(alignment: .top) {
        if showCopyToast {
            Text("已拷貝")
                .font(.custom(sansName, size: 11))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(PaperTokens.ink)
                .foregroundStyle(PaperTokens.stock)
                .padding(.top, 8)
                .task {
                    try? await Task.sleep(for: .seconds(1.5))
                    showCopyToast = false
                }
        }
    }
```

(Attach this `.overlay` to the outer `ScrollView`/`VStack` alongside the existing
`.fullScreenCover` modifier from Task 8.)

- [ ] **Step 4: Wire `iconRow` into the layout**

Insert `iconRow` directly below the title/description block, above `RecipePhotoCarousel`.

- [ ] **Step 5: Build and run full test suite**

Run: `cd ios && xcodegen generate && xcodebuild build -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' 2>&1 | tail -20`

Expected: `BUILD SUCCEEDED`.

Run: `cd ios && xcodebuild test -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' 2>&1 | tail -30`

Expected: PASS, no regressions — this is the last task, so the final count should be
every pre-existing test plus `ModelsTests` (Task 4), `RecipeScalingLogicTests` (Task 5),
and the 3 new `CookbookLogicTests` folio tests (Task 6).

**Acceptance:** Photo area shows the tap-to-advance carousel (right/left tap zones
advance/retreat, progress segments update, no swipe response). Tapping 拷貝 copies the
current-serving ingredient list + steps as plain text to the clipboard (verify via
pasting into Notes on the simulator) and shows a brief "已拷貝" toast. Tapping 列印
opens the system share sheet with the same text, AirPrint available among the options.
Both icon buttons meet the 44pt minimum touch target.

- [ ] **Step 6: Commit**

```bash
git add ios/Sous/RecipeDetailView.swift
git commit -m "feat(ios): wire photo carousel and copy/print icon row into Recipe Detail"
```

---

## Final verification (whole-plan acceptance)

After Task 10:
- [ ] Full test suite green: `cd ios && xcodebuild test -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' 2>&1 | tail -30` and `cd worker && uv run pytest -v`.
- [ ] Real-device check on iPhone 13 mini (375pt), per Pass 1a's exit-criteria precedent
  — walk the full D1 screen: running head/folio, seal numeral, title, icon row,
  carousel tap zones, servings stepper (both directions, floor at 1), unit toggle,
  ingredient list (both structured and free-text rows), steps with tips/durations,
  verdict history, 開始做菜 → Cook Mode launch.
- [ ] Whole-branch review before merge, same bar as Pass 1a (Ready to merge = Yes, no
  Critical/Important findings).
