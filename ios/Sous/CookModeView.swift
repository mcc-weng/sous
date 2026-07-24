// ios/Sous/CookModeView.swift
import SwiftUI

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

    private enum Phase { case prep, cooking, verdict, done }

    init(recipe: Recipe, planDay: PlanDay?) {
        self.recipe = recipe
        self.planDay = planDay
        _checked = State(initialValue: Array(repeating: false, count: recipe.ingredients.count))
    }

    var body: some View {
        VStack {
            switch phase {
            case .prep: prepChecklist
            case .cooking: teleprompter
            case .verdict: verdictPrompt
            case .done: doneView
            }
        }
        .padding()
        .task { await startSession() }
    }

    private var prepChecklist: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("備料").font(.title2.bold())
            ForEach(recipe.ingredients.indices, id: \.self) { i in
                Button {
                    checked[i].toggle()
                } label: {
                    HStack {
                        Image(systemName: checked[i] ? "checkmark.circle.fill" : "circle")
                        Text(recipe.ingredients[i].name)
                        Spacer()
                        if let qty = recipe.ingredients[i].qty {
                            Text(qty).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
            HStack {
                Button("略過") { phase = .cooking }
                Spacer()
                Button("開始烹飪") { phase = .cooking }
                    .buttonStyle(.borderedProminent)
                    .disabled(!recipe.ingredients.isEmpty && !isChecklistComplete(checked))
            }
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
        VStack(spacing: 16) {
            Label("煮好了!", systemImage: "checkmark.seal.fill")
                .font(.title.bold())
                .foregroundStyle(.green)
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
                .select("id,recipe_id,started_at,completed_at").single().execute().value
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
