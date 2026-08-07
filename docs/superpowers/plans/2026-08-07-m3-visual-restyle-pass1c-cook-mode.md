# M3 Visual Restyle — Pass 1c: Cook Mode (C1–C4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restyle `CookModeView.swift`'s four phases to the 書與灶 stage/paper system and
add the three real capabilities the restyle exposes as gaps —a per-step timer,
independent concurrent background timers, and 上菜 photo capture backed by a new
`cook_sessions.photo_url` column — per
`docs/superpowers/specs/2026-08-07-m3-visual-restyle-pass1c-cook-mode-design.md`.

**Architecture:** A new `StageTokens` design-system layer (Cook Mode is the first screen
set to touch the dark half of 書與灶) plus a shared `CrossingTransition` component
(the 940ms paper↔stage choreography, used both directions) wrap the existing four-phase
`CookModeView`, which grows a fifth phase (`.plateUp`, for 上菜 — currently missing
entirely, the flow jumps straight from the last teleprompter step to verdict). A new
`CookTimerModel` drives both the step timer and independent background timers from
absolute end-times (never a decrementing countdown), so pausing the step timer can't
touch the rice, and backgrounding/foregrounding needs no invalidation logic — remaining
time is always `endTime.timeIntervalSinceNow`. Local notifications (one per running
timer) cover the case where the user has switched apps. Photo capture uses the system
camera sheet, uploads to a new private `cook-photos` Storage bucket, and
`RecipePhotoCarousel` (placeholder-only since Pass 1b) is wired to query it — closing
that pass's open loop.

**Tech Stack:** SwiftUI (iOS 17+), XCTest, `UserNotifications` (local notifications,
already imported elsewhere in this codebase for push), Supabase Storage (via the
already-pinned `supabase-swift` 2.52.0 SDK — `client.storage.from(_:).upload/download`),
`UIImagePickerController` (camera capture, no new dependency), Supabase Postgres
migration (SQL). No new package dependencies.

## Global Constraints

- **Stage-first for C2/C3, paper everywhere else in this file** — `StageTokens.bg`
  background for the teleprompter and photo-capture screens only; C1/C4 stay
  `PaperTokens.stock`. See parent design spec's "If your hands are busy and something
  is counting, dark. Everything else is paper."
