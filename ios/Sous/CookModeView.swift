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
        Color(StageTokens.bg).ignoresSafeArea()
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
        VStack(spacing: 24) {
            HStack {
                Text("\(stepIndex + 1) / \(recipe.steps.count)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("步驟列表") { showStepList = true }
            }
            Spacer()
            Text(recipe.steps[stepIndex].text)
                .font(.title.bold())
                .multilineTextAlignment(.center)
            if let tip = recipe.steps[stepIndex].tip {
                Text(tip).font(.body).foregroundStyle(.secondary)
            }
            if let duration = recipe.steps[stepIndex].durationSec {
                Text(durationLabel(duration)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                Button("上一步") {
                    stepIndex = clampedStepIndex(stepIndex - 1, stepCount: recipe.steps.count)
                }
                .disabled(stepIndex == 0)
                Spacer()
                if stepIndex == recipe.steps.count - 1 {
                    Button("完成") { Task { await finishCooking() } }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("下一步") {
                        stepIndex = clampedStepIndex(stepIndex + 1, stepCount: recipe.steps.count)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
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

    private var verdictPrompt: some View {
        VStack(spacing: 16) {
            Text("這頓煮得怎麼樣?").font(.title2.bold())
            ForEach(["神作", "不錯", "普通", "翻車"], id: \.self) { option in
                if rating == option {
                    Button(option) { rating = option }.buttonStyle(.borderedProminent)
                } else {
                    Button(option) { rating = option }.buttonStyle(.bordered)
                }
            }
            TextField("備註(選填)", text: $note)
                .textFieldStyle(.roundedBorder)
            Button("送出") { Task { await submitVerdict() } }
                .buttonStyle(.borderedProminent)
                .disabled(rating == nil)
            Button("略過") { phase = .done }
        }
    }

    private var doneView: some View {
        let count = cookCount(sessions: model.cookSessions, recipeId: recipe.id)
        return VStack(spacing: 16) {
            Label("煮好了!", systemImage: "checkmark.seal.fill")
                .font(.title.bold())
                .foregroundStyle(.green)
            if isMilestone(count) {
                Text(milestoneReactionText(count: count, template: model.personaCopy["cook_milestone_reaction"]))
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
            } else if count > 0 {
                Text("已煮 \(count) 次")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Button("關閉") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
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
        if let sessionId {
            struct Complete: Encodable { let completed_at: String; let step_ticks: [Int] }
            let nowISO = ISO8601DateFormatter().string(from: Date())
            do {
                try await model.client.from("cook_sessions")
                    .update(Complete(completed_at: nowISO, step_ticks: Array(recipe.steps.indices)))
                    .eq("id", value: sessionId)
                    .execute()
                await model.loadCookbook()
            } catch { print("complete cook session: \(error)") }
        }
        phase = planDay != nil ? .verdict : .done
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
