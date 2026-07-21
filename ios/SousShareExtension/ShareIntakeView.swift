import SwiftUI
import UniformTypeIdentifiers
import Supabase

private let appGroupID = "group.com.mikeweng.sous"

private enum ShareIntakeState: Equatable {
    case loadingURL
    case ready(URL)
    case sending
    case sent
    case noSession
    case error(String)
}

struct ShareIntakeView: View {
    weak var extensionContext: NSExtensionContext?
    @State private var state: ShareIntakeState = .loadingURL
    private let client = SupabaseClientFactory.make()

    var body: some View {
        VStack(spacing: 16) {
            switch state {
            case .loadingURL:
                ProgressView()
            case .ready(let url):
                Text(url.absoluteString).font(.caption).lineLimit(2)
                Button("送到小當家的廚房") { Task { await send(url) } }
                    .buttonStyle(.borderedProminent)
            case .sending:
                ProgressView("送出中…")
            case .sent:
                Label("已送到小當家的廚房!", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .noSession:
                Text("先打開小當家登入").foregroundStyle(.secondary)
            case .error(let message):
                Text(message).foregroundStyle(.red)
            }
            Button("關閉") { dismiss() }
        }
        .padding()
        .task { await loadSharedURL() }
    }

    private func loadSharedURL() async {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let provider = item.attachments?.first,
              provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) else {
            state = .error("找不到連結")
            return
        }
        let loaded: NSSecureCoding? = await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                continuation.resume(returning: item)
            }
        }
        guard let url = loaded as? URL else {
            state = .error("找不到連結")
            return
        }
        state = .ready(url)
    }

    private func send(_ url: URL) async {
        state = .sending
        guard (try? await client.auth.session) != nil else {
            state = .noSession
            return
        }
        guard let idString = UserDefaults(suiteName: appGroupID)?.string(forKey: "household_id"),
              let householdId = UUID(uuidString: idString) else {
            state = .noSession
            return
        }
        do {
            try await client.from("jobs")
                .insert(makeRecipeIntakeJob(householdId: householdId, url: url))
                .execute()
            state = .sent
        } catch {
            state = .error("送出失敗,請稍後再試")
        }
    }

    private func dismiss() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
