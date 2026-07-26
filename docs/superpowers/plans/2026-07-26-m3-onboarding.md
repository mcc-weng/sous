# M3 — Onboarding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the app a first-run onboarding wizard — a native SwiftUI step-by-step
interview (allergies, dislikes, spice, equipment, household size) that writes
`preferences.content` directly, plus a chat-driven `update_preferences` verb so the
brain can keep it current afterward, per
`docs/superpowers/specs/2026-07-26-m3-onboarding-design.md`.

**Architecture:** Two independent write paths into the existing `preferences` table
(no schema change to that table itself). (1) A new native SwiftUI wizard
(`OnboardingView`) writes `preferences` directly via the Supabase client — needs one new
RLS policy, since `preferences` is read-only from the app's perspective today. No job,
no brain round-trip; mirrors the shopping-checkbox's direct-write precedent. (2) A new
`update_preferences` `state_api` verb lets the brain update `preferences` during
ordinary chat (kind="chat" already allows every `state_api.py` verb — no job-routing
change needed). Wizard framing copy (not the chip option lists themselves) flows
through a new set of `copy_pack` keys, following the persona-discipline rule. The
wizard is gated on `preferences.content` being empty, checked client-side on every
`CounterView` appearance; a settings entry point can also force a redo.

**Tech Stack:** Swift 5 / SwiftUI (iOS 17+), `supabase-swift` (already a dependency),
XcodeGen (`ios/project.yml` → generated `ios/Sous.xcodeproj`), XCTest for pure-logic
unit tests, Python (worker, psycopg), pytest, PostgreSQL/Supabase migrations + RLS.

## Global Constraints

- Next Postgres migration numbers are `0012` and `0013` (last existing is `0011`).
- No new job `kind`. The wizard never touches jobs at all (direct client write); chat
  revisits use the existing `kind="chat"` path, which already blanket-allows every
  `state_api.py` verb via `chat_allowed_tools` in `worker/config.json` — no config
  change needed there.
- `copy_pack` migrations always merge (`copy_pack || jsonb_build_object(...)`), never
  overwrite — existing keys (`failure_message`, `ritual_prompt_title`,
  `ritual_prompt_body`) must survive.
- Chip option lists (allergen names, equipment names, etc.) are plain data, not persona
  voice — they stay as hardcoded Swift arrays, never routed through `copy_pack`. Only
  the question *framing* text and completion copy come from `copy_pack`.
- Every `copy_pack`-sourced string in the iOS wizard has a hardcoded Swift fallback used
  if the key is missing or the fetch fails — a resilience default, not a persona-voice
  decision, so this does not violate the "zero hardcoded persona strings" rule.
- Household size (question 5) is mandatory-with-a-default (2) and always contributes a
  composed line; questions 1–4 are individually skippable and omit their line when
  empty. See the design doc's scope-decision note for why the earlier "all-skip
  placeholder" idea was dropped.
- Household comes from the signed-in session / `AppModel.household`, never hardcoded —
  same rule the worker side follows for `SOUS_HOUSEHOLD_ID`.
- `ios/Sous.xcodeproj` is generated via `xcodegen generate` from `ios/project.yml` —
  never hand-edit `project.pbxproj`. New source files under `ios/Sous/` and
  `ios/SousTests/` are picked up automatically (both targets glob their whole
  directory in `project.yml`) — no `project.yml` edit needed for this plan.
- iOS build/test verification: `cd ios && xcodegen generate && xcodebuild -project
  Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=<SIM_NAME>'
  test` (same convention as every prior iOS plan in this repo).
- Worker test verification: `cd worker && .venv/bin/pytest <path> -v`.

---

### Task 1: RLS migration — `preferences` write policy

**Files:**
- Create: `supabase/migrations/0012_preferences_write_policy.sql`

**Interfaces:**
- Produces: a `preferences_write` RLS policy allowing `is_member(household_id)` to
  insert/update/select/delete their own household's `preferences` row. Task 6 (iOS
  `submitPreferences`) depends on this to write at all; Task 5's real-use exit check
  depends on it to verify.

- [ ] **Step 1: Write the migration**

