// ios/Sous/OnboardingView.swift
import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var stepIndex = 0
    @State private var answers = OnboardingAnswers()
    @State private var isSubmitting = false
    @State private var submitError: String?
    @State private var isDone = false

    private let stepCount = 5

    private func copy(_ key: String, fallback: String) -> String {
        model.personaCopy[key] ?? fallback
    }

    var body: some View {
        if isDone {
            doneView
        } else {
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

    private var doneView: some View {
        VStack(spacing: 16) {
            Text(copy("onboarding_complete",
                      fallback: "都記住了!以後煮菜通通照你的喜好來,想到什麼隨時再跟我說一聲 🔥"))
                .font(.title2.bold())
            Button("開始使用") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private func submit() async {
        isSubmitting = true
        submitError = nil
        let content = composePreferences(answers)
        do {
            try await model.submitPreferences(content: content)
            isSubmitting = false
            isDone = true
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
