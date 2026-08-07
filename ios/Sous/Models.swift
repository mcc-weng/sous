import Foundation
import Supabase

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
    let personaId: UUID

    enum CodingKeys: String, CodingKey {
        case id, name, timezone
        case workerSeenAt = "worker_seen_at"
        case personaId = "persona_id"
    }
}

/// Presence: worker heartbeat within `threshold` seconds = chef is around.
func chefIsPresent(workerSeenAt: Date?, now: Date = Date(),
                   threshold: TimeInterval = 60) -> Bool {
    guard let seen = workerSeenAt else { return false }
    return now.timeIntervalSince(seen) < threshold
}

struct Ingredient: Codable, Equatable, Hashable {
    let name: String
    let qty: String?
    let qtyValue: Double?
    let qtyUnit: String?

    enum CodingKeys: String, CodingKey {
        case name, qty
        case qtyValue = "qty_value"
        case qtyUnit = "qty_unit"
    }
}

struct RecipeStep: Codable, Equatable, Hashable {
    let text: String
    let stage: String?
    let durationSec: Int?
    let tip: String?

    enum CodingKeys: String, CodingKey {
        case text, stage, tip
        case durationSec = "duration_sec"
    }
}

struct Recipe: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    let slug: String
    let title: String
    let sourceBlock: String?
    let bodyMd: String
    let ingredients: [Ingredient]
    let steps: [RecipeStep]
    let createdAt: Date
    let servings: Int

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, slug, title, ingredients, steps, servings
        case sourceBlock = "source_block"
        case bodyMd = "body_md"
        case createdAt = "created_at"
    }

    /// PostgREST `select=` column list, derived from `CodingKeys` rather than
    /// hand-maintained separately — a field added to `Recipe` without updating a
    /// hardcoded select string silently drops that column from every fetch and, if the
    /// field is non-optional, throws a decode error the `catch { print(...) }` in
    /// `AppModel.loadCookbook()` swallows entirely (this exact bug shipped with Pass 1b's
    /// `servings` field and produced an empty cookbook in production for two days before
    /// being traced to this). Deriving the column list from `CodingKeys` makes that class
    /// of bug impossible instead of merely fixing this one instance of it.
    static let selectColumns = CodingKeys.allCases.map(\.rawValue).joined(separator: ",")
}

struct CookSession: Codable, Identifiable, Equatable {
    let id: UUID
    let recipeId: UUID
    let startedAt: Date
    let completedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case recipeId = "recipe_id"
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }
}

struct Verdict: Codable, Identifiable, Equatable {
    let id: UUID
    let rating: String
    let note: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, rating, note
        case createdAt = "created_at"
    }
}

struct PreferencesRow: Codable {
    let content: String
}

struct PersonaCopyRow: Decodable {
    /// The string-valued keys of `copy_pack` — nearly all of it. Non-string values
    /// (currently just `thinking_stages`, a JSON array) are decoded separately below
    /// and simply absent here, rather than failing the whole dictionary's decode — see
    /// the custom `init(from:)` below for why that distinction is load-bearing.
    let copyPack: [String: String]
    /// `thinking_stages` copy_pack key (migration 0016) — the one copy_pack value
    /// that's a JSON array instead of a string (`README` B2 waiting-state rotation).
    /// Empty if the key is missing or isn't actually an array of strings.
    let thinkingStages: [String]
    /// Hex string (e.g. `"#9B2C1E"`) from `personas.tint` — the persona's accent
    /// colour, read at runtime rather than hardcoded, so a future second persona is a
    /// data change, not a code change. Optional/nullable: `AppModel` falls back to
    /// `PaperTokens.sealFallback` if this is missing or fails to parse.
    let tint: String?

    enum CodingKeys: String, CodingKey {
        case copyPack = "copy_pack"
        case tint
    }

    /// `copy_pack` is `jsonb`; every key was string-valued until migration 0016 added
    /// `thinking_stages` as a JSON array. Decoding straight into `[String: String]`
    /// throws `DecodingError.typeMismatch` the instant any key holds a non-string
    /// value — and because Codable dictionary decode is all-or-nothing, that failure
    /// takes out the ENTIRE `copy_pack` dictionary, not just the offending key. That
    /// bug shipped unnoticed (see `PersonaCopyRowDecodingTests`) because every call
    /// site's hardcoded fallback happens to equal the seeded copy_pack value. Decoding
    /// via `AnyJSON` (from the Supabase SDK, already a transitive dependency) instead
    /// means one odd-typed value — today's array, tomorrow's bool or number — is
    /// dropped rather than fatal to every other key.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode([String: AnyJSON].self, forKey: .copyPack)
        copyPack = raw.compactMapValues(\.stringValue)
        thinkingStages = raw["thinking_stages"]?.arrayValue?.compactMap(\.stringValue) ?? []
        tint = try container.decodeIfPresent(String.self, forKey: .tint)
    }
}