```sql
-- supabase/migrations/0012_preferences_write_policy.sql
-- preferences has been read-only from the app's perspective since 0002_rls.sql — the
-- one household that exists today got its `content` by hand via seed.sql, never
-- through a real write path. M3 onboarding
-- (docs/superpowers/specs/2026-07-26-m3-onboarding-design.md) needs the wizard to
-- upsert preferences directly from iOS on completion, for an instant completion feel
-- with no job/brain round-trip — mirroring the "for all" grant already used for
-- household-owned data (cook_rw, verdict_rw in 0002_rls.sql) rather than a narrower
-- single-command policy.
create policy preferences_write on preferences for all to authenticated
  using (is_member(household_id)) with check (is_member(household_id));
```

- [ ] **Step 2: Apply locally and verify**

Run: `supabase db reset` (local stack) or, if the local stack is already running,
`supabase migration up`.

Then verify the policy exists with the right expressions:

```bash
cd /Users/mikeweng/Projects/sous
psql "$(supabase status -o env | grep DB_URL | cut -d= -f2 | tr -d '"')" -c \
  "select polname, pg_get_expr(polqual, polrelid) as using_expr, \
   pg_get_expr(polwithcheck, polrelid) as check_expr from pg_policy \
   where polname='preferences_write';"
```

Expected: one row, `using_expr` and `check_expr` both `is_member(household_id)`.

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/0012_preferences_write_policy.sql
git commit -m "feat(db): allow household members to write their own preferences"
```

---

### Task 2: `update_preferences` state_api verb

**Files:**
- Modify: `worker/state_api.py`
- Test: `worker/tests/test_state_api.py`

**Interfaces:**
- Consumes: nothing new — same `conn`/`household_id` shape every other verb uses.
- Produces: `update_preferences(conn, household_id: str, content: str) -> dict` (`{"ok":
  True, "content": content}`), CLI verb `update-preferences --content <str>`. Task 4
  (chat.md) documents this verb for the brain to call.

- [ ] **Step 1: Write the failing tests**

Add to `worker/tests/test_state_api.py`, right after `test_flag_staple_upserts`:

```python
def test_update_preferences_upserts(conn, api_hid):
    first = state_api.update_preferences(conn, api_hid, "2人份\n不吃香菜")
    assert first["ok"] is True
    row = conn.execute(
        "select content from preferences where household_id = %s", (api_hid,),
    ).fetchone()
    assert row == ("2人份\n不吃香菜",)

    again = state_api.update_preferences(conn, api_hid, "2人份\n不吃香菜、內臟")
    assert again["ok"] is True
    row = conn.execute(
        "select content from preferences where household_id = %s", (api_hid,),
    ).fetchone()
    assert row == ("2人份\n不吃香菜、內臟",)
```

Add near the other `test_cli_*` functions (e.g. after `test_cli_shopping_verbs`):

```python
def test_cli_update_preferences(api_hid):
    proc = _run_cli(["update-preferences", "--content", "辣度:中辣 OK"], api_hid)
    assert proc.returncode == 0, proc.stderr
    out = json.loads(proc.stdout)
    assert out["ok"] is True and out["content"] == "辣度:中辣 OK"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd worker && .venv/bin/pytest tests/test_state_api.py -k update_preferences -v`
Expected: FAIL — `state_api.update_preferences` / CLI verb `update-preferences` not
defined.

- [ ] **Step 3: Implement the verb**

In `worker/state_api.py`, add after `schedule_notification` (before the
`_ensure_proposing_week_for_test` helper):

```python
def update_preferences(conn, household_id: str, content: str) -> dict:
    conn.execute(
        "insert into preferences (household_id, content) values (%s, %s) "
        "on conflict (household_id) do update set content = excluded.content, "
        "updated_at = now()",
        (household_id, content),
    )
    return {"ok": True, "content": content}
```

In `_parser()`, add after the `schedule-notification` subparser block (before
`return p`):

```python
    up = sub.add_parser("update-preferences")
    up.add_argument("--content", required=True)
