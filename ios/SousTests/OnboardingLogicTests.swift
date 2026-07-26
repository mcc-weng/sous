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
