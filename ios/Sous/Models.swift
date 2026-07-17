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

struct PlanDay: Codable, Identifiable, Equatable {
    let id: UUID
    let date: String          // "YYYY-MM-DD" (postgres date — keep as string)
    let dish: String
    let mode: String
    let prepNote: String?
    let reasoning: String?
    let status: String        // "planned" | "cooked" | "skipped" — defaults to "planned"
                               // if absent from a query's select list (see custom decoder)

    enum CodingKeys: String, CodingKey {
        case id, date, dish, mode, reasoning, status
        case prepNote = "prep_note"
    }

    init(id: UUID, date: String, dish: String, mode: String,
         prepNote: String?, reasoning: String?, status: String) {
        self.id = id
        self.date = date
        self.dish = dish
        self.mode = mode
        self.prepNote = prepNote
        self.reasoning = reasoning
        self.status = status
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        date = try c.decode(String.self, forKey: .date)
        dish = try c.decode(String.self, forKey: .dish)
        mode = try c.decode(String.self, forKey: .mode)
        prepNote = try c.decodeIfPresent(String.self, forKey: .prepNote)
        reasoning = try c.decodeIfPresent(String.self, forKey: .reasoning)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "planned"
    }
}

struct PlanWeek: Codable, Identifiable, Equatable {
    let id: UUID
    let weekOf: String        // "YYYY-MM-DD" (Monday), postgres date — keep as string
    let status: String        // "proposing" | "locked"
    let reasoning: String?

    enum CodingKeys: String, CodingKey {
        case id, status, reasoning
        case weekOf = "week_of"
    }
}

struct ShoppingItem: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let qty: String?
    let section: String?
    var checked: Bool
}

struct Household: Codable {
    let id: UUID
    let name: String
    let workerSeenAt: Date?
    let timezone: String

    enum CodingKeys: String, CodingKey {
        case id, name, timezone
        case workerSeenAt = "worker_seen_at"
    }
}

/// Presence: worker heartbeat within `threshold` seconds = chef is around.
func chefIsPresent(workerSeenAt: Date?, now: Date = Date(),
                   threshold: TimeInterval = 60) -> Bool {
    guard let seen = workerSeenAt else { return false }
    return now.timeIntervalSince(seen) < threshold
}