```

In `_dispatch()`, add after the `schedule-notification` branch (before
`raise ValueError(f"unknown verb {args.verb}")`):

```python
    if args.verb == "update-preferences":
        return update_preferences(conn, household_id, args.content)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd worker && .venv/bin/pytest tests/test_state_api.py -k update_preferences -v`
Expected: PASS (2 tests).

- [ ] **Step 5: Run the full worker suite to check for regressions**

Run: `cd worker && .venv/bin/pytest tests/ -v`
Expected: all pass (no new failures beyond any pre-existing skips).

- [ ] **Step 6: Commit**

```bash
git add worker/state_api.py worker/tests/test_state_api.py
git commit -m "feat(worker): add update_preferences state_api verb"
```

---

### Task 3: `copy_pack` migration — onboarding framing copy

**Files:**
- Create: `supabase/migrations/0013_onboarding_copy_pack.sql`

**Interfaces:**
- Produces: seven new `copy_pack` keys on every persona: `onboarding_intro`,
  `onboarding_q_allergies`, `onboarding_q_dislikes`, `onboarding_q_spice`,
  `onboarding_q_equipment`, `onboarding_q_household_size`, `onboarding_complete`. Task 7
  (`OnboardingView`) reads these by exact key name, with a hardcoded fallback if a key
  is missing.

- [ ] **Step 1: Write the migration**

```sql
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
```

- [ ] **Step 2: Apply locally and verify**

Run: `supabase db reset` (local stack) or `supabase migration up`.

```bash
psql "$(supabase status -o env | grep DB_URL | cut -d= -f2 | tr -d '"')" -c \
  "select name, copy_pack->'onboarding_intro' as intro from personas;"
```

Expected: every persona row shows the new `onboarding_intro` text (not null).

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/0013_onboarding_copy_pack.sql
git commit -m "feat(db): add onboarding wizard framing copy to copy_pack"
```

---

### Task 4: `chat.md` — document `update-preferences` for the brain

**Files:**
- Modify: `worker/prompts/chat.md`

**Interfaces:**
- Consumes: Task 2's `update-preferences` CLI verb.
- Produces: no code interface — this only changes brain-facing prompt text, verified by
  inspection and by the real-use exit check's chat-revisit scenario.

- [ ] **Step 1: Add the verb to "你的手"**

In `worker/prompts/chat.md`, after the `capture-inbox` bullet (the last bullet in that
section) and before the blank line preceding `## 規則`:

Old:
```
- 記進 inbox,下次排菜單時處理(想吃的、回饋、雜記):
  `.venv/bin/python state_api.py capture-inbox --kind craving --content "想吃泰式"`

## 規則
```

New:
```
- 記進 inbox,下次排菜單時處理(想吃的、回饋、雜記):
  `.venv/bin/python state_api.py capture-inbox --kind craving --content "想吃泰式"`
- 更新家庭偏好(過敏、忌口、辣度、設備、人數有變動時):
  `.venv/bin/python state_api.py update-preferences --content "完整偏好內容"`
  這個指令是整份覆蓋,不是合併 —— 一定要先看上面「家庭偏好」的現況,把沒變的部分原封
  不動保留,只改動對方提到的那一項,再整份送出。

## 規則
```

- [ ] **Step 2: Add a rule for when to use it**

After the "太模糊就先問清楚再動" rule (the first bullet under `## 規則`) and before the
"上面渲染好的狀態若「已經」反映了對方的要求" bullet:

Old:
```
- 對方要求改動:直接動手,做完明確講你改了什麼(例:「好!週三換成三杯雞了」)。
  要求太模糊(「換一道」但沒說換什麼)就先問清楚再動。
- 上面渲染好的狀態若「已經」反映了對方的要求,不要重複執行(可能是系統重試)—
```

New:
```
- 對方要求改動:直接動手,做完明確講你改了什麼(例:「好!週三換成三杯雞了」)。
  要求太模糊(「換一道」但沒說換什麼)就先問清楚再動。
- 對方主動提到飲食偏好改變(過敏、忌口、辣度、設備、人數):讀懂完整新內容後用
  `update-preferences` 更新,成功後明確回報改了哪一項(例:「好,幫你把不吃香菜加進去
  了」)。
- 上面渲染好的狀態若「已經」反映了對方的要求,不要重複執行(可能是系統重試)—
```

- [ ] **Step 3: Verify the file still reads correctly**

Run: `grep -n "update-preferences" worker/prompts/chat.md`
Expected: two matches (one in "你的手", one in "規則").

- [ ] **Step 4: Commit**

```bash
git add worker/prompts/chat.md
git commit -m "feat(worker): teach chat mode to update preferences via state_api"
```

---

### Task 5: `OnboardingLogic.swift` — composition & gating (TDD)

**Files:**
- Create: `ios/Sous/OnboardingLogic.swift`
- Test: `ios/SousTests/OnboardingLogicTests.swift`

