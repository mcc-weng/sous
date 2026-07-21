// ios/Sous/ShareIntakeLogic.swift
import Foundation

struct RecipeIntakeJob: Encodable, Equatable {
    let household_id: UUID
    let kind: String
    let payload: Payload

    struct Payload: Encodable, Equatable {
        let url: String
        let by: String
    }
}

func makeRecipeIntakeJob(householdId: UUID, url: URL) -> RecipeIntakeJob {
    RecipeIntakeJob(household_id: householdId, kind: "recipe_intake",
                     payload: .init(url: url.absoluteString, by: "mike"))
}
