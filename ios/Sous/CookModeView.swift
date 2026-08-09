// ios/Sous/CookModeView.swift
import SwiftUI
import UIKit

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
    @State private var showCamera = false
    @StateObject private var timerModel = CookTimerModel()
    @State private var showAddTimerSheet = false
    @State private var newTimerLabel = ""
    @State private var newTimerMinutes = 10

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

                // Bypasses the checklist entirely — an incomplete/unavailable pantry
                // shouldn't block cooking. Calls beginCooking() (not a bare phase
                // assignment) so the first step's timer still gets set up. No
                // .disabled(...) — that's the whole point versus 開始烹飪 above.
                Button {
                    beginCooking()
                } label: {
                    Text("略過")
                        .font(.custom(sansName, size: 12))
                        .foregroundStyle(PaperTokens.inkDim)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }

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
            if let duration = recipe.steps[newValue].durationSec {
                timerModel.setStepTimer(label: "步驟 \(chineseNumeral(newValue + 1))",
                                        duration: TimeInterval(duration))
            } else {
                timerModel.clearStepTimer()
            }
        }
        .sheet(isPresented: $showStepList) {
            NavigationStack {
                List(recipe.steps.indices, id: \.self) { i in
                    Button {
                        withAnimation(.easeInOut(duration: 0.14)) {
                            stepIndex = i
                        }
                        showStepList = false
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Text(chineseNumeral(i + 1))
                                .font(.custom(sansName, size: 11))
                                .foregroundStyle(StageTokens.brass)
                                .frame(width: 20, alignment: .leading)
                            Text(recipe.steps[i].text)
                                .font(.custom(serifName, size: 14))
                                .foregroundStyle(StageTokens.ink)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .listRowBackground(StageTokens.bg)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(StageTokens.bg)
                .navigationTitle("步驟列表")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("關閉") { showStepList = false }
                            .foregroundStyle(StageTokens.brass)
                    }
                }
            }
            .presentationBackground(StageTokens.bg)
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
                withAnimation(.easeInOut(duration: 0.14)) {
                    stepIndex = clampedStepIndex(stepIndex - 1, stepCount: recipe.steps.count)
                }
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
                    withAnimation(.easeInOut(duration: 0.14)) {
                        stepIndex = clampedStepIndex(stepIndex + 1, stepCount: recipe.steps.count)
                    }
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
                .padding(.bottom, Spacing.lg)
        }
        .background(PaperTokens.stock)
    }

    private func durationLabel(_ seconds: Int) -> String {
        seconds < 60 ? "約 \(seconds) 秒" : "約 \(seconds / 60) 分鐘"
    }

    /// Optimistic and best-effort — a failed insert doesn't block cooking, matching
    /// the shopping checkbox's precedent of never gating a mechanical action on a
    /// network round-trip.
    private func startSession() async {
        struct NewSession: Encodable { let household_id: UUID; let recipe_id: UUID }
        guard let household = model.household else { return }
        do {
            let inserted: CookSession = try await model.client.from("cook_sessions")
                .insert(NewSession(household_id: household.id, recipe_id: recipe.id))
                .select(CookSession.selectColumns).single().execute().value
            sessionId = inserted.id
        } catch { print("start cook session: \(error)") }
    }

    private func finishCooking() async {
        // Step timer has no purpose once cooking is over — cancel it unconditionally
        // regardless of whether a session ID exists. Background timers are untouched.
        timerModel.clearStepTimer()
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
            // design spec's error handling section. The detached task refreshes the
            // cookbook again once the upload/DB-write actually completes, so
            // RecipePhotoCarousel picks up the new photo_url without the user needing
            // to wait for an unrelated future refresh.
            if let capturedPhotoData {
                Task {
                    _ = await model.uploadCookPhoto(sessionId: sessionId, imageData: capturedPhotoData)
                    await model.loadCookbook()
                }
            }
            await model.loadCookbook()
        }
        // Every cook session ends in 講評, not just ones tied to tonight's plan —
        // `submitVerdict()` already no-ops safely when there's no planDayId (nothing to
        // attach a verdicts row to), so routing a plan-less cook straight to `.done`
        // silently skipped the screen entirely instead of just skipping the write.
        // Caught on real-device testing: cooking a recipe from the cookbook (no
        // planDay) jumped straight from 上菜 to the closing screen.
        phase = .verdict
    }

    private func submitVerdict() async {
        guard let household = model.household, let rating,
              let payload = makeVerdictPayload(householdId: household.id, planDayId: planDay?.id,
                                                rating: rating, note: note.isEmpty ? nil : note) else {
            phase = .done
            return
        }
        do {
            try await model.client.from("verdicts").insert(payload).execute()
        } catch { print("submit verdict: \(error)") }
        phase = .done
    }
}