**Interfaces:**
- Produces: `enum SpiceLevel: String, CaseIterable, Identifiable` (cases `none="不辣"`,
  `mild="小辣"`, `medium="中辣"`, `hot="大辣"`); `let onboardingAllergyOptions:
  [String]`, `let onboardingDislikeOptions: [String]`, `let
  onboardingEquipmentOptions: [String]`; `struct OnboardingAnswers: Equatable` (fields:
  `allergies: [String] = []`, `allergyOther: String = ""`, `dislikes: [String] = []`,
  `dislikeOther: String = ""`, `spiceLevel: SpiceLevel? = nil`, `equipment: [String] =
  []`, `householdSize: Int = 2`); `func composePreferences(_ answers:
  OnboardingAnswers) -> String`; `func needsOnboarding(preferencesContent: String?) ->
  Bool`. Task 6 (`AppModel`) uses `needsOnboarding`; Task 7 (`OnboardingView`) uses
  everything else.

- [ ] **Step 1: Write the failing tests**

```swift
// ios/SousTests/OnboardingLogicTests.swift
import XCTest
@testable import Sous

final class OnboardingLogicTests: XCTestCase {
    func testComposePreferencesAllFields() {
        var answers = OnboardingAnswers()
        answers.allergies = ["花生"]
        answers.dislikes = ["香菜"]
        answers.spiceLevel = .medium
        answers.equipment = ["瓦斯爐", "烤箱"]
        answers.householdSize = 2
        XCTAssertEqual(composePreferences(answers),
                       "過敏:花生\n不吃香菜\n辣度:中辣 OK\n設備:瓦斯爐、烤箱\n2人份")
    }

    func testComposePreferencesOmitsSkippedFields() {
        var answers = OnboardingAnswers()
        answers.spiceLevel = .mild
        answers.householdSize = 3
        XCTAssertEqual(composePreferences(answers), "辣度:小辣 OK\n3人份")
    }

    func testComposePreferencesMergesOtherIntoChips() {
        var answers = OnboardingAnswers()
        answers.allergies = ["花生"]
        answers.allergyOther = "芒果"
        answers.householdSize = 2
        XCTAssertEqual(composePreferences(answers), "過敏:花生、芒果\n2人份")
    }

    func testComposePreferencesAllSkippedStillWritesHouseholdSize() {
        var answers = OnboardingAnswers()
        answers.householdSize = 2
        XCTAssertEqual(composePreferences(answers), "2人份")
    }

    func testNeedsOnboardingTrueForNilOrEmpty() {
        XCTAssertTrue(needsOnboarding(preferencesContent: nil))
        XCTAssertTrue(needsOnboarding(preferencesContent: ""))
        XCTAssertTrue(needsOnboarding(preferencesContent: "   "))
    }

    func testNeedsOnboardingFalseForRealContent() {
        XCTAssertFalse(needsOnboarding(preferencesContent: "2人份"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ios && xcodegen generate && xcodebuild -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=<SIM_NAME>' test`
Expected: FAIL to build — `OnboardingAnswers`/`composePreferences`/`needsOnboarding` not
defined.

- [ ] **Step 3: Implement**

