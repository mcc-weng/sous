import XCTest
@testable import Sous

final class RecipeScalingLogicTests: XCTestCase {
    private func ingredient(qty: String? = nil, qtyValue: Double? = nil,
                            qtyUnit: String? = nil) -> Ingredient {
        Ingredient(name: "test", qty: qty, qtyValue: qtyValue, qtyUnit: qtyUnit)
    }

    func testRescaledValueScalesContinuousUnitUp() {
        XCTAssertEqual(rescaledValue(qtyValue: 300, unit: "g", fromServings: 2, toServings: 4), 600.0)
    }

    func testRescaledValueRoundsContinuousUnitToOneDecimal() {
        XCTAssertEqual(rescaledValue(qtyValue: 1.5, unit: "cup", fromServings: 4, toServings: 2), 0.8)
    }

    func testRescaledValueRoundsDiscreteUnitToWholeNumber() {
        XCTAssertEqual(rescaledValue(qtyValue: 1, unit: "顆", fromServings: 2, toServings: 3), 2.0)
    }

    func testRescaledValueNeverGoesBelowOneForDiscreteUnits() {
        XCTAssertEqual(rescaledValue(qtyValue: 1, unit: "顆", fromServings: 4, toServings: 1), 1.0)
    }

    func testConvertWeightMetricToImperial() {
        let result = convert(value: 300, unit: "g", to: .imperial)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.unit, "oz")
        XCTAssertEqual(result!.value, 10.58, accuracy: 0.01)
    }

    func testConvertVolumeRoundTrips() {
        let toImperial = convert(value: 236.588, unit: "ml", to: .imperial)!
        XCTAssertEqual(toImperial.unit, "cup")
        XCTAssertEqual(toImperial.value, 1.0, accuracy: 0.01)
        let backToMetric = convert(value: toImperial.value, unit: toImperial.unit, to: .metric)!
        XCTAssertEqual(backToMetric.value, 236.588, accuracy: 0.5)
    }

    func testConvertReturnsNilForDiscreteUnits() {
        XCTAssertNil(convert(value: 2, unit: "顆", to: .imperial))
    }

    func testFormattedQuantityDropsDecimalForWholeNumbers() {
        XCTAssertEqual(formattedQuantity(value: 600.0, unit: "g"), "600 g")
    }

    func testFormattedQuantityKeepsOneDecimalForFractional() {
        XCTAssertEqual(formattedQuantity(value: 0.8, unit: "cup"), "0.8 cup")
    }

    func testDisplayQuantityRescalesWhenStructuredDataPresent() {
        let ing = ingredient(qty: "300g", qtyValue: 300, qtyUnit: "g")
        let result = displayQuantity(ingredient: ing, currentServings: 4, baseServings: 2, unitSystem: .metric)
        XCTAssertEqual(result, "600 g")
    }

    func testDisplayQuantityFallsBackToFreeTextWhenNoStructuredData() {
        let ing = ingredient(qty: "1 顆蛋")
        let result = displayQuantity(ingredient: ing, currentServings: 4, baseServings: 2, unitSystem: .metric)
        XCTAssertEqual(result, "1 顆蛋")
    }

    func testDisplayQuantityConvertsUnitSystem() {
        let ing = ingredient(qty: "300g", qtyValue: 300, qtyUnit: "g")
        let result = displayQuantity(ingredient: ing, currentServings: 2, baseServings: 2, unitSystem: .imperial)
        XCTAssertEqual(result, "10.6 oz")
    }

    func testConvertRecognizesTraditionalChineseTablespoon() {
        let result = convert(value: 2, unit: "大匙", to: .metric)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.value, 30.0)
        XCTAssertEqual(result!.unit, "ml")
    }

    func testConvertRecognizesTraditionalChineseCup() {
        let result = convert(value: 1, unit: "杯", to: .metric)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.value, 240.0)
        XCTAssertEqual(result!.unit, "ml")
    }

    func testDisplayQuantityConvertsTraditionalChineseTablespoonEndToEnd() {
        let ing = ingredient(qty: "2 大匙", qtyValue: 2, qtyUnit: "大匙")
        let result = displayQuantity(ingredient: ing, currentServings: 2, baseServings: 2, unitSystem: .metric)
        XCTAssertEqual(result, "30 ml")
    }
}
