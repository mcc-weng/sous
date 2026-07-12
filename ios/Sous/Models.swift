import Foundation

struct ChatMessage: Codable, Identifiable, Equatable {
    let id: UUID
    let sender: String        // "user" | "chef"
    let content: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, sender, content
        case createdAt = "created_at"
    }
}

struct PlanDay: Codable, Identifiable {
    let id: UUID
    let date: String          // "YYYY-MM-DD" (postgres date — keep as string)
    let dish: String
    let mode: String
    let prepNote: String?

    enum CodingKeys: String, CodingKey {
        case id, date, dish, mode
        case prepNote = "prep_note"
    }
}

struct Household: Codable {
    let id: UUID
    let name: String
    let workerSeenAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name
        case workerSeenAt = "worker_seen_at"
    }
}

/// Presence: worker heartbeat within `threshold` seconds = chef is around.
func chefIsPresent(workerSeenAt: Date?, now: Date = Date(),
                   threshold: TimeInterval = 60) -> Bool {
    guard let seen = workerSeenAt else { return false }
    return now.timeIntervalSince(seen) < threshold
}
