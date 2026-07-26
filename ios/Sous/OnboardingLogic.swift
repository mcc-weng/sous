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
