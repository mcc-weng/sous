import Foundation

/// True once every ingredient in the 備料 (mise en place) gate has been checked off.
/// The gate is intentionally skippable in the UI — this only drives the "ready to
/// cook" affordance, not a hard block.
func isChecklistComplete(_ checked: [Bool]) -> Bool {
    !checked.isEmpty && checked.allSatisfy { $0 }
}

/// Clamps a step index into `steps`' bounds — shared by swipe-advance and the
/// step-list jump affordance so neither can navigate past the ends.
func clampedStepIndex(_ index: Int, stepCount: Int) -> Int {
    guard stepCount > 0 else { return 0 }
    return min(max(index, 0), stepCount - 1)
}

struct VerdictPayload: Encodable, Equatable {
    let household_id: UUID
    let plan_day_id: UUID
    let rating: String
    let note: String?
}

/// `planDayId` is nil when cook mode was launched from the cookbook (not tied to a
/// specific day on the plan) — there's nothing to rate against, so no payload is built.
func makeVerdictPayload(householdId: UUID, planDayId: UUID?, rating: String, note: String?) -> VerdictPayload? {
    guard let planDayId else { return nil }
    return VerdictPayload(household_id: householdId, plan_day_id: planDayId, rating: rating, note: note)
}
