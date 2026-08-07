# M3 Visual Restyle — Pass 1c: Cook Mode (C1–C4) Design

**Status:** Approved, ready for planning.
**Parent spec:** `docs/superpowers/specs/2026-08-02-m3-visual-restyle-design.md` (staged
Pass 1a/1b/1c/Pass 2; this is the Pass 1c sub-spec, same split as Pass 1b's).
**Design reference:** `design_handoff_sous_m3/README.md` §C1–C4 (mise en place, cook
mode, plate-up, verdict), §Motion (過場 the crossing), §Accessibility, §Design tokens
(灶 · Stage). This doc does not restate those values; it records scope decisions, the
data model, and the parts the mockup doesn't cover.

## Context

`CookModeView.swift`/`CookModeLogic.swift` currently implement a functional but
unstyled four-phase flow (`.prep` / `.cooking` / `.verdict` / `.done`) — system fonts,
no timers, no photo capture, user-picked rating. This is the last screen set from the
original Pass 1a/1b/1c/Pass 2 split (per
`docs/superpowers/specs/2026-08-02-m3-visual-restyle-design.md`) and the only one that
touches the **stage** (dark) half of the 書與灶 system — Pass 1a only ever built
`PaperTokens`.

Unlike Pass 1a's screens, Cook Mode isn't a pure restyle: the design names three real
capabilities that don't exist in the current implementation — a per-step timer,
independent concurrent background timers, and 上菜 photo capture backed by a new
`cook_sessions.photo_url` column. Pass 1b's `RecipePhotoCarousel` shipped
placeholder-only specifically because this column didn't exist yet (see that spec's
Scope decisions) — this pass is what unblocks it.

Brainstormed with Mike on 2026-08-07 to resolve scope questions the mockup and prior
specs left open.

## Scope decisions made during brainstorming

