import Foundation
import Supabase

@MainActor
final class AppModel: ObservableObject {
    let client = SupabaseClient(
        supabaseURL: Config.supabaseURL,
        supabaseKey: Config.supabaseAnonKey
    )

    @Published var session: Session?
    @Published var household: Household?
    @Published var tonight: PlanDay?
    @Published var messages: [ChatMessage] = []

    // MARK: auth

    func restoreSession() async {
        session = try? await client.auth.session
        if session != nil {
            await loadAll()
            subscribe()
        }
    }

    func signInWithApple(idToken: String, nonce: String) async throws {
        session = try await client.auth.signInWithIdToken(
            credentials: .init(provider: .apple, idToken: idToken, nonce: nonce)
        )
        await loadAll()
        subscribe()
    }

    // MARK: data

    func loadAll() async {
        await refreshHousehold()
        await loadTonight()
        await loadMessages()
    }

    func refreshHousehold() async {
        do {
            let rows: [Household] = try await client.from("households")
                .select("id,name,worker_seen_at").execute().value
            household = rows.first
        } catch { print("household load: \(error)") }
    }

    func loadTonight() async {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        do {
            let rows: [PlanDay] = try await client.from("plan_days")
                .select("id,date,dish,mode,prep_note")
                .eq("date", value: fmt.string(from: Date()))
                .execute().value
            tonight = rows.first
        } catch { print("tonight load: \(error)") }
    }

    func loadMessages() async {
        do {
            messages = try await client.from("chat_messages")
                .select("id,sender,content,created_at")
                .order("created_at", ascending: true)
                .limit(100)
                .execute().value
        } catch { print("messages load: \(error)") }
    }

    // MARK: write path — chat message + chat job (spec §3 step 1)

    func send(_ text: String) async {
        guard let household else { return }
        struct NewMessage: Encodable {
            let household_id: UUID
            let sender: String
            let content: String
        }
        struct NewJob: Encodable {
            let household_id: UUID
            let kind: String
            let payload: Payload
            struct Payload: Encodable { let message_id: UUID }
        }
        do {
            let inserted: ChatMessage = try await client.from("chat_messages")
                .insert(NewMessage(household_id: household.id, sender: "user", content: text))
                .select("id,sender,content,created_at").single().execute().value
            messages.append(inserted)
            try await client.from("jobs")
                .insert(NewJob(household_id: household.id, kind: "chat",
                               payload: .init(message_id: inserted.id)))
                .execute()
        } catch { print("send: \(error)") }
    }

    // MARK: realtime — refetch on insert (simple and correct for a skeleton)

    private var subscribed = false

    func subscribe() {
        guard !subscribed else { return }
        subscribed = true
        Task {
            let channel = client.channel("kitchen")
            let inserts = channel.postgresChange(
                InsertAction.self, schema: "public", table: "chat_messages"
            )
            await channel.subscribe()
            for await _ in inserts {
                await loadMessages()
            }
        }
        Task { // presence poll — heartbeat is 15s, refresh at 30s
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await refreshHousehold()
            }
        }
    }
}
