import Foundation
import Supabase

@MainActor
final class AppModel: ObservableObject {
    let client = SupabaseClientFactory.make()

    @Published var session: Session?
    @Published var household: Household?
    @Published var tonight: PlanDay?
    @Published var messages: [ChatMessage] = []
    @Published var thisWeek: PlanWeek?
    @Published var thisWeekDays: [PlanDay] = []
    @Published var nextWeek: PlanWeek?
    @Published var nextWeekDays: [PlanDay] = []
    @Published var shoppingItems: [ShoppingItem] = []
    @Published var recipes: [Recipe] = []
    @Published var cookSessions: [CookSession] = []
    @Published var deviceTokenRegistered = false
    @Published var deviceTokenRegistrationError: String?
    @Published var preferencesContent: String?
    @Published var personaCopy: [String: String] = [:]
    @Published var onboardingRestartRequested = false

    init() {
        // Subscribed here (not in the settings sheet) because APNs registration is
        // async and its callback isn't scoped to any view's lifetime — a user who
        // grants permission and immediately dismisses the sheet must still end up
        // registered. AppModel is the one thing alive for the whole app session.
        NotificationCenter.default.addObserver(
            forName: .sousDidRegisterDeviceToken, object: nil, queue: .main
        ) { [weak self] note in
            guard let tokenHex = note.userInfo?["tokenHex"] as? String else { return }
            Task { @MainActor in
                await self?.registerDeviceToken(tokenHex: tokenHex)
            }
        }
        NotificationCenter.default.addObserver(
            forName: .sousDidFailToRegisterDeviceToken, object: nil, queue: .main
        ) { [weak self] note in
            let message = note.userInfo?["message"] as? String
            Task { @MainActor in
                self?.deviceTokenRegistrationError = message ?? "註冊失敗"
            }
        }
    }

    // MARK: auth

    func restoreSession() async {
        session = try? await client.auth.session
        if session != nil {
            await loadAll()
            startPresencePoll()
        }
    }

    func signInWithApple(idToken: String, nonce: String) async throws {
        session = try await client.auth.signInWithIdToken(
            credentials: .init(provider: .apple, idToken: idToken, nonce: nonce)
        )
        await loadAll()
        startPresencePoll()
    }

    // MARK: data

    func loadAll() async {
        await refreshHousehold()
        await loadPersonaCopy()
        await loadTonight()
        await loadMessages()
        await loadWeekBoard()
        await loadShoppingItems()
    }

    func refreshHousehold() async {
        do {
            let rows: [Household] = try await client.from("households")
                .select("id,name,worker_seen_at,timezone,persona_id").execute().value
            household = rows.first
            if let id = household?.id {
                UserDefaults(suiteName: "group.com.mikeweng.sous")?.set(id.uuidString, forKey: "household_id")
            }
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
            // Descending + limit, then reverse — ascending + limit would return the
            // OLDEST 100 once the conversation grows past 100, silently hiding every
            // new reply from then on (and permanently breaking waitForReply's completion
            // check, which depends on new messages actually showing up here).
            let recent: [ChatMessage] = try await client.from("chat_messages")
                .select("id,sender,content,created_at")
                .order("created_at", ascending: false)
                .limit(100)
                .execute().value
            messages = Array(recent.reversed())
        } catch { print("messages load: \(error)") }
    }

    func loadWeekBoard() async {
        guard let household else { return }
        let tz = TimeZone(identifier: household.timezone) ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        let thisMonday = weekMonday(for: Date(), timezone: tz)
        let nextMonday = calendar.date(byAdding: .day, value: 7, to: thisMonday)!
        let rangeEnd = calendar.date(byAdding: .day, value: 14, to: thisMonday)!
        let thisMondayStr = dateString(thisMonday, timezone: tz)
        let nextMondayStr = dateString(nextMonday, timezone: tz)
        let rangeEndStr = dateString(rangeEnd, timezone: tz)
        do {
            let weeks: [PlanWeek] = try await client.from("plan_weeks")
                .select("id,week_of,status,reasoning")
                .in("week_of", values: [thisMondayStr, nextMondayStr])
                .execute().value
            thisWeek = weeks.first { $0.weekOf == thisMondayStr }
            nextWeek = weeks.first { $0.weekOf == nextMondayStr }

            let days: [PlanDay] = try await client.from("plan_days")
                .select("id,date,dish,mode,prep_note,reasoning,status")
                .gte("date", value: thisMondayStr)
                .lt("date", value: rangeEndStr)
                .order("date")
                .execute().value
            thisWeekDays = days.filter { $0.date < nextMondayStr }
            nextWeekDays = days.filter { $0.date >= nextMondayStr }
        } catch { print("week board load: \(error)") }
    }

    func loadShoppingItems() async {
        do {
            shoppingItems = try await client.from("shopping_items")
                .select("id,name,qty,section,checked")
                .order("name")
                .execute().value
        } catch { print("shopping items load: \(error)") }
    }

    func loadPreferences() async {
        do {
            let rows: [PreferencesRow] = try await client.from("preferences")
                .select("content").execute().value
            preferencesContent = rows.first?.content
        } catch { print("preferences load: \(error)") }
    }

    func loadPersonaCopy() async {
        guard let personaId = household?.personaId else { return }
        do {
            let row: PersonaCopyRow = try await client.from("personas")
                .select("copy_pack").eq("id", value: personaId).single().execute().value
            personaCopy = row.copyPack
        } catch { print("persona copy load: \(error)") }
    }

    /// Direct write, no job — instant, matching the shopping-checkbox precedent
    /// (`toggleShoppingItem`). Throws so `OnboardingView` can show inline retry instead
    /// of silently discarding a completed interview.
    struct MissingHouseholdError: Error {}