- **C4 講評 is a restyle only — no grading-flip.** The mockup's blind-reveal +
  我同意/我不服 interaction requires `verdicts.rating` to become a brain write (spec
  delta #1 in the design README), which needs new worker reporting and a 我不服
  re-tasting job. That backend work was already deferred to Pass 2 during Pass 1a's
  own backlog review ("the grading flip"). Pulling it into 1c would mean building Pass
  2 backend inside a visual-restyle pass. **Decision: Pass 1c re-skins the existing
  direct rating picker (神作/不錯/普通/翻車 + optional note) to paper tokens.
  Pass 2 later replaces the interaction model when the grading-flip backend lands.**
- **Cook-session photos feed the recipe's real photo history, not a session-only
  field.** `RecipePhotoCarousel.swift` already documents this intent in its own
  comment (placeholder-only "until Pass 1c"). No new `recipes` column: the carousel
  queries `cook_sessions` directly (`recipe_id = self`, `photo_url is not null`, most
  recent first) — same approach the Pass 1b spec's Out-of-scope section already named
  as "a small follow-up task."
- **Timers are wall-clock-based with local notifications, not view-lifecycle
  countdowns.** The design's "pausing the step timer must not pause the rice" implies
  timers survive backgrounding (checking Messages while rice cooks) — a plain
  `Timer`/`Combine` countdown tied to the view's lifetime would silently break that
  the moment the user switches apps. Each timer stores an absolute end-time (`Date`);
  remaining time is always `endTime.timeIntervalSinceNow`, recomputed on
  appear/foreground — no invalidation bookkeeping needed. Each running timer schedules
  one local notification (`UNNotificationRequest`) so it pings even if the app isn't
  foreground; permission denial degrades silently to wall-clock-only (timer still
  correct, no ping — never blocks starting one).
- **Photo storage mirrors the existing household-scoped RLS model exactly.** A new
  private bucket `cook-photos`, objects at `{household_id}/{cook_session_id}.jpg`,
  `storage.objects` policies reuse the existing `is_member()` helper (parsed off the
  path's first segment) — same access model as every other table in `0002_rls.sql`.
  Rejected a public bucket: simpler client code, but breaks the household-privacy
  discipline every other table enforces.
- **Photo capture uses the system camera sheet, not a bespoke camera view.** The
  mockup's square 1:1 live-preview-in-a-hatched-target with a brass ◎ shutter is
  visually specific, but building it means a custom `AVCaptureSession` (session
  lifecycle, permissions, preview layer) for a screen used once per cook. **Decision:**
  `UIImagePickerController` (camera source) presented as a sheet, captured image
  center-cropped to 1:1 client-side before upload. Camera permission denial doesn't
  block finishing a cook — `跳過,直接聽講評` remains available regardless.
- **`StageTokens` is new, `PaperTokens.seal` is reused, not duplicated.** Cook Mode is
  the first screen set to touch the dark half of the design system, so `bg`/`ink`/
  `inkDim`/`brass`/`brassSoft`/`rule`/`glow` are new. `stage.seal` in the README is the
  same literal value (`#9B2C1E`) as `paper.seal` — implemented as one shared constant,
  not two tokens that could drift.
- **The crossing (過場) transition is built as one shared component, both
  directions.** Used at C1→C2 (開始烹飪, dims to stove) and C3→C4 (上菜 completes,
  prints back to paper) — same 940ms choreography (dim 620ms, stage cross-fades from
  340ms, glow arrives at 500ms; reversed ~220ms faster), so it's implemented once and
  reused, not hand-rolled per transition. `UIAccessibility.isReduceMotionEnabled`
  collapses it to a 140ms cross-fade per the a11y spec.

## Data model changes

**Migration `0019`:**
- `alter table cook_sessions add column photo_url text` — nullable; most sessions
  never capture a photo (跳過 is a first-class path, not an edge case).
- `insert into storage.buckets (id, name, public) values ('cook-photos',
  'cook-photos', false)`.
- `storage.objects` RLS policies for the `cook-photos` bucket: `select`/`insert` to
  `authenticated`, gated by `is_member(((storage.foldername(name))[1])::uuid)` —
  parses the household id off the object path's first segment, same helper every
  other table's policy already calls.

Per `[[feedback-real-device-check-needs-cloud-migrations]]`: this migration must be
pushed to **both** the local dev stack and production (`supabase db push --linked`)
before the real-device exit check, not discovered as a gap after it — Pass 1b's
post-merge incident is exactly this failure mode.

**`CookSession` (`Models.swift`)** — one new optional field:
```swift
struct CookSession: Codable, Identifiable, Equatable {
    let id: UUID
    let recipeId: UUID
    let startedAt: Date
    let completedAt: Date?
    let photoUrl: String?   // new — storage object path, nil if no photo captured

    enum CodingKeys: String, CodingKey {
        case id
        case recipeId = "recipe_id"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case photoUrl = "photo_url"
    }
}
```

## What's landing (iOS)

**`DesignTokens.swift`** — new `enum StageTokens` (bg/ink/inkDim/brass/brassSoft/rule),
a `glow` helper (radial gradient anchored to the bottom edge), reusing
`PaperTokens.seal` rather than adding a duplicate.

**`CookTimerModel`** (new type, `CookModeLogic.swift`) — the step timer and an array of
independent background timers. Each timer: `id`, `label`, `endTime: Date?` (nil when
paused), `remainingAtPause: TimeInterval?`. Remaining time is always computed from
`endTime`, never decremented imperatively. Starting/resuming a timer schedules a local
notification at its end-time; pausing or completing cancels that request. Background
timers are keyed by their own id and are untouched by step navigation (`stepIndex`
changes don't touch `backgroundTimers`).

**`CookModeView.swift`** restyled phase-by-phase:
- **C1 備料** (paper): existing `isChecklistComplete` logic unchanged, rows restyled to
  the 56pt/24×24-checkbox idiom already established in Pass 1a's `ShoppingListView`.
- **過場 crossing** (new shared view/modifier): wraps the C1→C2 and C3→C4 transitions,
  the 940ms dim/cross-fade/glow choreography described above, Reduce Motion variant.
- **C2 灶前** (stage): teleprompter (previous/current/next step, tip inline in the
  current step), step ring (118pt conic gradient) bound to `CookTimerModel`'s step
  timer, background timer rows each with 暫停/繼續. `下一步` advances `stepIndex` only.
  Last step's button becomes `上菜`.
- **C3 上菜** (stage): 1:1 hatched photo target. `拍照` presents
  `UIImagePickerController` (`.camera`), crops the result to 1:1, uploads to
  `cook-photos/{household_id}/{session_id}.jpg` via Supabase Storage in the background
  of the transition to C4 (doesn't block on network), then updates
  `cook_sessions.photo_url`. `跳過,直接聽講評` skips straight to C4 with no photo.
- **C4 講評** (paper): existing rating picker + note field, restyled to paper tokens.
  No interaction changes — see Scope decisions.

**`RecipePhotoCarousel.swift`** — `placeholderCount = 2` hardcode replaced with a real
query against `cook_sessions` (`recipe_id = self`, `photo_url is not null`, most recent
first). Empty result keeps today's placeholder copy (`圖 · 之後煮這道菜的照片會顯示在這裡。`)
— true for most recipes immediately after this ships, since it takes one real cook to
populate.

**Accessibility** (per README §Accessibility, applied to C2/C3 specifically): timer
ring VoiceOver label (`步驟二計時器,剩四分十二秒,暫停中。輕點兩下繼續。`), step text
as a 140ms opacity swap only (no slide — "the eye must not chase it at the stove"),
haptic **and** sound on timer completion (not haptic alone — "the phone is usually
across the counter").

## Error handling

- Photo upload and `cook_sessions.photo_url` update stay best-effort
  (`catch { print(...) }`), matching `startSession()`'s existing precedent — a failed
  upload doesn't strand the user mid-verdict; C4 proceeds regardless, `photo_url` just
  stays nil for that session. No retry queue (out of scope, matches the app's existing
  "instant and local" philosophy for mechanical actions).
- Local notification permission denial: timers remain wall-clock-correct, just silent
  in the background. Never blocks starting a timer.
- Camera permission denial: `跳過` remains available — capture is never a hard gate on
  finishing a cook.
- Background timers are structurally independent of `stepIndex` and of the step
  timer's pause state — there is no shared mutable state between them, so "pausing the
  step timer must not pause the rice" is true by construction, not by a runtime guard.

## Testing

`CookModeLogicTests.swift` gains coverage for `CookTimerModel`:
- Remaining-time math is correct purely from `endTime` (no drift from imperative
  decrementing).
- Pause captures `remainingAtPause` correctly; resume recomputes a fresh `endTime` from
  it (not from the original duration).
- Multiple background timers and the step timer don't interfere — advancing
  `stepIndex` or pausing the step timer leaves background timers' `endTime`s untouched.

Regression test for `RecipePhotoCarousel`'s query logic (empty → placeholder copy,
non-empty → real photos in most-recent-first order) — same pattern as Pass 1b's
`Recipe.selectColumns` regression test.

No changes needed to `makeVerdictPayload`/`isChecklistComplete` — both restyled around,
not modified.

## Verification / exit criteria

Targets for this pass — this section gets updated with actual results as Pass 1c
closes out, same as the Pass 1a/1b specs were.

- Unit tests green on `main` post-merge (exact count set by the plan's task breakdown).
- Whole-branch review (opus) — Ready to merge, no Critical/Important findings.
- Migration `0019` confirmed applied via `supabase migration list --linked`
  **before** the real-device check, not after — the explicit process fix from
  `[[feedback-real-device-check-needs-cloud-migrations]]`.
- Real-device exit check on Mike's iPhone 13 mini: full C1→C2→C3→C4 walkthrough,
  including a background timer surviving an app-switch and firing its notification,
  and a captured 上菜 photo appearing in that recipe's `RecipePhotoCarousel` afterward.

## Out of scope (deferred, not forgotten)

- Grading-flip (brain-write `verdicts.rating`, blind-reveal, 我同意/我不服, 我不服
  re-tasting job) — Pass 2, per spec delta #1.
- Bespoke `AVCaptureSession` camera view matching the mockup pixel-for-pixel — system
  camera sheet instead, this pass.
- Photo upload retry/offline queue — best-effort only, this pass.
- Auto-found reference photos (web-search-sourced dish images) — separate future spec,
  already deferred once in Pass 1b.