```swift
// ios/Sous/OnboardingLogic.swift
import Foundation

enum SpiceLevel: String, CaseIterable, Identifiable {
    case none = "不辣"
    case mild = "小辣"
    case medium = "中辣"
    case hot = "大辣"
    var id: String { rawValue }
}

let onboardingAllergyOptions = ["甲殼類", "花生", "堅果", "乳製品", "麩質", "蛋"]
let onboardingDislikeOptions = ["香菜", "內臟", "苦瓜", "茄子", "生食"]
let onboardingEquipmentOptions = ["瓦斯爐", "電磁爐", "烤箱", "電子鍋", "氣炸鍋", "微波爐"]

struct OnboardingAnswers: Equatable {
    var allergies: [String] = []
    var allergyOther: String = ""
    var dislikes: [String] = []
    var dislikeOther: String = ""
    var spiceLevel: SpiceLevel?
    var equipment: [String] = []
    var householdSize: Int = 2
}

/// Composes structured wizard answers into the free-text bullet-line convention
/// `preferences.content` already uses (seed.sql) — every prompt template that reads
/// `{preferences}` needs the exact same format, one line per answered question.
/// Household size always contributes a line (mandatory-with-a-default, unlike the
/// other four questions — see the design doc's scope-decision note); the rest are
/// individually skippable and simply omit their line when empty.
func composePreferences(_ answers: OnboardingAnswers) -> String {
    var lines: [String] = []

    let allergies = (answers.allergies + [answers.allergyOther])
        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    if !allergies.isEmpty {
        lines.append("過敏:\(allergies.joined(separator: "、"))")
    }

    let dislikes = (answers.dislikes + [answers.dislikeOther])
        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    if !dislikes.isEmpty {
        lines.append("不吃\(dislikes.joined(separator: "、"))")
    }

    if let spiceLevel = answers.spiceLevel {
        lines.append("辣度:\(spiceLevel.rawValue) OK")
    }

    if !answers.equipment.isEmpty {
        lines.append("設備:\(answers.equipment.joined(separator: "、"))")
    }

    lines.append("\(answers.householdSize)人份")

    return lines.joined(separator: "\n")
}

/// Households whose preferences are empty or whitespace-only need onboarding — mirrors
/// context.py's `_render_preferences` emptiness check (`row and row[0]`, falsy on both
/// a missing row and an empty string) so client and brain agree on "not yet
/// configured."
func needsOnboarding(preferencesContent: String?) -> Bool {
    guard let content = preferencesContent else { return true }
    return content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ios && xcodegen generate && xcodebuild -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=<SIM_NAME>' test`
Expected: PASS (6 new tests in `OnboardingLogicTests`).

- [ ] **Step 5: Commit**

```bash
git add ios/Sous/OnboardingLogic.swift ios/SousTests/OnboardingLogicTests.swift
git commit -m "feat(ios): add onboarding composition and gating logic"
```

---

### Task 6: `AppModel` — preferences + persona copy plumbing

**Files:**
- Modify: `ios/Sous/Models.swift`
- Modify: `ios/Sous/AppModel.swift`

**Interfaces:**
- Consumes: `PreferencesRow`/`PersonaCopyRow` (new, this task).
- Produces: `Household.personaId: UUID` (new field); `AppModel.preferencesContent:
  String?` (published); `AppModel.personaCopy: [String: String]` (published);
  `AppModel.loadPreferences() async`; `AppModel.loadPersonaCopy() async`;
  `AppModel.submitPreferences(content: String) async throws`. Task 7
  (`OnboardingView`) and Task 8 (`CounterView`) both depend on these exact names.

No dedicated unit test for this task — matching this codebase's existing convention
that `AppModel`'s network-calling functions (`loadCookbook`, `loadShoppingItems`,
`registerDeviceToken`, etc.) have no unit tests of their own; they're exercised by the
Task 10 real-use exit check instead, same as every other `AppModel` load/write function
in this app.

- [ ] **Step 1: Add models**

In `ios/Sous/Models.swift`, modify the `Household` struct:

```swift
struct Household: Codable {
    let id: UUID
    let name: String
    let workerSeenAt: Date?
    let timezone: String
    let personaId: UUID

    enum CodingKeys: String, CodingKey {
        case id, name, timezone
        case workerSeenAt = "worker_seen_at"
        case personaId = "persona_id"
    }
}
```

Append two new structs at the end of `Models.swift`:

```swift
struct PreferencesRow: Codable {
    let content: String
}

struct PersonaCopyRow: Codable {
    let copyPack: [String: String]

    enum CodingKeys: String, CodingKey {
        case copyPack = "copy_pack"
    }
}
```

- [ ] **Step 2: Update the household fetch**

In `ios/Sous/AppModel.swift`, modify `refreshHousehold()`'s select list:

Old:
```swift
            let rows: [Household] = try await client.from("households")
                .select("id,name,worker_seen_at,timezone").execute().value
```

New:
```swift
            let rows: [Household] = try await client.from("households")
                .select("id,name,worker_seen_at,timezone,persona_id").execute().value
```

- [ ] **Step 3: Add preferences + persona copy loading and the write function**

In `ios/Sous/AppModel.swift`, add two new `@Published` properties near the existing
ones:

```swift
    @Published var preferencesContent: String?
    @Published var personaCopy: [String: String] = [:]
```

Add three new functions, placed after `loadShoppingItems()`:

```swift
    func loadPreferences() async {
        do {
            let rows: [PreferencesRow] = try await client.from("preferences")
                .select("content").execute().value
            preferencesContent = rows.first?.content
        } catch { print("preferences load: \(error)") }
    }

    func loadPersonaCopy() async {
        guard let personaId = household?.personaId else { return }
        do {
            let row: PersonaCopyRow = try await client.from("personas")
                .select("copy_pack").eq("id", value: personaId).single().execute().value
            personaCopy = row.copyPack
        } catch { print("persona copy load: \(error)") }
    }

    /// Direct write, no job — instant, matching the shopping-checkbox precedent
    /// (`toggleShoppingItem`). Throws so `OnboardingView` can show inline retry instead
    /// of silently discarding a completed interview.
    func submitPreferences(content: String) async throws {
        guard let household else { return }
        struct Upsert: Encodable { let household_id: UUID; let content: String }
        try await client.from("preferences")
            .upsert(Upsert(household_id: household.id, content: content))
            .execute()
        preferencesContent = content
    }
```

- [ ] **Step 4: Build to verify no compile errors**

Run: `cd ios && xcodegen generate && xcodebuild -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=<SIM_NAME>' build`
Expected: build succeeds (existing `OnboardingLogicTests` from Task 5 still pass if
`test` is run instead).

- [ ] **Step 5: Commit**

```bash
git add ios/Sous/Models.swift ios/Sous/AppModel.swift
git commit -m "feat(ios): add preferences and persona copy plumbing to AppModel"
```

---

### Task 7: `OnboardingView.swift` — the wizard UI

**Files:**
- Create: `ios/Sous/OnboardingView.swift`

**Interfaces:**
- Consumes: everything from Task 5 (`OnboardingAnswers`, `composePreferences`,
  `SpiceLevel`, option arrays) and Task 6 (`AppModel.personaCopy`,
  `AppModel.loadPersonaCopy()`, `AppModel.submitPreferences(content:)`).
- Produces: `struct OnboardingView: View` (no external params — reads
  `@EnvironmentObject private var model: AppModel`). Task 8 and Task 9 both present
  this view via `.fullScreenCover`.

No dedicated unit test — this is a SwiftUI view composed entirely of Task 5's
already-tested pure logic; its correctness is verified visually and behaviorally in
Task 10's real-use exit check, matching how `CookModeView`/`WeekBoardView` have no view
tests of their own in this codebase.

- [ ] **Step 1: Implement the view**