    func submitPreferences(content: String) async throws {
        guard let household else { throw MissingHouseholdError() }
        struct Upsert: Encodable { let household_id: UUID; let content: String }
        try await client.from("preferences")
            .upsert(Upsert(household_id: household.id, content: content))
            .execute()
        preferencesContent = content
    }

    func loadCookbook() async {
        do {
            recipes = try await client.from("recipes")
                .select("id,slug,title,source_block,body_md,ingredients,steps,created_at")
                .order("created_at", ascending: false)
                .execute().value
            cookSessions = try await client.from("cook_sessions")
                .select("id,recipe_id,started_at,completed_at")
                .execute().value
        } catch { print("cookbook load: \(error)") }
    }

    // MARK: write path — chat message + job (spec §3 step 1)

    func send(_ text: String) async {
        await sendSystemAction(text, jobKind: "chat")
    }

    /// Bootstraps the ritual — mirrors exactly the job shape verified by hand during
    /// the M2b1 cloud exit check (2026-07-16): a synthetic user message + a
    /// `ritual`-kind job. The brain takes it from there.
    func startRitual() async {
        await sendSystemAction("（開始本週儀式）", jobKind: "ritual")
    }

    /// Drag-to-swap fires the exact same request a typed chat message would — the
    /// brain calls `swap-days` via the normal chat flow, no new job kind needed.
    func requestSwap(dateA: String, dateB: String) async {
        await sendSystemAction("（手勢）把 \(dateA) 和 \(dateB) 對調", jobKind: "chat")
    }

    /// Direct write, no job — instant, matching the shopping-list spec's "no brain
    /// round-trip for checkboxes" decision. Updates local state optimistically rather
    /// than waiting on a realtime round-trip: checking an item is a pure local action
    /// with no brain involved, so there's no reason "instant" should depend on realtime
    /// delivery at all. Reverts on write failure.
    func toggleShoppingItem(_ item: ShoppingItem) async {
        guard let index = shoppingItems.firstIndex(where: { $0.id == item.id }) else { return }
        let newChecked = !item.checked
        shoppingItems[index].checked = newChecked
        struct Update: Encodable { let checked: Bool }
        do {
            try await client.from("shopping_items")
                .update(Update(checked: newChecked))
                .eq("id", value: item.id)
                .execute()
        } catch {
            print("toggle shopping item: \(error)")
            // Re-find by id rather than reusing `index` — a concurrent loadShoppingItems()
            // (e.g. from waitForReply, or the sheet's own .task on reappear) can replace
            // the whole array while this write is in flight, making the captured index
            // stale (wrong item, or out of bounds — a hard crash on direct subscript).
            if let current = shoppingItems.firstIndex(where: { $0.id == item.id }) {
                shoppingItems[current].checked = !newChecked
            }
        }
    }

    /// Upserts the APNs device token once `SousAppDelegate` hands it back via
    /// `.sousDidRegisterDeviceToken`. See the `init()` comment for why this lives on
    /// AppModel rather than `NotificationsSettingsView`.
    func registerDeviceToken(tokenHex: String) async {
        guard let userId = session?.user.id else { return }
        let upsert = makeDeviceTokenUpsert(userId: userId, tokenHex: tokenHex)
        do {
            try await client.from("device_tokens").upsert(upsert).execute()
            deviceTokenRegistered = true
            deviceTokenRegistrationError = nil
        } catch {
            print("device token upsert: \(error)")
            deviceTokenRegistrationError = error.localizedDescription
        }
    }

    private func sendSystemAction(_ text: String, jobKind: String) async {
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
                .insert(NewJob(household_id: household.id, kind: jobKind,
                               payload: .init(message_id: inserted.id)))
                .execute()
            await waitForReply(after: inserted.createdAt)
        } catch { print("sendSystemAction: \(error)") }
    }

    /// Polls for the chef's reply instead of waiting on a realtime push — this app's
    /// scale (one household, occasional messages, replies that already take seconds to
    /// minutes to generate) doesn't need WebSocket-level push, and a real-device exit
    /// check (2026-07-19) found the realtime channel never actually delivered postgres_changes
    /// for this project regardless of role/JWT/SDK version, root cause unresolved. A 2s
    /// poll adds no perceptible delay on top of the brain's own response time. Every
    /// action that expects a reaction (chat, ritual start, swap) always ends in a new
    /// chat_messages row per the worker's prompt contract, so waiting for that single
    /// signal covers refreshing after all three — the actual effect (a plan/shopping
    /// change) is picked up by the loadWeekBoard()/loadShoppingItems() refresh once the
    /// reply lands, not by tracking each action's specific side effect. Watches for an
    /// actual chef reply newer than the message just sent, rather than a raw count —
    /// a second action firing concurrently (e.g. a swap triggered while a chat reply is
    /// still pending) would otherwise satisfy this one's count with a message that isn't
    /// really its reply.
    private func waitForReply(after sentAt: Date) async {
        // A single ritual round-trip (bootstrap → craving deck → picks → proposal → lock)
        // is several separate sendSystemAction calls, one per touchpoint — this only ever
        // waits for the one reply to the message just sent, not the whole ritual.
        for _ in 0..<90 {  // 2s * 90 = 180s safety net
            try? await Task.sleep(for: .seconds(2))
            await loadMessages()
            if messages.contains(where: { $0.sender == "chef" && $0.createdAt > sentAt }) {
                await loadTonight()
                await loadWeekBoard()
                await loadShoppingItems()
                return
            }
        }
    }

    // MARK: presence poll (heartbeat is 15s, refresh at 30s)

    private var presencePollStarted = false

    func startPresencePoll() {
        guard !presencePollStarted else { return }
        presencePollStarted = true
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await refreshHousehold()
            }
        }
    }
}
