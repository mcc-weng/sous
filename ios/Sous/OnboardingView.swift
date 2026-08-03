// ios/Sous/OnboardingView.swift
import SwiftUI

/// Onboarding wizard — no dedicated mock exists in the design handoff (the screen
/// inventory doesn't call it out separately), so this restyles the existing wizard
/// structure (steps, chip selections, stepper, completion screen) to the same paper
/// tokens used everywhere else, rather than inventing new UX. See task-11-brief.md.
struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var stepIndex = 0
    @State private var answers = OnboardingAnswers()
    @State private var isSubmitting = false
    @State private var submitError: String?
    @State private var isDone = false

    private let stepCount = 5

    private var serifName: String { serifFontName(bundled: FontBook.isSerifBundled) }
    private var sansName: String { sansFontName(bundled: FontBook.isSansBundled) }

    private func copy(_ key: String, fallback: String) -> String {
        model.personaCopy[key] ?? fallback
    }

    var body: some View {
        if isDone {
            doneView
        } else {
            VStack(spacing: 0) {
                progressHeader
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.lg) {
                        if stepIndex == 0 {
                            introLine
                        }
                        currentStep
                    }
                    .padding(.horizontal, Spacing.pageMargin)
                    .padding(.top, Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let submitError {
                    Text(submitError)
                        .font(.custom(sansName, size: 11))
                        .foregroundStyle(.red)
                        .padding(.horizontal, Spacing.pageMargin)
                        .padding(.top, Spacing.sm)
                }
                navigationButtons
            }
            .background(PaperTokens.stock)
            .task { await model.loadPersonaCopy() }
        }
    }

    // MARK: Header

    /// Replaces the old dot-carousel with a square tick-bar (README "square shapes"
    /// convention) plus a page-count readout — same current-step semantics as before
    /// (only the current tick is filled), reshaped to match every other screen.
    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("入　廚　問　卷")
                    .font(.custom(sansName, size: 10))
                    .tracking(4.2) // .42em at 10pt
                    .foregroundStyle(model.personaTint)
                Spacer()
                Text("\(stepIndex + 1) ／ \(stepCount)")
                    .font(.custom(sansName, size: 10.5))
                    .foregroundStyle(PaperTokens.inkFaint)
                    .monospacedDigit()
            }
            progressDots
        }
        .padding(.horizontal, Spacing.pageMargin)
        .padding(.top, Spacing.pageMargin)
    }

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<stepCount, id: \.self) { i in
                Rectangle()
                    .fill(i == stepIndex ? model.personaTint : PaperTokens.rule)
                    .frame(height: 3)
            }
        }
    }

    /// 小當家's framing line on the first step only — persona voice, so serif italic
    /// (matches the `眉批`/`lock_signoff` precedent for his voice elsewhere), not sans
    /// UI chrome.
    private var introLine: some View {
        Text(copy("onboarding_intro",
                  fallback: "先讓我認識你一下,幾個小問題,一下就好。"))
            .font(.custom(serifName, size: 14).italic())
            .lineSpacing(6)
            .foregroundStyle(PaperTokens.inkDim)
    }

    // MARK: Steps

    @ViewBuilder
    private var currentStep: some View {
        switch stepIndex {
        case 0:
            questionHeader("onboarding_q_allergies",
                           fallback: "你有沒有什麼過敏原,我要小心別放進菜單裡?")
            OnboardingChipGrid(options: onboardingAllergyOptions, selection: $answers.allergies,
                               tint: model.personaTint, sansName: sansName)
            otherField($answers.allergyOther)
        case 1:
            questionHeader("onboarding_q_dislikes",
                           fallback: "有沒有什麼你不喜歡吃的?我幫你避開。")
            OnboardingChipGrid(options: onboardingDislikeOptions, selection: $answers.dislikes,
                               tint: model.personaTint, sansName: sansName)
            otherField($answers.dislikeOther)
        case 2:
            questionHeader("onboarding_q_spice", fallback: "口味吃辣嗎?")
            Picker("辣度", selection: $answers.spiceLevel) {
                Text("略過").tag(SpiceLevel?.none)
                ForEach(SpiceLevel.allCases) { level in
                    Text(level.rawValue).tag(SpiceLevel?.some(level))
                }
            }
            .pickerStyle(.segmented)
            .tint(model.personaTint)
        case 3:
            questionHeader("onboarding_q_equipment", fallback: "家裡有哪些廚房設備?")
            OnboardingChipGrid(options: onboardingEquipmentOptions, selection: $answers.equipment,
                               tint: model.personaTint, sansName: sansName)
        default:
            questionHeader("onboarding_q_household_size", fallback: "平常煮飯大概幾人份?")
            Stepper("\(answers.householdSize) 人", value: $answers.householdSize, in: 1...8)
                .font(.custom(serifName, size: 16))
                .foregroundStyle(PaperTokens.ink)
                .tint(model.personaTint)
        }
    }

    private func questionHeader(_ key: String, fallback: String) -> some View {
        Text(copy(key, fallback: fallback))
            .font(.custom(serifName, size: 18).italic())
            .lineSpacing(6)
            .foregroundStyle(PaperTokens.ink)
    }

    /// Square, underlined "其他(選填)" field — plain text field with a bottom rule
    /// instead of the system rounded-border chrome, matching the paper design system's
    /// no-rounded-corners convention.
    private func otherField(_ text: Binding<String>) -> some View {
        TextField("", text: text, prompt: Text("其他(選填)").foregroundStyle(PaperTokens.inkFaint))
            .textFieldStyle(.plain)
            .font(.custom(sansName, size: 13))
            .foregroundStyle(PaperTokens.ink)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) { Rectangle().fill(PaperTokens.rule).frame(height: 1) }
    }

    // MARK: Navigation

    private var navigationButtons: some View {
        VStack(spacing: 0) {
            Rectangle().fill(PaperTokens.rule).frame(height: 1)
            HStack(spacing: 12) {
                if stepIndex > 0 {
                    secondaryButton("上一步") { stepIndex -= 1 }
                }
                Spacer(minLength: 0)
                if stepIndex == stepCount - 1 {
                    primaryButton(isSubmitting ? "送出中…" : "完成", disabled: isSubmitting) {
                        Task { await submit() }
                    }
                } else {
                    primaryButton("下一步") { stepIndex += 1 }
                }
            }
            .padding(.horizontal, Spacing.pageMargin)
            .padding(.vertical, Spacing.md)
        }
    }

    /// Ink-filled: the one committing action per page (README "元件" convention —
    /// same fill CounterView's "開始做菜" uses), never `model.personaTint` for the
    /// fill itself.
    private func primaryButton(_ title: String, disabled: Bool = false,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.custom(sansName, size: 13))
                .fontWeight(.medium)
                .tracking(4.16) // .32em at 13pt
                .foregroundStyle(PaperTokens.stock)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(PaperTokens.ink)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }

    /// Outlined = neutral secondary action (README "元件" convention — the "登入"
    /// example), used only for "上一步" here.
    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.custom(sansName, size: 13))
                .tracking(3.9) // .3em at 13pt
                .foregroundStyle(PaperTokens.ink)
                .padding(.horizontal, 20)
                .padding(.vertical, 13)
                .overlay(Rectangle().stroke(PaperTokens.ink, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: Completion

    private var doneView: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 18) {
                sealSquare
                Text(copy("onboarding_complete",
                          fallback: "都記住了!以後煮菜通通照你的喜好來,想到什麼隨時再跟我說一聲 🔥"))
                    .font(.custom(serifName, size: 19))
                    .lineSpacing(9) // lh ~1.4
                    .multilineTextAlignment(.center)
                    .foregroundStyle(PaperTokens.ink)
            }
            .padding(.horizontal, Spacing.pageMargin)
            Spacer(minLength: 0)
            primaryButton("開始使用") { dismiss() }
                .padding(.bottom, Spacing.pageMargin)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PaperTokens.stock)
    }

    /// Same seal-glyph treatment as `AuthView.sealSquare` — duplicated rather than
    /// extracted into a shared component, since AuthView is already merged and this
    /// restyle pass shouldn't risk touching it.
    private var sealSquare: some View {
        Text("當")
            .font(.custom(serifName, size: 18))
            .foregroundStyle(PaperTokens.slip)
            .frame(width: 40, height: 40)
            .background(model.personaTint)
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

/// Multi-select chip grid — square outlined chips, filled with `tint` when selected
/// (same selected/unselected fill convention as `ShoppingListView.checkbox`).
private struct OnboardingChipGrid: View {
    let options: [String]
    @Binding var selection: [String]
    let tint: Color
    let sansName: String

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(options, id: \.self) { option in
                let isSelected = selection.contains(option)
                Button {
                    if isSelected {
                        selection.removeAll { $0 == option }
                    } else {
                        selection.append(option)
                    }
                } label: {
                    Text(option)
                        .font(.custom(sansName, size: 12.5))
                        .foregroundStyle(isSelected ? PaperTokens.stock : PaperTokens.ink)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background(isSelected ? tint : Color.clear)
                        .overlay(
                            Rectangle().stroke(isSelected ? Color.clear : PaperTokens.ruleStrong, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}