```swift
// ios/Sous/OnboardingView.swift
import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var stepIndex = 0
    @State private var answers = OnboardingAnswers()
    @State private var isSubmitting = false
    @State private var submitError: String?

    private let stepCount = 5

    private func copy(_ key: String, fallback: String) -> String {
        model.personaCopy[key] ?? fallback
    }

    var body: some View {
        VStack(spacing: 24) {
            progressDots
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if stepIndex == 0 {
                        Text(copy("onboarding_intro",
                                  fallback: "先讓我認識你一下,幾個小問題,一下就好。"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    currentStep
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let submitError {
                Text(submitError).font(.caption).foregroundStyle(.red)
            }
            navigationButtons
        }
        .padding()
        .task { await model.loadPersonaCopy() }
    }

    @ViewBuilder
    private var currentStep: some View {
        switch stepIndex {
        case 0:
            questionHeader("onboarding_q_allergies",
                           fallback: "你有沒有什麼過敏原,我要小心別放進菜單裡?")
            OnboardingChipGrid(options: onboardingAllergyOptions, selection: $answers.allergies)
            TextField("其他(選填)", text: $answers.allergyOther).textFieldStyle(.roundedBorder)
        case 1:
            questionHeader("onboarding_q_dislikes",
                           fallback: "有沒有什麼你不喜歡吃的?我幫你避開。")
            OnboardingChipGrid(options: onboardingDislikeOptions, selection: $answers.dislikes)
            TextField("其他(選填)", text: $answers.dislikeOther).textFieldStyle(.roundedBorder)
        case 2:
            questionHeader("onboarding_q_spice", fallback: "口味吃辣嗎?")
            Picker("辣度", selection: $answers.spiceLevel) {
                Text("略過").tag(SpiceLevel?.none)
                ForEach(SpiceLevel.allCases) { level in
                    Text(level.rawValue).tag(SpiceLevel?.some(level))
                }
            }
            .pickerStyle(.segmented)
        case 3:
            questionHeader("onboarding_q_equipment", fallback: "家裡有哪些廚房設備?")
            OnboardingChipGrid(options: onboardingEquipmentOptions, selection: $answers.equipment)
        default:
            questionHeader("onboarding_q_household_size", fallback: "平常煮飯大概幾人份?")
            Stepper("\(answers.householdSize) 人", value: $answers.householdSize, in: 1...8)
        }
    }

    private func questionHeader(_ key: String, fallback: String) -> some View {
        Text(copy(key, fallback: fallback)).font(.title3.bold())
    }

    private var progressDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<stepCount, id: \.self) { i in
                Circle()
                    .fill(i == stepIndex ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
        }
    }

    private var navigationButtons: some View {
        HStack {
            if stepIndex > 0 {
                Button("上一步") { stepIndex -= 1 }
            }
            Spacer()
            if stepIndex == stepCount - 1 {
                Button(isSubmitting ? "送出中…" : "完成") { Task { await submit() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSubmitting)
            } else {
                Button("下一步") { stepIndex += 1 }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func submit() async {
        isSubmitting = true
        submitError = nil
        let content = composePreferences(answers)
        do {
            try await model.submitPreferences(content: content)
            isSubmitting = false
            dismiss()
        } catch {
            isSubmitting = false
            submitError = "儲存失敗,請再試一次(\(error.localizedDescription))"
        }
    }
}

private struct OnboardingChipGrid: View {
    let options: [String]
    @Binding var selection: [String]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], alignment: .leading, spacing: 8) {
            ForEach(options, id: \.self) { option in
                let isSelected = selection.contains(option)
                Button(option) {
                    if isSelected {
                        selection.removeAll { $0 == option }
                    } else {
                        selection.append(option)
                    }
                }
                .buttonStyle(.bordered)
                .tint(isSelected ? .accentColor : .secondary)
            }
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `cd ios && xcodegen generate && xcodebuild -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=<SIM_NAME>' build`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add ios/Sous/OnboardingView.swift
git commit -m "feat(ios): add onboarding wizard view"
```

---

### Task 8: Wire the first-run trigger into `CounterView`

**Files:**
- Modify: `ios/Sous/CounterView.swift`

**Interfaces:**
- Consumes: `needsOnboarding(preferencesContent:)` (Task 5), `model.loadPreferences()`
  (Task 6), `OnboardingView` (Task 7).
- Produces: nothing new consumed by later tasks — this is the terminal wiring for the
  first-run path.

- [ ] **Step 1: Add the gating state and cover**

In `ios/Sous/CounterView.swift`, add a new `@State` alongside the existing ones:

```swift
    @State private var showOnboarding = false
```

Add a new `.fullScreenCover` and `.task` to the view's modifier chain (after the
existing `.task { await model.loadCookbook() }`):

Old:
```swift
        .task { await model.loadCookbook() }
    }
```

New:
```swift
        .task { await model.loadCookbook() }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView().environmentObject(model)
        }
        .task {
            await model.loadPreferences()
            showOnboarding = needsOnboarding(preferencesContent: model.preferencesContent)
        }
    }
```

(Two separate `.task` modifiers on the same view run independently and concurrently —
matches the existing single-purpose-per-modifier style in this file.)

- [ ] **Step 2: Build to verify it compiles**

Run: `cd ios && xcodegen generate && xcodebuild -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=<SIM_NAME>' build`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add ios/Sous/CounterView.swift
git commit -m "feat(ios): force onboarding wizard on first run"
```

---

### Task 9: Settings redo entry point

**Files:**
- Modify: `ios/Sous/AppModel.swift`
- Modify: `ios/Sous/NotificationsSettingsView.swift`
- Modify: `ios/Sous/CounterView.swift`

**Interfaces:**
- Consumes: `OnboardingView` (Task 7), `showOnboarding` state (Task 8).
- Produces: `AppModel.onboardingRestartRequested: Bool` (published) — a one-shot signal
  from the settings sheet to `CounterView`.

- [ ] **Step 1: Add the restart-request flag**

In `ios/Sous/AppModel.swift`, add a new `@Published` property alongside
`preferencesContent`/`personaCopy`:

```swift
    @Published var onboardingRestartRequested = false
```

- [ ] **Step 2: Add the settings button**

In `ios/Sous/NotificationsSettingsView.swift`, add a new section to the `VStack` inside
`body`, after the existing `Button(isRequesting ? "處理中…" : "開啟通知") { ... }`
block and before the closing `.padding()`:

Old:
```swift
                Button(isRequesting ? "處理中…" : "開啟通知") {
                    Task { await requestAndRegister() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRequesting)
            }
            .padding()