- **No border radius anywhere on paper** — stage uses square too, except the timer ring
  (circle) and the 上菜 photo target (also circle-accented per the mockup's ◎).
- **Persona-tintable**: the seal/accent colour on paper screens is `model.personaTint`,
  never a hardcoded hex. Stage screens use `StageTokens.brass` for their accent
  (per-README, brass is stage's own accent — not persona-tinted).
- **Traditional Chinese primary**: `serifFontName(bundled: FontBook.isSerifBundled)` /
  `sansFontName(bundled: FontBook.isSansBundled)` (`DesignTokens.swift`) for all text.
- **copy_pack discipline applies to persona voice, not generic UI chrome** — established
  precedent (Pass 1b). New UI-chrome strings in this plan (拍照/跳過/計時器 labels, timer
  notification text) are hardcoded Chinese, not new `copy_pack` keys.
- Minimum touch target 44pt.
- **Real device target**: iPhone 13 mini, 375pt logical width.
- **Migration must reach production, not just local** — per
  `[[feedback-real-device-check-needs-cloud-migrations]]`: `supabase db push --linked`
  is required before the real-device exit check (Final verification), not discovered as
  a gap after it.
- Design reference: `design_handoff_sous_m3/README.md` §C1–C4, §Motion (過場), §灶 ·
  Stage tokens table, §Accessibility.
- Build/test command shape (iOS): `cd ios && xcodegen generate && xcodebuild ... -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' ...`
  — always run `xcodegen generate` first.
- Build/test command shape (SQL): `supabase db reset` (local), verified with
  `docker exec -it $(docker ps -qf "name=supabase_db") psql -U postgres -c "..."`.

---

## Task 1: `StageTokens` — dark-half design tokens

**Files:**
- Modify: `ios/Sous/DesignTokens.swift`

**Interfaces:**
- Produces: `enum StageTokens { static let bg, ink, inkDim, brass, brassSoft, rule: Color; static var glow: some View }`.
- Consumes: nothing (reuses `PaperTokens.seal`... — actually `PaperTokens` has no `seal`,
  only `sealFallback`; stage's accent for the seal-shared token is `model.personaTint`
  wherever a *persona* seal appears on stage, same as paper. `StageTokens.brass` is
  stage's own distinct accent per the README table and is never persona-tinted.)

This is not TDD-shaped — pure constant/view declarations, same as `PaperTokens` itself
had no tests. Explicit acceptance bar below.

- [ ] **Step 1: Add `StageTokens`**

Append to `ios/Sous/DesignTokens.swift`, directly after the closing brace of
`enum PaperTokens` (after line 22):

```swift

/// 灶 · Stage — the dark half of 書與灶, reserved for exactly three screens per the
/// design handoff: cook-mode steps, timers, and 上菜 (`Sous App v2.dc.html` calls this
/// "if your hands are busy and something is counting, dark; everything else is paper").
/// Cook Mode (Pass 1c) is the first screen set to use this enum — Pass 1a only ever
/// built `PaperTokens`.
enum StageTokens {
    static let bg = Color(red: 0x0C / 255, green: 0x0A / 255, blue: 0x09 / 255)
    static let ink = Color(red: 0xF4 / 255, green: 0xEF / 255, blue: 0xE6 / 255)
    static let inkDim = Color(red: 0xA4 / 255, green: 0x9D / 255, blue: 0x93 / 255)
    static let brass = Color(red: 0xC9 / 255, green: 0x8A / 255, blue: 0x3E / 255)
    static let brassSoft = Color(red: 0xDC / 255, green: 0xC5 / 255, blue: 0x9C / 255)
    static let rule = ink.opacity(0.20)

    /// Anchored to the bottom edge, arrives last in the crossing (500ms) — "light comes
    /// on last, the way a gas ring does" (README §Motion).
    static var glow: some View {
        RadialGradient(
            colors: [brass.opacity(0.20), .clear],
            center: .center, startRadius: 0, endRadius: 160
        )
    }
}
```

- [ ] **Step 2: Build**

Run: `cd ios && xcodegen generate && xcodebuild build -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' 2>&1 | tail -20`

Expected: `BUILD SUCCEEDED`.

**Acceptance:** `StageTokens.bg`/`.ink`/`.inkDim`/`.brass`/`.brassSoft`/`.rule` resolve to
the exact hex values in the README's 灶 · Stage table; `StageTokens.glow` compiles as a
droppable `View`.

- [ ] **Step 3: Commit**

```bash
git add ios/Sous/DesignTokens.swift
git commit -m "feat(ios): add StageTokens for Cook Mode's dark screens"
```

---

## Task 2: Migration — `cook_sessions.photo_url` + `cook-photos` storage bucket

**Files:**
- Create: `supabase/migrations/0019_cook_photo_storage.sql`

**Interfaces:**
- Produces: `cook_sessions.photo_url text` (nullable); private storage bucket
  `cook-photos`; `storage.objects` RLS policies scoped by `is_member()` parsed off the
  object path's first segment (`{household_id}/{cook_session_id}.jpg`).
- Consumes: `public.is_member(hid uuid)` (already defined, `0002_rls.sql`).

- [ ] **Step 1: Write the migration**

```sql
-- supabase/migrations/0019_cook_photo_storage.sql
-- Pass 1c (Cook Mode redesign): the 上菜 photo-capture column, plus the storage bucket
-- it's uploaded into. Private bucket + household-scoped RLS, mirroring the is_member()
-- pattern every other table's policy already uses (0002_rls.sql), rather than a public
-- bucket. See docs/superpowers/specs/2026-08-07-m3-visual-restyle-pass1c-cook-mode-design.md.

alter table cook_sessions add column photo_url text;

insert into storage.buckets (id, name, public)
values ('cook-photos', 'cook-photos', false)
on conflict (id) do nothing;

-- Objects are stored at "{household_id}/{cook_session_id}.jpg" — the first path segment
-- is the household id, checked against household_members the same way every other
-- table's RLS policy does.
create policy cook_photos_read on storage.objects for select to authenticated
  using (bucket_id = 'cook-photos' and is_member(((storage.foldername(name))[1])::uuid));

create policy cook_photos_write on storage.objects for insert to authenticated
  with check (bucket_id = 'cook-photos' and is_member(((storage.foldername(name))[1])::uuid));

create policy cook_photos_update on storage.objects for update to authenticated
  using (bucket_id = 'cook-photos' and is_member(((storage.foldername(name))[1])::uuid))
  with check (bucket_id = 'cook-photos' and is_member(((storage.foldername(name))[1])::uuid));
```

- [ ] **Step 2: Apply locally and verify**

Run: `supabase db reset`

Expected: migration applies cleanly, seed re-runs after it.

Run:
```bash
docker exec -it $(docker ps -qf "name=supabase_db") psql -U postgres -c \
  "select column_name from information_schema.columns where table_name = 'cook_sessions' and column_name = 'photo_url';"
docker exec -it $(docker ps -qf "name=supabase_db") psql -U postgres -c \
  "select id, public from storage.buckets where id = 'cook-photos';"
```

Expected: first query returns one row (`photo_url`); second returns one row
(`cook-photos`, `public = f`).

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/0019_cook_photo_storage.sql
git commit -m "feat(db): add cook_sessions.photo_url and cook-photos storage bucket"
```

---

## Task 3: iOS models — `CookSession.photoUrl` + derived select clause

**Files:**
- Modify: `ios/Sous/Models.swift:149-161` (`CookSession`)
- Modify: `ios/Sous/AppModel.swift:202-212` (`loadCookbook`)
- Modify: `ios/Sous/CookModeView.swift:160-168` (`startSession` — same hand-maintained
  select string, same bug class)
- Test: Create `ios/SousTests/CookSessionModelTests.swift`

**Interfaces:**
- Produces: `CookSession.photoUrl: String?` (JSON key `photo_url`);
  `CookSession.selectColumns: String` (static, `CodingKeys.allCases`-derived, same
  pattern as `Recipe.selectColumns`).
- Consumes: `cook_sessions.photo_url` (Task 2).

**Why derive the select clause here too:** `Recipe.selectColumns` was added
2026-08-07 specifically because a hand-maintained PostgREST `select=` string
(`AppModel.loadCookbook()`'s old `"id,slug,title,..."`) silently dropped `servings` and
broke decoding for two days in production. `CookSession` has exactly the same
hand-maintained string in two places (`AppModel.loadCookbook()` and
`CookModeView.startSession()`) — adding `photo_url` to `CookSession` without fixing
both is the identical bug shape recurring on day one of its own existence.

- [ ] **Step 1: Write the failing tests**

Create `ios/SousTests/CookSessionModelTests.swift`:

```swift
import XCTest
@testable import Sous

final class CookSessionModelTests: XCTestCase {
    func testCookSessionDecodesPhotoUrl() throws {
        let json = """
        {"id": "\(UUID().uuidString)", "recipe_id": "\(UUID().uuidString)",
         "started_at": "2026-08-07T00:00:00Z", "completed_at": null,
         "photo_url": "abc/def.jpg"}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(CookSession.self, from: json)
        XCTAssertEqual(session.photoUrl, "abc/def.jpg")
    }

    func testCookSessionDecodesWithoutPhotoUrl() throws {
        let json = """
        {"id": "\(UUID().uuidString)", "recipe_id": "\(UUID().uuidString)",
         "started_at": "2026-08-07T00:00:00Z", "completed_at": null}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(CookSession.self, from: json)
        XCTAssertNil(session.photoUrl)
    }

    func testCookSessionSelectColumnsIncludesPhotoUrl() {
        XCTAssertEqual(CookSession.selectColumns, "id,recipe_id,started_at,completed_at,photo_url")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ios && xcodegen generate && xcodebuild test -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' -only-testing:SousTests/CookSessionModelTests 2>&1 | tail -30`

Expected: FAIL to compile — `CookSession` has no member `photoUrl`/`selectColumns`.

- [ ] **Step 3: Update `CookSession`**

Replace `ios/Sous/Models.swift:149-161`:

```swift
struct CookSession: Codable, Identifiable, Equatable {
    let id: UUID
    let recipeId: UUID
    let startedAt: Date
    let completedAt: Date?
    let photoUrl: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case recipeId = "recipe_id"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case photoUrl = "photo_url"
    }

    /// PostgREST `select=` column list derived from `CodingKeys`, same pattern and same
    /// rationale as `Recipe.selectColumns` — see that property's doc comment for the
    /// production incident this class of bug caused.
    static let selectColumns = CodingKeys.allCases.map(\.rawValue).joined(separator: ",")
}
```

- [ ] **Step 4: Use `selectColumns` at both call sites**

In `ios/Sous/AppModel.swift`, replace line 209:

```swift
                .select("id,recipe_id,started_at,completed_at")
```

with:

```swift
                .select(CookSession.selectColumns)
```

In `ios/Sous/CookModeView.swift`, replace line 165:

```swift
                .select("id,recipe_id,started_at,completed_at").single().execute().value
```

with:

```swift
                .select(CookSession.selectColumns).single().execute().value
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd ios && xcodegen generate && xcodebuild test -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' 2>&1 | tail -30`

Expected: PASS, full suite, no regressions.

- [ ] **Step 6: Commit**

```bash
git add ios/Sous/Models.swift ios/Sous/AppModel.swift ios/Sous/CookModeView.swift ios/SousTests/CookSessionModelTests.swift
git commit -m "feat(ios): add CookSession.photoUrl, derive its select clause from CodingKeys"
```

---

## Task 4: `CookTimerModel` — wall-clock step + background timers, local notifications

**Files:**
- Create: `ios/Sous/CookTimerModel.swift`
- Modify: `ios/Sous/SousApp.swift` (foreground notification presentation + haptic)
- Test: Create `ios/SousTests/CookTimerModelTests.swift`

**Interfaces:**
- Produces: `struct CookTimer` (`id`, `label`, `duration`, `remaining(now:)`,
  `isComplete(now:)`, `isRunning`); `protocol TimerNotificationScheduling`;
  `struct LocalNotificationScheduler: TimerNotificationScheduling`; `@MainActor final
  class CookTimerModel: ObservableObject` with `@Published private(set) var stepTimer:
  CookTimer?`, `@Published private(set) var backgroundTimers: [CookTimer]`,
  `setStepTimer(label:duration:)`, `toggleStepTimerPause()`,
  `addBackgroundTimer(label:duration:) -> UUID`, `togglePause(id:)`,
  `removeBackgroundTimer(id:)`.
- Consumes: nothing from earlier tasks.

- [ ] **Step 1: Write the failing tests**

Create `ios/SousTests/CookTimerModelTests.swift`:

```swift
import XCTest
@testable import Sous

final class FakeNotificationScheduler: TimerNotificationScheduling {
    private(set) var scheduled: [(id: UUID, label: String, fireAt: Date)] = []
    private(set) var cancelled: [UUID] = []

    func schedule(id: UUID, label: String, fireAt: Date) {
        scheduled.append((id, label, fireAt))
    }

    func cancel(id: UUID) {
        cancelled.append(id)
    }
}

final class CookTimerModelTests: XCTestCase {
    // MARK: CookTimer — pure wall-clock math

    func testRemainingComputedFromEndTimeNotDecremented() {
        var timer = CookTimer(label: "步驟", duration: 300)
        timer.endTime = Date().addingTimeInterval(300)
        let remainingNow = timer.remaining(now: Date())
        let remainingLater = timer.remaining(now: Date().addingTimeInterval(10))
        XCTAssertEqual(remainingNow, 300, accuracy: 0.5)
        XCTAssertEqual(remainingLater, 290, accuracy: 0.5)
    }

    func testRemainingNeverGoesNegative() {
        var timer = CookTimer(label: "步驟", duration: 10)
        timer.endTime = Date().addingTimeInterval(-5)
        XCTAssertEqual(timer.remaining(), 0)
    }

    func testIsCompleteWhenPastEndTime() {
        var timer = CookTimer(label: "步驟", duration: 10)
        timer.endTime = Date().addingTimeInterval(-1)
        XCTAssertTrue(timer.isComplete())
    }

    func testIsRunningReflectsEndTimePresence() {
        var timer = CookTimer(label: "步驟", duration: 10)
        XCTAssertFalse(timer.isRunning)
        timer.endTime = Date().addingTimeInterval(10)
        XCTAssertTrue(timer.isRunning)
    }

    // MARK: CookTimerModel — step timer

    func testSetStepTimerStartsRunningAndSchedulesNotification() {
        let scheduler = FakeNotificationScheduler()
        let model = CookTimerModel(scheduler: scheduler)
        model.setStepTimer(label: "步驟 一", duration: 120)
        XCTAssertEqual(model.stepTimer?.isRunning, true)
        XCTAssertEqual(model.stepTimer?.remaining() ?? 0, 120, accuracy: 0.5)
        XCTAssertEqual(scheduler.scheduled.count, 1)
        XCTAssertEqual(scheduler.scheduled.first?.label, "步驟 一")
    }

    func testSetStepTimerReplacesPreviousAndCancelsItsNotification() {
        let scheduler = FakeNotificationScheduler()
        let model = CookTimerModel(scheduler: scheduler)
        model.setStepTimer(label: "步驟 一", duration: 120)
        let firstId = model.stepTimer!.id
        model.setStepTimer(label: "步驟 二", duration: 60)
        XCTAssertNotEqual(model.stepTimer!.id, firstId)
        XCTAssertEqual(scheduler.cancelled, [firstId])
        XCTAssertEqual(scheduler.scheduled.count, 2)
    }

    func testToggleStepTimerPausePreservesRemainingTime() {
        let scheduler = FakeNotificationScheduler()
        let model = CookTimerModel(scheduler: scheduler)
        model.setStepTimer(label: "步驟", duration: 100)
        model.toggleStepTimerPause() // pause
        XCTAssertFalse(model.stepTimer!.isRunning)
        let pausedRemaining = model.stepTimer!.remainingAtPause
        XCTAssertEqual(pausedRemaining, 100, accuracy: 0.5)
        model.toggleStepTimerPause() // resume
        XCTAssertTrue(model.stepTimer!.isRunning)
        XCTAssertEqual(model.stepTimer!.remaining(), 100, accuracy: 0.5)
    }

    // MARK: CookTimerModel — background timers independent of the step timer

    func testBackgroundTimerSurvivesStepTimerReplacement() {
        let scheduler = FakeNotificationScheduler()
        let model = CookTimerModel(scheduler: scheduler)
        let riceId = model.addBackgroundTimer(label: "白飯", duration: 600)
        model.setStepTimer(label: "步驟 一", duration: 60)
        model.setStepTimer(label: "步驟 二", duration: 60)
        XCTAssertEqual(model.backgroundTimers.first(where: { $0.id == riceId })?.remaining() ?? 0,
                       600, accuracy: 0.5)
    }

    func testPausingStepTimerDoesNotPauseBackgroundTimers() {
        let scheduler = FakeNotificationScheduler()
        let model = CookTimerModel(scheduler: scheduler)
        let riceId = model.addBackgroundTimer(label: "白飯", duration: 600)
        model.setStepTimer(label: "步驟", duration: 60)
        model.toggleStepTimerPause()
        XCTAssertTrue(model.backgroundTimers.first(where: { $0.id == riceId })!.isRunning)
    }

    func testMultipleBackgroundTimersPauseIndependently() {
        let scheduler = FakeNotificationScheduler()
        let model = CookTimerModel(scheduler: scheduler)
        let riceId = model.addBackgroundTimer(label: "白飯", duration: 600)
        let soupId = model.addBackgroundTimer(label: "湯", duration: 900)
        model.togglePause(id: riceId)
        XCTAssertFalse(model.backgroundTimers.first(where: { $0.id == riceId })!.isRunning)
        XCTAssertTrue(model.backgroundTimers.first(where: { $0.id == soupId })!.isRunning)
    }

    func testRemoveBackgroundTimerCancelsNotificationAndRemovesIt() {
        let scheduler = FakeNotificationScheduler()
        let model = CookTimerModel(scheduler: scheduler)
        let riceId = model.addBackgroundTimer(label: "白飯", duration: 600)
        model.removeBackgroundTimer(id: riceId)
        XCTAssertTrue(scheduler.cancelled.contains(riceId))
        XCTAssertFalse(model.backgroundTimers.contains { $0.id == riceId })
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ios && xcodegen generate && xcodebuild test -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' -only-testing:SousTests/CookTimerModelTests 2>&1 | tail -30`

Expected: FAIL to compile — none of these types exist yet.

- [ ] **Step 3: Implement `CookTimerModel.swift`**

Create `ios/Sous/CookTimerModel.swift`:

```swift
// ios/Sous/CookTimerModel.swift
import Foundation
import UserNotifications

/// A single timer — the step timer or one background timer — expressed as an absolute
/// end-time rather than a countdown, so remaining time is always correct from the wall
/// clock alone: no invalidation bookkeeping needed across step navigation,
/// backgrounding, or app relaunch (design spec: "pausing the step timer must not pause
/// the rice").
struct CookTimer: Identifiable, Equatable {
    let id: UUID
    var label: String
    let duration: TimeInterval
    var endTime: Date?              // nil while paused or not yet started
    var remainingAtPause: TimeInterval

    init(id: UUID = UUID(), label: String, duration: TimeInterval) {
        self.id = id
        self.label = label
        self.duration = duration
        self.endTime = nil
        self.remainingAtPause = duration
    }

    var isRunning: Bool { endTime != nil }

    func remaining(now: Date = Date()) -> TimeInterval {
        guard let endTime else { return remainingAtPause }
        return max(0, endTime.timeIntervalSince(now))
    }

    func isComplete(now: Date = Date()) -> Bool {
        remaining(now: now) <= 0
    }
}

/// Abstracts local-notification scheduling so `CookTimerModel` is testable without a
/// real `UNUserNotificationCenter` (simulator/CI can't reliably assert on delivered
/// notifications). `LocalNotificationScheduler` is the real implementation; tests inject
/// a fake.
protocol TimerNotificationScheduling {
    func schedule(id: UUID, label: String, fireAt: Date)
    func cancel(id: UUID)
}

struct LocalNotificationScheduler: TimerNotificationScheduling {
    func schedule(id: UUID, label: String, fireAt: Date) {
        let content = UNMutableNotificationContent()
        content.title = label
        content.body = "時間到了。"
        content.sound = .default
        let interval = max(0.01, fireAt.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: id.uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    func cancel(id: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id.uuidString])
    }
}

/// The step timer and any number of independent background timers (e.g. rice, soup).
/// Every start/resume schedules exactly one local notification per timer so it pings
/// even if the user has switched apps; every pause/removal cancels it. Permission denial
/// degrades silently to wall-clock-only — starting a timer is never blocked on it.
@MainActor
final class CookTimerModel: ObservableObject {
    @Published private(set) var stepTimer: CookTimer?
    @Published private(set) var backgroundTimers: [CookTimer] = []

    private let scheduler: TimerNotificationScheduling
    private var didRequestNotificationPermission = false

    init(scheduler: TimerNotificationScheduling = LocalNotificationScheduler()) {
        self.scheduler = scheduler
    }

    private func requestNotificationPermissionIfNeeded() {
        guard !didRequestNotificationPermission else { return }
        didRequestNotificationPermission = true
        Task {
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        }
    }

    // MARK: step timer — replaced wholesale on every step change, never paused across
    // step navigation (advancing the step always starts a fresh timer for the new step)

    func setStepTimer(label: String, duration: TimeInterval) {
        if let old = stepTimer { scheduler.cancel(id: old.id) }
        var timer = CookTimer(label: label, duration: duration)
        start(&timer)
        stepTimer = timer
    }

    func toggleStepTimerPause() {
        guard var timer = stepTimer else { return }
        if timer.isRunning { pause(&timer) } else { start(&timer) }
        stepTimer = timer
    }

    // MARK: background timers — independent of the step timer and of each other

    @discardableResult
    func addBackgroundTimer(label: String, duration: TimeInterval) -> UUID {
        var timer = CookTimer(label: label, duration: duration)
        start(&timer)
        backgroundTimers.append(timer)
        return timer.id
    }

    func togglePause(id: UUID) {
        guard let index = backgroundTimers.firstIndex(where: { $0.id == id }) else { return }
        var timer = backgroundTimers[index]
        if timer.isRunning { pause(&timer) } else { start(&timer) }
        backgroundTimers[index] = timer
    }

    func removeBackgroundTimer(id: UUID) {
        scheduler.cancel(id: id)
        backgroundTimers.removeAll { $0.id == id }
    }

    // MARK: shared start/pause mechanics

    private func start(_ timer: inout CookTimer) {
        requestNotificationPermissionIfNeeded()
        let end = Date().addingTimeInterval(timer.remainingAtPause)
        timer.endTime = end
        scheduler.schedule(id: timer.id, label: timer.label, fireAt: end)
    }

    private func pause(_ timer: inout CookTimer) {
        timer.remainingAtPause = timer.remaining()
        timer.endTime = nil
        scheduler.cancel(id: timer.id)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ios && xcodegen generate && xcodebuild test -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' -only-testing:SousTests/CookTimerModelTests 2>&1 | tail -30`

Expected: PASS, all 12 tests.

- [ ] **Step 5: Foreground notification presentation + haptic**

Local notifications don't show a banner or play sound while the app is foreground
unless a `UNUserNotificationCenterDelegate` opts in — and the README requires "a haptic
**and** a sound" on completion regardless of foreground state. `SousAppDelegate`
(`ios/Sous/SousApp.swift`) already owns app-lifecycle/notification concerns (device
token registration) — add the delegate conformance there rather than inventing a new
lifecycle object.

Replace `ios/Sous/SousApp.swift` in full:

```swift
import SwiftUI
import UIKit
import UserNotifications

final class SousAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NotificationCenter.default.post(name: .sousDidRegisterDeviceToken, object: nil,
                                         userInfo: ["tokenHex": hexString(deviceToken)])
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NotificationCenter.default.post(name: .sousDidFailToRegisterDeviceToken, object: nil,
                                         userInfo: ["message": error.localizedDescription])
    }

    /// Cook-mode timers rely on this to satisfy "timers fire a haptic and a sound" even
    /// while the app is in the foreground — without it, a foreground local notification
    /// is silently suppressed. Push notifications (the other user of this delegate)
    /// don't fire while foreground in this app's flows, so this doesn't change their
    /// behaviour.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // Haptics are main-thread UIKit calls; this delegate callback isn't guaranteed
        // to run on main, so hop explicitly rather than assume.
        await MainActor.run {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        return [.banner, .sound]
    }
}

extension Notification.Name {
    static let sousDidRegisterDeviceToken = Notification.Name("sousDidRegisterDeviceToken")
    static let sousDidFailToRegisterDeviceToken = Notification.Name("sousDidFailToRegisterDeviceToken")
}

@main
struct SousApp: App {
    @UIApplicationDelegateAdaptor(SousAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            Group {
                if model.session == nil {
                    AuthView()
                } else {
                    CounterView()
                }
            }
            .environmentObject(model)
            .task { await model.restoreSession() }
        }
    }
}
```

(`hexString(_:)` is defined in `ios/Sous/NotificationsLogic.swift`, not this file — this
full-file replace doesn't need to preserve or duplicate it.)

- [ ] **Step 6: Build**

Run: `cd ios && xcodegen generate && xcodebuild build -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' 2>&1 | tail -20`

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 7: Commit**

```bash
git add ios/Sous/CookTimerModel.swift ios/Sous/SousApp.swift ios/SousTests/CookTimerModelTests.swift
git commit -m "feat(ios): add CookTimerModel with wall-clock step + background timers"
```

---

## Task 5: `CrossingTransition` — the shared 過場 component

**Files:**
- Create: `ios/Sous/CrossingTransition.swift`
- Test: Create `ios/SousTests/CrossingChoreographyTests.swift`

**Interfaces:**
- Consumes: `StageTokens` (Task 1).
- Produces: `@MainActor final class CrossingChoreography: ObservableObject` (`paperVisible`,
  `stageVisible` — tree-presence, unanimated; `paperDimmed` — bool driving
  colorMultiply/saturation; `stageOpacity`, `glowOpacity` — animated `Double`s, the
  actual cross-fade; `setInitial(showingStage:)`, `crossToStage(reduceMotion:onSettled:)`,
  `crossToPaper(reduceMotion:onSettled:)`); `struct CrossingTransition<Paper: View, Stage:
  View>: View` — Tasks 6/8 wrap C1↔C2 and C3↔C4 in this.

**Design note — why opacity, not conditional presence, drives the fade:** toggling a
bare `Bool` that gates `if choreography.stageVisible { stage() }` pops the view in or
out instantly, even inside `withAnimation` — SwiftUI only animates a conditional's
insertion/removal via an explicit `.transition`, which doesn't compose cleanly with
this class's separately-timed, `asyncAfter`-staggered `withAnimation` blocks (dim at
0ms, cross-fade at 340ms, glow at 500ms — three different delays within one state
change). So `stageVisible`/`paperVisible` only toggle tree presence at the very start
(insert before fading in) and very end (remove after fully faded out) of each crossing,
when the layer is already fully transparent or fully opaque; the actual fade is a
continuously-rendered view's `.opacity()` animating between 0 and 1 via
`stageOpacity`/`glowOpacity`.

- [ ] **Step 1: Write the failing tests**

Create `ios/SousTests/CrossingChoreographyTests.swift`:

```swift
import XCTest
@testable import Sous

final class CrossingChoreographyTests: XCTestCase {
    @MainActor
    func testSetInitialToStageShowsOnlyStage() {
        let choreography = CrossingChoreography()
        choreography.setInitial(showingStage: true)
        XCTAssertFalse(choreography.paperVisible)
        XCTAssertTrue(choreography.stageVisible)
        XCTAssertEqual(choreography.stageOpacity, 1)
        XCTAssertEqual(choreography.glowOpacity, 1)
    }

    @MainActor
    func testSetInitialToPaperShowsOnlyPaper() {
        let choreography = CrossingChoreography()
        choreography.setInitial(showingStage: false)
        XCTAssertTrue(choreography.paperVisible)
        XCTAssertFalse(choreography.stageVisible)
        XCTAssertEqual(choreography.stageOpacity, 0)
        XCTAssertEqual(choreography.glowOpacity, 0)
    }

    @MainActor
    func testCrossToStageDimsPaperImmediately() {
        let choreography = CrossingChoreography()
        choreography.setInitial(showingStage: false)
        choreography.crossToStage(reduceMotion: false)
        XCTAssertTrue(choreography.paperDimmed)
        XCTAssertTrue(choreography.paperVisible) // still visible under the dim, briefly
        XCTAssertTrue(choreography.stageVisible) // in the tree, still transparent
    }

    @MainActor
    func testCrossToStageEndsWithOnlyStageVisible() {
        let choreography = CrossingChoreography()
        choreography.setInitial(showingStage: false)
        let expectation = expectation(description: "crossing settles")
        choreography.crossToStage(reduceMotion: false) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
        XCTAssertFalse(choreography.paperVisible)
        XCTAssertTrue(choreography.stageVisible)
        XCTAssertEqual(choreography.stageOpacity, 1)
        XCTAssertEqual(choreography.glowOpacity, 1)
    }

    @MainActor
    func testCrossToPaperEndsWithOnlyPaperVisible() {
        let choreography = CrossingChoreography()
        choreography.setInitial(showingStage: true)
        let expectation = expectation(description: "crossing settles")
        choreography.crossToPaper(reduceMotion: false) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
        XCTAssertTrue(choreography.paperVisible)
        XCTAssertFalse(choreography.stageVisible)
        XCTAssertFalse(choreography.paperDimmed)
        XCTAssertEqual(choreography.stageOpacity, 0)
        XCTAssertEqual(choreography.glowOpacity, 0)
    }

    @MainActor
    func testReduceMotionSettlesImmediately() {
        let choreography = CrossingChoreography()
        choreography.setInitial(showingStage: false)
        choreography.crossToStage(reduceMotion: true)
        XCTAssertFalse(choreography.paperVisible)
        XCTAssertTrue(choreography.stageVisible)
        XCTAssertEqual(choreography.stageOpacity, 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ios && xcodegen generate && xcodebuild test -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' -only-testing:SousTests/CrossingChoreographyTests 2>&1 | tail -30`

Expected: FAIL to compile — `CrossingChoreography` doesn't exist yet.

- [ ] **Step 3: Implement**

Create `ios/Sous/CrossingTransition.swift`:

```swift
// ios/Sous/CrossingTransition.swift
import SwiftUI

/// The imperative state machine behind 過場 · the crossing (README §Motion): paper
/// dims in place (620ms), the stage cross-fades in starting at 340ms, and its glow
/// arrives last at 500ms — light comes on last, the way a gas ring does. Reversed and
/// ~220ms faster on the way back to paper. Expressed as explicit, individually staged
/// `withAnimation` calls (not a single declarative `.animation(value:)`) because each
/// layer needs its own delay within one state transition, which a single implicit
/// animation modifier can't express.
///
/// `onSettled` is called once the full sequence completes — used by tests to assert on
/// end state without hand-rolling delays, and unused (nil) by real call sites.
@MainActor
final class CrossingChoreography: ObservableObject {
    @Published private(set) var paperVisible = true
    @Published private(set) var stageVisible = false
    @Published private(set) var paperDimmed = false
    @Published private(set) var stageOpacity: Double = 0
    @Published private(set) var glowOpacity: Double = 0

    func setInitial(showingStage: Bool) {
        paperVisible = !showingStage
        stageVisible = showingStage
        paperDimmed = showingStage
        stageOpacity = showingStage ? 1 : 0
        glowOpacity = showingStage ? 1 : 0
    }

    func crossToStage(reduceMotion: Bool, onSettled: (() -> Void)? = nil) {
        if reduceMotion {
            withAnimation(.linear(duration: 0.14)) {
                paperDimmed = true
                stageOpacity = 1
                glowOpacity = 1
            }
            stageVisible = true
            paperVisible = false
            onSettled?()
            return
        }
        stageVisible = true // in the tree, still transparent — the 340ms fade-in has something to animate
        withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.62)) {
            paperDimmed = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) { [weak self] in
            withAnimation(.timingCurve(0.2, 0.8, 0.3, 1, duration: 0.28)) {
                self?.stageOpacity = 1
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            withAnimation(.timingCurve(0.2, 0.8, 0.3, 1, duration: 0.3)) {
                self?.glowOpacity = 1
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.94) { [weak self] in
            self?.paperVisible = false
            onSettled?()
        }
    }

    func crossToPaper(reduceMotion: Bool, onSettled: (() -> Void)? = nil) {
        if reduceMotion {
            withAnimation(.linear(duration: 0.14)) {
                paperDimmed = false
                stageOpacity = 0
                glowOpacity = 0
            }
            paperVisible = true
            stageVisible = false
            onSettled?()
            return
        }
        paperVisible = true // in the tree again, still dimmed — the fade back has something to land on
        withAnimation(.timingCurve(0.2, 0.8, 0.3, 1, duration: 0.3)) {
            glowOpacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            withAnimation(.timingCurve(0.2, 0.8, 0.3, 1, duration: 0.22)) {
                self?.stageOpacity = 0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.5)) {
                self?.paperDimmed = false
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.72) { [weak self] in
            self?.stageVisible = false
            onSettled?()
        }
    }
}

/// One shared crossing implementation used both directions (C1→C2 in `CookModeView`,
/// C3→C4 on the way back) so the choreography can't drift between call sites.
/// `showingStage` drives which side settles; toggling it plays the corresponding
/// direction. `paper`/`stage` are continuously rendered while their tree-presence flag
/// is true — the fade itself is `stageOpacity`/`glowOpacity`, not insertion/removal.
struct CrossingTransition<Paper: View, Stage: View>: View {
    let showingStage: Bool
    @ViewBuilder var paper: () -> Paper
    @ViewBuilder var stage: () -> Stage

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var choreography = CrossingChoreography()
    @State private var hasAppeared = false

    var body: some View {
        ZStack {
            if choreography.paperVisible {
                paper()
                    .colorMultiply(Color(white: choreography.paperDimmed ? 0.28 : 1.0))
                    .saturation(choreography.paperDimmed ? 0.4 : 1.0)
            }
            if choreography.stageVisible {
                stage()
                    .opacity(choreography.stageOpacity)
                    .overlay(alignment: .bottom) {
                        StageTokens.glow
                            .frame(height: 160)
                            .opacity(choreography.glowOpacity)
                            .allowsHitTesting(false)
                    }
            }
        }
        .onAppear {
            guard !hasAppeared else { return }
            hasAppeared = true
            choreography.setInitial(showingStage: showingStage)
        }
        .onChange(of: showingStage) { _, newValue in
            if newValue {
                choreography.crossToStage(reduceMotion: reduceMotion)
            } else {
                choreography.crossToPaper(reduceMotion: reduceMotion)
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ios && xcodegen generate && xcodebuild test -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' -only-testing:SousTests/CrossingChoreographyTests 2>&1 | tail -30`

Expected: PASS, all 6 tests (the two `wait(for:timeout: 2.0)` tests take ~1s of real
wall time each — that's expected, not a hang).

**Acceptance (visual, checked in Task 6/8's manual verification, not here):**
`CrossingTransition` compiles standalone; not wired into `CookModeView` yet.

- [ ] **Step 5: Commit**

```bash
git add ios/Sous/CrossingTransition.swift ios/SousTests/CrossingChoreographyTests.swift
git commit -m "feat(ios): add CrossingTransition, the shared 過場 paper/stage component"
```

---

## Task 6: C1 備料 restyle + crossing into C2

**Files:** Modify `ios/Sous/CookModeView.swift` (currently 197 lines — the whole file).

**Design reference:** README "C1 · 備料 (mise en place — still paper)".

**Interfaces:**
- Consumes: `CrossingTransition` (Task 5), `CookTimerModel` (Task 4, wired but not yet
  used by this task's phase — Task 7 consumes it).
- Produces: the restructured `phase` enum (`.prep, .cooking, .plateUp, .verdict, .done`
  — `.plateUp` is new, since the current implementation has no 上菜 step at all; Task 8
  gives it content) that Tasks 7-9 build on.

This task is not TDD-shaped (visual restyle, same as Pass 1a/1b's screen tasks) —
explicit acceptance bar in place of tests. `isChecklistComplete` (`CookModeLogic.swift`)
is unchanged; only the checklist's presentation changes.

- [ ] **Step 1: Restructure phases and add shared state**

Replace `ios/Sous/CookModeView.swift:1-37` (imports through `init`):

```swift
// ios/Sous/CookModeView.swift
import SwiftUI

/// C1-C4 · 備料/灶前/上菜/講評 — Reference: design_handoff_sous_m3/README.md §C1-C4 and
/// docs/superpowers/specs/2026-08-07-m3-visual-restyle-pass1c-cook-mode-design.md.
/// `.plateUp` (上菜, photo capture) is a new phase this pass adds — the pre-Pass-1c
/// flow jumped straight from the last teleprompter step to the verdict, skipping photo
/// capture entirely. C4 (講評) is restyled only, per the design spec: grading stays a
/// direct user pick (神作/不錯/普通/翻車), no blind-reveal/brain-write — that's Pass 2.
struct CookModeView: View {
    let recipe: Recipe
    let planDay: PlanDay?
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var checked: [Bool]
    @State private var phase: Phase = .prep
    @State private var stepIndex = 0
    @State private var showStepList = false
    @State private var sessionId: UUID?
    @State private var rating: String?
    @State private var note = ""
    @State private var capturedPhotoData: Data?
    @StateObject private var timerModel = CookTimerModel()

    private enum Phase { case prep, cooking, plateUp, verdict, done }

    /// Drives `CrossingTransition` — true for both dark phases (C2 teleprompter, C3
    /// 上菜), false for the paper phases either side of them.
    private var showingStage: Bool { phase == .cooking || phase == .plateUp }

    init(recipe: Recipe, planDay: PlanDay?) {
        self.recipe = recipe
        self.planDay = planDay
        _checked = State(initialValue: Array(repeating: false, count: recipe.ingredients.count))
    }

    private var serifName: String { serifFontName(bundled: FontBook.isSerifBundled) }
    private var sansName: String { sansFontName(bundled: FontBook.isSansBundled) }
```

- [ ] **Step 2: Replace `body` to route through the crossing**

Replace the old `body` (originally lines 26-37):

```swift
    var body: some View {
        CrossingTransition(showingStage: showingStage) {
            paperContent
        } stage: {
            stageContent
        }
        .task { await startSession() }
    }

    @ViewBuilder
    private var paperContent: some View {
        switch phase {
        case .prep: prepChecklist
        case .verdict: verdictPrompt
        case .done: doneView
        case .cooking, .plateUp: EmptyView() // unreachable — those phases render via stageContent
        }
    }

    @ViewBuilder
    private var stageContent: some View {
        switch phase {
        case .cooking: teleprompter
        case .plateUp: plateUpCapture // Task 8 gives this real content
        case .prep, .verdict, .done: EmptyView() // unreachable — those phases render via paperContent
        }
    }
```

(`plateUpCapture` is a placeholder stub for this task — Task 8 replaces it. Add a
minimal stub now so the file compiles:)

```swift
    private var plateUpCapture: some View {
        Color(StageTokens.bg).ignoresSafeArea()
    }
```

- [ ] **Step 3: Restyle `prepChecklist` to the paper system**

Replace the old `prepChecklist` (originally lines 39-66):

```swift
    private var prepChecklist: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("備　料")
                    .font(.custom(sansName, size: 10))
                    .tracking(4.2)
                    .foregroundStyle(PaperTokens.inkFaint)
                    .padding(.top, Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .center)

                ForEach(recipe.ingredients.indices, id: \.self) { i in
                    checklistRow(index: i)
                }

                Spacer(minLength: Spacing.lg)

                Button {
                    beginCooking()
                } label: {
                    Text("開始烹飪")
                        .font(.custom(sansName, size: 13.5))
                        .tracking(2.6)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .foregroundStyle(PaperTokens.stock)
                        .background(model.personaTint)
                }
                .disabled(!recipe.ingredients.isEmpty && !isChecklistComplete(checked))

                Text("開始後,廚房會轉為烹飪模式 — 隨時可以回來這一頁。")
                    .font(.system(size: 10.5))
                    .tracking(1.1)
                    .foregroundStyle(PaperTokens.inkDim)
                    .padding(.top, Spacing.sm)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, Spacing.pageMargin)
        }
        .background(PaperTokens.stock)
    }

    private func checklistRow(index i: Int) -> some View {
        Button {
            checked[i].toggle()
        } label: {
            HStack(spacing: Spacing.md) {
                checklistCheckbox(checked: checked[i])
                Text(recipe.ingredients[i].name)
                    .font(.custom(serifName, size: 16))
                    .foregroundStyle(PaperTokens.ink)
                Spacer(minLength: 0)
                if let qty = recipe.ingredients[i].qty {
                    Text(qty)
                        .font(.custom(serifName, size: 14))
                        .foregroundStyle(PaperTokens.inkDim)
                        .monospacedDigit()
                }
            }
            .padding(.vertical, 15)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Rectangle().fill(PaperTokens.rule).frame(height: 1) }
    }

    private func checklistCheckbox(checked: Bool) -> some View {
        ZStack {
            if checked {
                Rectangle().fill(model.personaTint)
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(PaperTokens.stock)
            } else {
                Rectangle().stroke(PaperTokens.ruleStrong, lineWidth: 1)
            }
        }
        .frame(width: 24, height: 24)
    }

    private func beginCooking() {
        phase = .cooking
        // Only steps with an explicit duration get a timer — matches the teleprompter's
        // own conditional ring display (Task 7) and the original file's precedent of
        // only showing a duration line `if let duration = ...`. A step with no duration
        // starting a 0-second timer would fire an immediate, spurious "time's up".
        if let duration = recipe.steps.first?.durationSec {
            timerModel.setStepTimer(label: "步驟 \(chineseNumeral(1))", duration: TimeInterval(duration))
        }
    }
```

(Checkbox/row treatment matches `ShoppingListView`'s established 56pt/24×24 idiom
exactly — same pattern, different data source.)

- [ ] **Step 4: Build**

Run: `cd ios && xcodegen generate && xcodebuild build -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' 2>&1 | tail -20`

Expected: `BUILD SUCCEEDED`. (The old `teleprompter`/`verdictPrompt`/`doneView`/
`startSession`/`finishCooking`/`submitVerdict` bodies from the original file are
untouched by this task's edits — they still reference the old `Phase` cases correctly,
since `.prep`/`.verdict`/`.done` are unchanged and `.cooking` still exists. Only
`finishCooking()`'s target phase needs a look — Task 8 updates it to route through
`.plateUp` instead of straight to `.verdict`/`.done`; leave it as-is for this task, it
still compiles.)

- [ ] **Step 5: Run full test suite**

Run: `cd ios && xcodebuild test -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' 2>&1 | tail -30`

Expected: PASS, no regressions (`CookModeLogicTests` untouched — `isChecklistComplete`,
`clampedStepIndex`, `makeVerdictPayload` are all unchanged).

**Acceptance:** Simulator: 備料 checklist shows 56pt rows with the shopping-list-style
checkbox; `開始烹飪` is disabled until every ingredient is checked (or immediately
enabled if the recipe has zero ingredients, matching prior behavior); tapping it plays
the crossing (paper dims, teleprompter fades in from the stove) rather than an instant
cut.

- [ ] **Step 6: Commit**

```bash
git add ios/Sous/CookModeView.swift
git commit -m "feat(ios): restyle Cook Mode's 備料 checklist and wire the crossing into C2"
```

---

## Task 7: C2 灶前 restyle — teleprompter, step ring, background timers

**Files:** Modify `ios/Sous/CookModeView.swift` (post-Task 6 version).

**Design reference:** README "C2 · 灶前 (cook mode — dark)".

**Interfaces:**
- Consumes: `timerModel.stepTimer`/`.backgroundTimers` (Task 4), `StageTokens` (Task 1).

**Implementation call (not in the mockup — no UI is shown for *creating* a background
timer, only for rendering ones already running):** a small `+ 計時器` row below the
background timer list opens a lightweight inline form (label text field + minute
stepper). This is new chrome by necessity, same tier of decision as Pass 1b's unit
toggle placement — doesn't need a spec amendment.

- [ ] **Step 1: Replace `teleprompter`**

Replace the old `teleprompter` (originally lines 68-112) with:

```swift
    private var teleprompter: some View {
        VStack(spacing: 0) {
            HStack {
                Text("步驟 \(chineseNumeral(stepIndex + 1)) / \(chineseNumeral(recipe.steps.count))")
                    .font(.custom(sansName, size: 10))
                    .tracking(2.1)
                    .foregroundStyle(StageTokens.brass)
                Spacer()
                Button("步驟列表") { showStepList = true }
                    .font(.custom(sansName, size: 11))
                    .foregroundStyle(StageTokens.inkDim)
                    .frame(minHeight: 44)
            }
            .padding(.horizontal, Spacing.pageMargin)
            .padding(.top, Spacing.lg)

            stepProgressRule

            ScrollView {
                VStack(spacing: 18) {
                    if stepIndex > 0 {
                        Text(recipe.steps[stepIndex - 1].text)
                            .font(.custom(sansName, size: 15, relativeTo: .body))
                            .fontWeight(.light)
                            .foregroundStyle(StageTokens.inkDim.opacity(0.7))
                    }

                    Text(recipe.steps[stepIndex].text)
                        .font(.custom(serifName, size: 26))
                        .fontWeight(.light)
                        .lineSpacing(26 * 0.62)
                        .foregroundStyle(StageTokens.ink)
                        .multilineTextAlignment(.center)
                        .id(stepIndex) // forces the 140ms opacity swap README requires —
                                       // "no slide, the eye must not chase it at the stove"
                        .transition(.opacity.animation(.easeInOut(duration: 0.14)))
                        .accessibilityLabel(stepAccessibilityLabel)

                    if let tip = recipe.steps[stepIndex].tip {
                        HStack(alignment: .top, spacing: 10) {
                            Rectangle().fill(StageTokens.brass).frame(width: 1)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("小當家眉批")
                                    .font(.custom(sansName, size: 10))
                                    .tracking(2.8)
                                    .foregroundStyle(StageTokens.brass)
                                Text(tip)
                                    .font(.custom(sansName, size: 13))
                                    .fontWeight(.light)
                                    .foregroundStyle(StageTokens.brassSoft)
                            }
                        }
                        .padding(.leading, 14)
                    }

                    if let duration = recipe.steps[stepIndex].durationSec {
                        stepTimerRing(durationSec: duration)
                    }

                    if stepIndex < recipe.steps.count - 1 {
                        Text(recipe.steps[stepIndex + 1].text)
                            .font(.custom(sansName, size: 15, relativeTo: .body))
                            .fontWeight(.light)
                            .foregroundStyle(StageTokens.inkDim.opacity(0.55))
                    }

                    backgroundTimersSection
                }
                .padding(.horizontal, Spacing.pageMargin)
                .padding(.vertical, Spacing.lg)
            }

            footerControls
        }
        .background(StageTokens.bg)
        .onChange(of: stepIndex) { _, newValue in
            guard let duration = recipe.steps[newValue].durationSec else { return }
            timerModel.setStepTimer(label: "步驟 \(chineseNumeral(newValue + 1))",
                                    duration: TimeInterval(duration))
        }
        .sheet(isPresented: $showStepList) {
            List(recipe.steps.indices, id: \.self) { i in
                Button(recipe.steps[i].text) {
                    stepIndex = i
                    showStepList = false
                }
            }
        }
    }

    private var stepAccessibilityLabel: String {
        "步驟 \(chineseNumeral(stepIndex + 1)),\(recipe.steps[stepIndex].text)"
    }

    private var stepProgressRule: some View {
        HStack(spacing: 3) {
            ForEach(recipe.steps.indices, id: \.self) { i in
                Rectangle()
                    .fill(i <= stepIndex ? StageTokens.brass : StageTokens.rule)
                    .frame(height: 1)
            }
        }
        .padding(.horizontal, Spacing.pageMargin)
        .padding(.top, Spacing.sm)
    }

    private func stepTimerRing(durationSec: Int) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = timerModel.stepTimer?.remaining(now: context.date) ?? TimeInterval(durationSec)
            let progress = durationSec > 0 ? 1 - (remaining / TimeInterval(durationSec)) : 0
            let isPaused = timerModel.stepTimer?.isRunning == false

            ZStack {
                Circle().stroke(StageTokens.ink.opacity(0.12), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: max(0, min(1, progress)))
                    .stroke(StageTokens.brass, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Circle().fill(StageTokens.bg).frame(width: 104, height: 104)
                VStack(spacing: 2) {
                    Text(formattedRemaining(remaining))
                        .font(.custom(serifName, size: 26))
                        .monospacedDigit()
                        .foregroundStyle(StageTokens.ink)
                    Text(isPaused ? "暫停中" : "計時中")
                        .font(.custom(sansName, size: 10))
                        .tracking(1.4)
                        .foregroundStyle(StageTokens.inkDim)
                }
            }
            .frame(width: 118, height: 118)
            .onTapGesture { timerModel.toggleStepTimerPause() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "步驟計時器,剩\(formattedRemainingSpoken(remaining))," +
                "\(isPaused ? "暫停中" : "計時中")。輕點兩下\(isPaused ? "繼續" : "暫停")。"
            )
        }
    }

    private var backgroundTimersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(timerModel.backgroundTimers) { timer in
                backgroundTimerRow(timer)
            }
            Button {
                showAddTimerSheet = true
            } label: {
                Text("＋ 計時器")
                    .font(.custom(sansName, size: 12.5))
                    .foregroundStyle(StageTokens.inkDim)
            }
            .frame(minHeight: 44)
        }
        .sheet(isPresented: $showAddTimerSheet) { addTimerSheet }
    }

    private func backgroundTimerRow(_ timer: CookTimer) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = timer.remaining(now: context.date)
            HStack {
                Text(timer.label)
                    .font(.custom(sansName, size: 12.5))
                    .fontWeight(.light)
                    .foregroundStyle(StageTokens.inkDim)
                Spacer()
                Text(formattedRemaining(remaining))
                    .font(.custom(serifName, size: 19))
                    .monospacedDigit()
                    .foregroundStyle(StageTokens.brass)
                Button(timer.isRunning ? "暫停" : "繼續") {
                    timerModel.togglePause(id: timer.id)
                }
                .font(.custom(sansName, size: 11))
                .foregroundStyle(StageTokens.brass)
                .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(timer.label)計時器,剩\(formattedRemainingSpoken(remaining))," +
                "\(timer.isRunning ? "計時中" : "暫停中")。"
            )
        }
    }

    private var footerControls: some View {
        HStack {
            Button("← 上一步") {
                stepIndex = clampedStepIndex(stepIndex - 1, stepCount: recipe.steps.count)
            }
            .disabled(stepIndex == 0)
            .foregroundStyle(StageTokens.inkDim)
            .frame(minHeight: 44)
            Spacer()
            if stepIndex == recipe.steps.count - 1 {
                Button("上菜") { phase = .plateUp }
                    .font(.custom(sansName, size: 13.5))
                    .tracking(2.2)
                    .foregroundStyle(StageTokens.brass)
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .overlay(Rectangle().stroke(StageTokens.brass, lineWidth: 1))
                    .frame(minHeight: 44)
            } else {
                Button("下一步 →") {
                    stepIndex = clampedStepIndex(stepIndex + 1, stepCount: recipe.steps.count)
                }
                .font(.custom(sansName, size: 13.5))
                .tracking(2.2)
                .foregroundStyle(StageTokens.brass)
                .padding(.horizontal, 20).padding(.vertical, 12)
                .overlay(Rectangle().stroke(StageTokens.brass, lineWidth: 1))
                .frame(minHeight: 44)
            }
        }
        .padding(.horizontal, Spacing.pageMargin)
        .padding(.vertical, Spacing.md)
    }

    private var addTimerSheet: some View {
        NavigationStack {
            Form {
                TextField("名稱(例如:白飯)", text: $newTimerLabel)
                Stepper("\(newTimerMinutes) 分鐘", value: $newTimerMinutes, in: 1...180)
            }
            .navigationTitle("新增計時器")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("開始") {
                        timerModel.addBackgroundTimer(
                            label: newTimerLabel.isEmpty ? "計時器" : newTimerLabel,
                            duration: TimeInterval(newTimerMinutes * 60)
                        )
                        newTimerLabel = ""
                        newTimerMinutes = 10
                        showAddTimerSheet = false
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showAddTimerSheet = false }
                }
            }
        }
    }

    private func formattedRemaining(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func formattedRemainingSpoken(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let minutes = total / 60
        let secs = total % 60
        return minutes > 0 ? "\(minutes)分\(secs)秒" : "\(secs)秒"
    }
```

- [ ] **Step 2: Add the new `@State` this task needs**

Alongside the `@State`/`@StateObject` properties Task 6 added, add:

```swift
    @State private var showAddTimerSheet = false
    @State private var newTimerLabel = ""
    @State private var newTimerMinutes = 10
```

- [ ] **Step 3: Build**

Run: `cd ios && xcodegen generate && xcodebuild build -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' 2>&1 | tail -20`

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Run full test suite**

Run: `cd ios && xcodebuild test -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' 2>&1 | tail -30`

Expected: PASS, no regressions.

**Acceptance:** Simulator walkthrough of a recipe with at least one step that has
`durationSec` set: the step ring appears, counts down once per second, tapping it
pauses/resumes (label switches 計時中/暫停中); adding a background timer via `＋ 計時器`
shows it running independently — pausing the step timer does not pause it, and vice
versa; `上一步`/`下一步` navigate correctly, last step's button reads `上菜`; step text
changes with a quick fade, no slide.

- [ ] **Step 5: Commit**

```bash
git add ios/Sous/CookModeView.swift
git commit -m "feat(ios): restyle Cook Mode's 灶前 teleprompter with step ring and background timers"
```

---

## Task 8: C3 上菜 restyle — camera capture, storage upload

**Files:**
- Create: `ios/Sous/CameraCaptureView.swift`
- Modify: `ios/Sous/CookModeView.swift` (post-Task 7 version)
- Modify: `ios/Sous/AppModel.swift` (add `uploadCookPhoto`)
- Modify: `ios/project.yml` (camera/photo-library usage descriptions)

**Design reference:** README "C3 · 上菜 (plate up — dark, last dark screen)".

**Interfaces:**
- Consumes: `client.storage` (Supabase Storage, already-pinned SDK 2.52.0 —
  `StorageFileApi.upload(_:data:options:)` verified against the checked-out package
  source at `~/Library/Developer/Xcode/DerivedData/*/SourcePackages/checkouts/supabase-swift/Sources/Storage/StorageFileApi.swift`).
- Produces: `AppModel.uploadCookPhoto(sessionId:imageData:) async -> String?` — Task 10
  doesn't consume this directly but `downloadPhoto` (Task 10) is its read-side sibling.

- [ ] **Step 1: Info.plist usage descriptions**

`UIImagePickerController(sourceType: .camera)` requires `NSCameraUsageDescription` or
the app crashes on first camera access. The simulator has no camera, so this task also
falls back to `.photoLibrary` there (requires `NSPhotoLibraryUsageDescription`) so the
feature is testable without a real device.

In `ios/project.yml`, add to the `Sous` target's `info.properties` (after
`CFBundleDisplayName: Sous`, before `UIAppFonts:`):

```yaml
        NSCameraUsageDescription: 用來拍下你煮好的成品照。
        NSPhotoLibraryUsageDescription: 找不到相機時,用來選一張成品照。
```

- [ ] **Step 2: `CameraCaptureView` — system camera sheet wrapper**

Create `ios/Sous/CameraCaptureView.swift`:

```swift
// ios/Sous/CameraCaptureView.swift
import SwiftUI
import UIKit

/// Wraps `UIImagePickerController` for 上菜's `拍照` button — the system camera sheet,
/// not a bespoke `AVCaptureSession` view (design spec: too much camera-lifecycle code
/// for a screen used once per cook). Falls back to the photo library when no camera is
/// available (the simulator has none), so the feature is testable without a device.
struct CameraCaptureView: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraCaptureView
        init(_ parent: CameraCaptureView) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onCapture(image.croppedToSquare())
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

extension UIImage {
    /// Center-crops to a 1:1 square — the design's photo target is always square
    /// regardless of what aspect ratio the camera/library hands back.
    func croppedToSquare() -> UIImage {
        let side = min(size.width, size.height)
        let origin = CGPoint(x: (size.width - side) / 2, y: (size.height - side) / 2)
        guard let cgImage,
              let cropped = cgImage.cropping(to: CGRect(origin: origin, size: CGSize(width: side, height: side)))
        else { return self }
        return UIImage(cgImage: cropped, scale: scale, orientation: imageOrientation)
    }
}
```

- [ ] **Step 3: `AppModel.uploadCookPhoto`**

In `ios/Sous/AppModel.swift`, add directly after `loadCookbook()` (after the closing
brace that follows line 212):

```swift

    /// Uploads a captured 上菜 photo to the household-scoped `cook-photos` bucket and
    /// records its path on the session. Best-effort — matching `startSession()`'s
    /// precedent, a failed upload doesn't block finishing the cook; `photo_url` simply
    /// stays nil for that session.
    func uploadCookPhoto(sessionId: UUID, imageData: Data) async -> String? {
        guard let household else { return nil }
        let path = "\(household.id.uuidString)/\(sessionId.uuidString).jpg"
        do {
            try await client.storage.from("cook-photos")
                .upload(path, data: imageData, options: FileOptions(contentType: "image/jpeg", upsert: true))
            struct PhotoUpdate: Encodable { let photo_url: String }
            try await client.from("cook_sessions")
                .update(PhotoUpdate(photo_url: path))
                .eq("id", value: sessionId)
                .execute()
            return path
        } catch {
            print("cook photo upload: \(error)")
            return nil
        }
    }
```

- [ ] **Step 4: Wire C3 into `CookModeView`**

Replace the Task 6 stub `plateUpCapture`:

```swift
    private var plateUpCapture: some View {
        VStack(spacing: 24) {
            Text("上　菜")
                .font(.custom(sansName, size: 10))
                .tracking(4.0)
                .foregroundStyle(StageTokens.brass)
                .padding(.top, Spacing.lg)

            Text("收工了。\n拍一張,我來寫。")
                .font(.custom(serifName, size: 26))
                .fontWeight(.light)
                .multilineTextAlignment(.center)
                .foregroundStyle(StageTokens.ink)

            ZStack {
                if let capturedPhotoData, let uiImage = UIImage(data: capturedPhotoData) {
                    Image(uiImage: uiImage).resizable().scaledToFill()
                } else {
                    Rectangle().stroke(StageTokens.ink.opacity(0.22), lineWidth: 1)
                    Circle()
                        .stroke(StageTokens.brass, lineWidth: 1.5)
                        .frame(width: 50, height: 50)
                        .overlay(Circle().fill(StageTokens.brass).frame(width: 8, height: 8))
                }
            }
            .frame(width: 240, height: 240)
            .clipped()
            .onTapGesture { showCamera = true }

            Button("拍照") { showCamera = true }
                .font(.custom(sansName, size: 13.5))
                .tracking(2.2)
                .frame(minWidth: 160, minHeight: 50)
                .foregroundStyle(StageTokens.bg)
                .background(StageTokens.brass)

            Button("跳過,直接聽講評") { Task { await finishCooking() } }
                .font(.custom(sansName, size: 12))
                .foregroundStyle(StageTokens.inkDim)
                .frame(minHeight: 44)

            Text("寫好後會收進食譜本 —— 那一頁就多一行你的紀錄")
                .font(.system(size: 10.5))
                .foregroundStyle(StageTokens.inkDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.pageMargin)

            Spacer()
        }
        .padding(.horizontal, Spacing.pageMargin)
        .background(StageTokens.bg)
        .sheet(isPresented: $showCamera) {
            CameraCaptureView { image in
                capturedPhotoData = image.jpegData(compressionQuality: 0.85)
                Task { await finishCooking() }
            }
        }
    }
```

Add `@State private var showCamera = false` alongside the other `@State` properties.

- [ ] **Step 5: Update `finishCooking()` to upload in the background and route to C4**

Replace the old `finishCooking()`:

```swift
    private func finishCooking() async {
        if let sessionId {
            struct Complete: Encodable { let completed_at: String; let step_ticks: [Int] }
            let nowISO = ISO8601DateFormatter().string(from: Date())
            do {
                try await model.client.from("cook_sessions")
                    .update(Complete(completed_at: nowISO, step_ticks: Array(recipe.steps.indices)))
                    .eq("id", value: sessionId)
                    .execute()
            } catch { print("complete cook session: \(error)") }
            // Upload doesn't block the crossing back to paper — best-effort, per the
            // design spec's error handling section.
            if let capturedPhotoData {
                Task { _ = await model.uploadCookPhoto(sessionId: sessionId, imageData: capturedPhotoData) }
            }
            await model.loadCookbook()
        }
        phase = planDay != nil ? .verdict : .done
    }
```

(Note: `finishCooking()` is now called both from the last teleprompter step's route
through `.plateUp`'s 跳過/拍照 actions above — not directly from `teleprompter`'s footer
anymore, since Task 7's footer button now sets `phase = .plateUp` on the last step
instead of calling `finishCooking()`. Confirm no other call site still invokes
`finishCooking()` directly from the teleprompter footer.)

- [ ] **Step 6: Build**

Run: `cd ios && xcodegen generate && xcodebuild build -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' 2>&1 | tail -20`

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 7: Run full test suite**

Run: `cd ios && xcodebuild test -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' 2>&1 | tail -30`

Expected: PASS, no regressions.

**Acceptance:** Simulator (photo library fallback, since no camera): tapping `拍照`
opens the picker, picking an image crops it to square and shows it in the photo target,
then proceeds to C4. `跳過,直接聽講評` skips straight to C4 with no photo. After a real
capture, check (once Task 2's migration is applied) that `cook_sessions.photo_url` for
that session is set to `{household_id}/{session_id}.jpg` in the local Postgres.

- [ ] **Step 8: Commit**

```bash
git add ios/Sous/CameraCaptureView.swift ios/Sous/CookModeView.swift ios/Sous/AppModel.swift ios/project.yml
git commit -m "feat(ios): restyle Cook Mode's 上菜 with camera capture and storage upload"
```

---

## Task 9: C4 講評 restyle (visual only) + crossing back to paper

**Files:** Modify `ios/Sous/CookModeView.swift` (post-Task 8 version).

**Design reference:** README "C4 · 講評 (verdict — paper)" — **visual restyle only**,
per the design spec's scope decision: no blind-reveal, no 我同意/我不服, `rating` stays
a direct user pick. `doneView` is restyled alongside it since it's the same file's
paper-side finishing state, even though it isn't one of the README's four lettered
screens.

- [ ] **Step 1: Replace `verdictPrompt` and `doneView`**

Replace the old `verdictPrompt`:

```swift
    private var verdictPrompt: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("寫進書裡了").font(.custom(sansName, size: 10)).tracking(2.8)
                    .foregroundStyle(model.personaTint)
                Text("這頓煮得怎麼樣?")
                    .font(.custom(serifName, size: 22))
                    .foregroundStyle(PaperTokens.ink)

                VStack(spacing: 10) {
                    ForEach(["神作", "不錯", "普通", "翻車"], id: \.self) { option in
                        Button {
                            rating = option
                        } label: {
                            Text(option)
                                .font(.custom(serifName, size: 16))
                                .frame(maxWidth: .infinity, minHeight: 50)
                                .foregroundStyle(rating == option ? PaperTokens.stock : PaperTokens.ink)
                                .background(rating == option ? model.personaTint : Color.clear)
                                .overlay(Rectangle().stroke(PaperTokens.ruleStrong, lineWidth: 1))
                        }
                    }
                }

                TextField("備註(選填)", text: $note)
                    .font(.custom(sansName, size: 13))
                    .padding(12)
                    .overlay(Rectangle().stroke(PaperTokens.rule, lineWidth: 1))

                Button("送出") { Task { await submitVerdict() } }
                    .font(.custom(sansName, size: 13.5))
                    .tracking(2.2)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(PaperTokens.stock)
                    .background(rating == nil ? PaperTokens.inkDim.opacity(0.4) : model.personaTint)
                    .disabled(rating == nil)

                Button("略過") { phase = .done }
                    .font(.custom(sansName, size: 12))
                    .foregroundStyle(PaperTokens.inkDim)
                    .frame(minHeight: 44)
            }
            .padding(.horizontal, Spacing.pageMargin)
            .padding(.top, Spacing.lg)
        }
        .background(PaperTokens.stock)
    }
```

Replace the old `doneView`:

```swift
    private var doneView: some View {
        let count = cookCount(sessions: model.cookSessions, recipeId: recipe.id)
        return VStack(spacing: 16) {
            Spacer()
            Text("煮好了")
                .font(.custom(serifName, size: 26))
                .foregroundStyle(model.personaTint)
            if isMilestone(count) {
                Text(milestoneReactionText(count: count, template: model.personaCopy["cook_milestone_reaction"]))
                    .font(.custom(serifName, size: 14))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(PaperTokens.inkDim)
                    .padding(.horizontal, Spacing.pageMargin)
            } else if count > 0 {
                Text("已煮 \(chineseNumeral(count)) 次")
                    .font(.custom(sansName, size: 12.5))
                    .foregroundStyle(PaperTokens.inkDim)
            }
            Spacer()
            Button("關閉") { dismiss() }
                .font(.custom(sansName, size: 13.5))
                .tracking(2.2)
                .frame(maxWidth: .infinity, minHeight: 50)
                .foregroundStyle(PaperTokens.stock)
                .background(model.personaTint)
                .padding(.horizontal, Spacing.pageMargin)
        }
        .background(PaperTokens.stock)
    }
```

`submitVerdict()` is unchanged (still calls `makeVerdictPayload`/inserts into
`verdicts`) — only its callers' presentation changed.

- [ ] **Step 2: Build**

Run: `cd ios && xcodegen generate && xcodebuild build -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' 2>&1 | tail -20`

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Run full test suite**

Run: `cd ios && xcodebuild test -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' 2>&1 | tail -30`

Expected: PASS, no regressions (`makeVerdictPayload`/`VerdictPayload` unchanged).

**Acceptance:** Reaching C4 from C3 plays the crossing back to paper (stage dims out,
paper cross-fades up). Picking a rating and submitting inserts a `verdicts` row exactly
as before (unchanged data path); 略過 skips to `doneView`, which shows the milestone
copy or plain cook count as before, now paper-styled.

- [ ] **Step 4: Commit**

```bash
git add ios/Sous/CookModeView.swift
git commit -m "feat(ios): restyle Cook Mode's 講評 verdict and closing screen to paper"
```

---

## Task 10: `RecipePhotoCarousel` wired to real `cook_sessions` photos

**Files:**
- Modify: `ios/Sous/RecipePhotoCarousel.swift`
- Modify: `ios/Sous/RecipeDetailView.swift:72` (call site)
- Modify: `ios/Sous/CookHistoryLogic.swift` (add `cookPhotoPaths`)
- Modify: `ios/Sous/AppModel.swift` (add `downloadPhoto`)
- Test: `ios/SousTests/CookHistoryLogicTests.swift` (create if it doesn't already exist
  — `CookHistoryLogic.swift`'s existing functions currently have no dedicated test file;
  confirm before creating a duplicate)

**Interfaces:**
- Consumes: `CookSession.photoUrl` (Task 3).
- Produces: `cookPhotoPaths(sessions:recipeId:) -> [String]`;
  `AppModel.downloadPhoto(path:) async -> Data?`.

This closes the loop Pass 1b's spec explicitly left open: `RecipePhotoCarousel` was
placeholder-only because `cook_sessions.photo_url` didn't exist. It exists now (Task 2).

- [ ] **Step 1: Write the failing tests**

Check whether `ios/SousTests/CookHistoryLogicTests.swift` exists:

Run: `find ios/SousTests -iname "CookHistoryLogicTests.swift"`

If it exists, append the tests below inside its existing `final class`. If it doesn't,
create it fresh:

```swift
import XCTest
@testable import Sous

final class CookHistoryLogicTests: XCTestCase {
    private func session(recipeId: UUID, photoUrl: String?, startedAt: Date) -> CookSession {
        CookSession(id: UUID(), recipeId: recipeId, startedAt: startedAt,
                   completedAt: startedAt, photoUrl: photoUrl)
    }

    func testCookPhotoPathsFiltersToRecipeAndPresence() {
        let target = UUID()
        let other = UUID()
        let sessions = [
            session(recipeId: target, photoUrl: "a.jpg", startedAt: Date()),
            session(recipeId: target, photoUrl: nil, startedAt: Date()),
            session(recipeId: other, photoUrl: "b.jpg", startedAt: Date()),
        ]
        XCTAssertEqual(cookPhotoPaths(sessions: sessions, recipeId: target), ["a.jpg"])
    }

    func testCookPhotoPathsOrdersMostRecentFirst() {
        let recipeId = UUID()
        let older = session(recipeId: recipeId, photoUrl: "older.jpg",
                            startedAt: Date().addingTimeInterval(-3600))
        let newer = session(recipeId: recipeId, photoUrl: "newer.jpg", startedAt: Date())
        XCTAssertEqual(cookPhotoPaths(sessions: [older, newer], recipeId: recipeId),
                      ["newer.jpg", "older.jpg"])
    }

    func testCookPhotoPathsEmptyWhenNoneCaptured() {
        let recipeId = UUID()
        let sessions = [session(recipeId: recipeId, photoUrl: nil, startedAt: Date())]
        XCTAssertEqual(cookPhotoPaths(sessions: sessions, recipeId: recipeId), [])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ios && xcodegen generate && xcodebuild test -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' -only-testing:SousTests/CookHistoryLogicTests 2>&1 | tail -30`

Expected: FAIL to compile — `cookPhotoPaths` doesn't exist yet (also FAIL if
`CookSession`'s memberwise init signature doesn't match — it should, since Task 3 only
added a trailing field with no custom `init`, keeping the compiler-synthesized
memberwise initializer valid with `photoUrl:` as its last parameter).

- [ ] **Step 3: Implement `cookPhotoPaths`**

Append to `ios/Sous/CookHistoryLogic.swift`:

```swift

/// Object paths (not full URLs — `cook-photos` is a private bucket, resolved via
/// `AppModel.downloadPhoto`) for a recipe's own captured 上菜 photos, most recent cook
/// first. Feeds `RecipePhotoCarousel`, closing the loop Pass 1b left open (that pass
/// shipped the carousel placeholder-only because this column didn't exist yet).
func cookPhotoPaths(sessions: [CookSession], recipeId: UUID) -> [String] {
    sessions
        .filter { $0.recipeId == recipeId && $0.photoUrl != nil }
        .sorted { $0.startedAt > $1.startedAt }
        .compactMap(\.photoUrl)
}
```

- [ ] **Step 4: `AppModel.downloadPhoto`**

In `ios/Sous/AppModel.swift`, add directly after `uploadCookPhoto` (Task 8):

```swift

    /// Downloads a stored cook photo's raw bytes for display. `cook-photos` is a
    /// private bucket, so this goes through the authenticated client (RLS-checked) —
    /// there's no plain public URL to hand `AsyncImage` directly.
    func downloadPhoto(path: String) async -> Data? {
        try? await client.storage.from("cook-photos").download(path: path)
    }
```

- [ ] **Step 5: Rewrite `RecipePhotoCarousel` to consume real data**

Replace `ios/Sous/RecipePhotoCarousel.swift` in full:

```swift
// ios/Sous/RecipePhotoCarousel.swift
import SwiftUI

/// Tap-to-advance photo carousel for Recipe Detail (D1). Placeholder-only through Pass
/// 1b (`cook_sessions.photo_url` didn't exist yet — see
/// docs/superpowers/specs/2026-08-04-m3-visual-restyle-pass1b-recipe-detail-design.md);
/// Pass 1c wires it to real captured 上菜 photos via `photoPaths` (most-recent-first
/// object paths — `cookPhotoPaths` in `CookHistoryLogic.swift`) and `loadImage`
/// (`AppModel.downloadPhoto` — `cook-photos` is a private bucket, no plain public URL to
/// hand `AsyncImage`). Falls back to the original hatched placeholder when `photoPaths`
/// is empty — true for most recipes immediately after this ships, since it takes one
/// real cook to populate. Tap zones instead of swipe: swipe is reserved for the separate
/// swipe-ritual gesture elsewhere in the app.
struct RecipePhotoCarousel: View {
    let accentColor: Color
    let photoPaths: [String]
    let loadImage: (String) async -> Data?

    @State private var index = 0
    @State private var loadedImages: [String: UIImage] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ZStack {
                if let path = photoPaths[safe: index], let image = loadedImages[path] {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    placeholderFill
                }
            }
            .frame(height: 194)
            .clipped()
            .overlay(alignment: .topLeading) { progressSegments }
            .overlay(tapZones)

            captionText
        }
        .task(id: photoPaths) {
            for path in photoPaths where loadedImages[path] == nil {
                if let data = await loadImage(path), let image = UIImage(data: data) {
                    loadedImages[path] = image
                }
            }
        }
    }

    private var placeholderFill: some View {
        ZStack {
            Rectangle().fill(
                LinearGradient(colors: [PaperTokens.ink.opacity(0.06), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            Text("料理照片")
                .font(.system(size: 10, design: .monospaced))
                .tracking(2)
                .foregroundStyle(PaperTokens.inkFaint)
        }
    }

    private var captionText: some View {
        Text(photoPaths.isEmpty
             ? "圖 · 之後煮這道菜的照片會顯示在這裡。"
             : "圖 · 你拍的成品照。")
            .font(.system(size: 11.5))
            .italic()
            .foregroundStyle(PaperTokens.inkDim)
    }

    private var progressSegments: some View {
        HStack(spacing: 3) {
            ForEach(0..<max(photoPaths.count, 1), id: \.self) { i in
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
        let count = max(photoPaths.count, 1)
        let next = index + delta
        guard next >= 0, next < count else { return }
        index = next
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
```

- [ ] **Step 6: Update the call site**

Replace `ios/Sous/RecipeDetailView.swift:72`:

```swift
                RecipePhotoCarousel(accentColor: model.personaTint)
```

with:

```swift
                RecipePhotoCarousel(
                    accentColor: model.personaTint,
                    photoPaths: cookPhotoPaths(sessions: model.cookSessions, recipeId: recipe.id),
                    loadImage: { path in await model.downloadPhoto(path: path) }
                )
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `cd ios && xcodegen generate && xcodebuild test -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' 2>&1 | tail -30`

Expected: PASS, full suite, no regressions.

**Acceptance:** A recipe with no completed cook sessions (or none with a photo) shows
the original hatched placeholder, unchanged from Pass 1b. A recipe with a captured 上菜
photo (from Task 8's manual verification) shows that real photo in the carousel, most
recent first, tap zones still advancing/retreating correctly.

- [ ] **Step 8: Commit**

```bash
git add ios/Sous/RecipePhotoCarousel.swift ios/Sous/RecipeDetailView.swift ios/Sous/CookHistoryLogic.swift ios/Sous/AppModel.swift ios/SousTests/CookHistoryLogicTests.swift
git commit -m "feat(ios): wire RecipePhotoCarousel to real cook_sessions photos"
```

---

## Final verification (whole-plan acceptance)

After Task 10:
- [ ] Full test suite green: `cd ios && xcodebuild test -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.2' 2>&1 | tail -30`.
- [ ] **Migration `0019` pushed to production before the device check, not after**:
  `supabase db push --linked`, then confirm with `supabase migration list --linked`
  that `0019` shows as applied remotely — per
  `[[feedback-real-device-check-needs-cloud-migrations]]`, this is the explicit process
  fix from Pass 1b's post-merge incident, done proactively this time.
- [ ] Real-device check on Mike's iPhone 13 mini (375pt): full C1→C2→C3→C4 walkthrough —
  備料 checklist, the crossing into 灶前, step ring + at least one background timer
  (including backgrounding the app with a timer running and confirming its local
  notification fires), 上菜 photo capture via the real camera, the crossing back to
  paper, 講評 rating submission, and finally confirming the captured photo appears in
  that recipe's `RecipePhotoCarousel` back on Recipe Detail.
- [ ] Whole-branch review before merge, same bar as Pass 1a/1b (Ready to merge = Yes, no
  Critical/Important findings).
