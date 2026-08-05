// ios/Sous/RecipeScalingLogic.swift
import Foundation

enum UnitSystem {
    case metric
    case imperial
}

/// Count-noun units where a fractional serving reads as absurd ("1.5 顆蛋") — the same
/// judgment call `recipe_intake.md` already makes when it leaves quantities like this as
/// free text rather than a computed fraction.
private let discreteUnits: Set<String> = ["顆", "支", "片", "瓣", "把", "條", "塊"]

func isDiscreteUnit(_ unit: String) -> Bool {
    discreteUnits.contains(unit)
}

/// Grams-per-unit for weight, ml-per-unit for volume — canonical bases used to convert
/// between any two units of the same kind without an N×N conversion table.
private let weightUnitsInGrams: [String: Double] = ["g": 1, "kg": 1000, "oz": 28.3495, "lb": 453.592]
private let volumeUnitsInMl: [String: Double] = ["ml": 1, "l": 1000, "cup": 236.588,
                                                  "tbsp": 14.7868, "tsp": 4.92892, "fl oz": 29.5735,
                                                  "大匙": 15, "小匙": 5, "杯": 240]

/// Rescales a quantity from one servings baseline to another. Discrete units round to
/// the nearest whole number (minimum 1) so scaling never invents a fake fraction like
/// "1.5 顆"; continuous units round to 1 decimal place.
func rescaledValue(qtyValue: Double, unit: String, fromServings: Int, toServings: Int) -> Double {
    guard fromServings > 0 else { return qtyValue }
    let raw = qtyValue * Double(toServings) / Double(fromServings)
    if isDiscreteUnit(unit) {
        return max(1, raw.rounded())
    }
    return (raw * 10).rounded() / 10
}

/// Converts a continuous-unit quantity between metric and imperial via a shared base
/// unit (grams for weight, ml for volume). Returns `nil` for discrete or unrecognized
/// units — callers display those unconverted, since the unit toggle only touches
/// convertible continuous units.
func convert(value: Double, unit: String, to system: UnitSystem) -> (value: Double, unit: String)? {
    if let perUnit = weightUnitsInGrams[unit] {
        let grams = value * perUnit
        let targetUnit = system == .metric ? "g" : "oz"
        guard let targetPerUnit = weightUnitsInGrams[targetUnit] else { return nil }
        return (grams / targetPerUnit, targetUnit)
    }
    if let perUnit = volumeUnitsInMl[unit] {
        let ml = value * perUnit
        let targetUnit = system == .metric ? "ml" : "cup"
        guard let targetPerUnit = volumeUnitsInMl[targetUnit] else { return nil }
        return (ml / targetPerUnit, targetUnit)
    }
    return nil
}

/// Formats a numeric quantity for display: whole numbers drop the decimal point.
func formattedQuantity(value: Double, unit: String) -> String {
    if value == value.rounded() {
        return "\(Int(value)) \(unit)"
    }
    return "\(String(format: "%.1f", value)) \(unit)"
}

/// The single entry point `RecipeDetailView` calls per ingredient row: rescales for the
/// current serving count, then converts for the active unit system, falling back to the
/// ingredient's free-text `qty` unchanged when there's no structured quantity to work
/// with (old recipes, or quantities `recipe_intake.md` couldn't cleanly parse).
func displayQuantity(ingredient: Ingredient, currentServings: Int, baseServings: Int,
                     unitSystem: UnitSystem) -> String {
    guard let qtyValue = ingredient.qtyValue, let qtyUnit = ingredient.qtyUnit else {
        return ingredient.qty ?? ""
    }
    let rescaled = rescaledValue(qtyValue: qtyValue, unit: qtyUnit,
                                 fromServings: baseServings, toServings: currentServings)
    if let converted = convert(value: rescaled, unit: qtyUnit, to: unitSystem) {
        return formattedQuantity(value: converted.value, unit: converted.unit)
    }
    return formattedQuantity(value: rescaled, unit: qtyUnit)
}