```

New:
```swift
                Button(isRequesting ? "處理中…" : "開啟通知") {
                    Task { await requestAndRegister() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRequesting)

                Divider()

                Text("偏好設定").font(.headline)
                Button("重新設定偏好") {
                    model.onboardingRestartRequested = true
                    dismiss()
                }
                .buttonStyle(.bordered)
            }
            .padding()
```

- [ ] **Step 3: Wire the signal into `CounterView`**

In `ios/Sous/CounterView.swift`, add an `.onChange` modifier next to the
`.fullScreenCover(isPresented: $showOnboarding)` added in Task 8:

Old:
```swift
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView().environmentObject(model)
        }
```

New:
```swift
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView().environmentObject(model)
        }
        .onChange(of: model.onboardingRestartRequested) { _, requested in
            guard requested else { return }
            showOnboarding = true
            model.onboardingRestartRequested = false
        }
```

- [ ] **Step 4: Build to verify it compiles**

Run: `cd ios && xcodegen generate && xcodebuild -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=<SIM_NAME>' build`
Expected: build succeeds.

- [ ] **Step 5: Commit**

```bash
git add ios/Sous/AppModel.swift ios/Sous/NotificationsSettingsView.swift ios/Sous/CounterView.swift
git commit -m "feat(ios): add settings entry point to redo onboarding"
```

---

## Real-use exit check

The real sandbox household already has non-empty seeded `preferences`
(`is_member`-scoped, from `seed.sql`), so the forced first-run path won't organically
trigger there — verify against a temporary test household instead, per household rule
(verify via real use, not sandboxes... but here "sandbox" in the household-rule sense
means the app's own real cloud project, not a unit-test mock — this check still runs
against real cloud Supabase and a real device/simulator, just a throwaway household row
rather than the production one).

- [ ] Insert a temporary test household directly in the cloud DB (via `psql` against the
  cloud connection string), owned by a persona, with no `preferences` row — join your
  own auth user to it, or temporarily point the app's cached `household_id` at it.
- [ ] Launch the app (or force-quit and relaunch): confirm the onboarding wizard appears
  full-screen before Kitchen Counter is usable.
- [ ] Step through all 5 questions: pick some allergy chips, type an "其他" allergy,
  skip dislikes entirely, pick a spice level, pick equipment chips, adjust the household
  size stepper. Confirm progress dots and back navigation work.
- [ ] Tap "完成": confirm the wizard dismisses and Kitchen Counter appears.
- [ ] Query `preferences.content` for the test household directly (`psql`) and confirm
  it matches the composed bullet-line format exactly, including the household-size
  line.
- [ ] Send a real chat message referencing the plan or a dish; confirm the brain's
  response reflects awareness of the new preferences (e.g. avoids a flagged allergy in
  a suggestion, or the rendered context visibly includes the new lines).
- [ ] From the notifications settings sheet, tap "重新設定偏好": confirm the wizard
  reappears full-screen, starting blank (no pre-filled answers — the stated v1
  limitation).
- [ ] Complete it again with different answers; confirm `preferences.content` is fully
  overwritten (old answers gone, not merged).
- [ ] Separately, in a household that already has `preferences` set, send a chat message
  like `「我開始吃素了」`; confirm the brain calls `update-preferences` and the reply
  confirms the change in character; query `preferences.content` to confirm it was
  updated (not wiped — the brain's own responsibility to preserve unrelated existing
  lines, per Task 4's rule).
- [ ] Delete the temporary test household and any test rows created during this check.

## Out of scope (carried from the design doc)

- Back-parsing existing free-text `preferences` into pre-filled wizard chips on redo.
- Per-member preferences (household-scoped only).
- Brain enrichment of the wizard's composed text at submission time.
- Real per-user household provisioning — the M1 auto-join-to-sandbox shim
  (`0002_rls.sql`) is untouched by this plan.
- Folding notification-permission requesting into the onboarding flow, even though
  `NotificationsSettingsView`'s existing doc comment anticipates this ("Stands in for
  the real onboarding permission flow... until that lands") — out of scope for this
  plan since the approved design spec doesn't call for it; flagged here as a discovered
  adjacent item for a future pass, not silently folded in.
