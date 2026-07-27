import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var model: AppModel
    @State private var draft = ""
    @FocusState private var isDraftFocused: Bool
    @State private var pendingFocusScroll: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.messages) { bubble($0) }
                        if model.messages.last?.sender == "user" {
                            HStack { ProgressView(); Text("…").foregroundStyle(.secondary) }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal)
                        }
                    }
                    .padding(.vertical)
                }
                .onTapGesture { isDraftFocused = false }
                .onChange(of: model.messages.count) {
                    pendingFocusScroll?.cancel()
                    scrollToBottom(proxy)
                }
                .onChange(of: isDraftFocused) { _, isFocused in
                    guard isFocused else { return }
                    pendingFocusScroll?.cancel()
                    // The keyboard's own show animation hasn't finished (and the scroll
                    // view's frame hasn't shrunk to make room for it yet) the instant
                    // isDraftFocused flips — scrolling immediately computes against the
                    // stale, still-full-height frame. Wait out the keyboard animation first.
                    pendingFocusScroll = Task {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        guard !Task.isCancelled else { return }
                        await scrollToBottom(proxy)
                    }
                }
            }
            inputBar
        }
    }

    // Explicitly hopping back to the main actor here (rather than relying on Task {}
    // to inherit it) matters: SwiftUI's onChange closure type isn't statically
    // @MainActor, so a Task created inside it isn't guaranteed to run there. Calling
    // ScrollViewProxy off the main thread doesn't crash — it wedges UIKit's touch
    // handling until the app is backgrounded and foregrounded again.
    @MainActor
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let last = model.messages.last else { return }
        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
    }

    private func bubble(_ msg: ChatMessage) -> some View {
        Text(msg.content)
            .padding(10)
            .background(
                msg.sender == "user" ? Color.accentColor.opacity(0.2) : Color(.secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .frame(maxWidth: .infinity,
                   alignment: msg.sender == "user" ? .trailing : .leading)
            .padding(.horizontal)
            .id(msg.id)
    }

    private var inputBar: some View {
        HStack {
            TextField("Message", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .focused($isDraftFocused)
            Button {
                let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                draft = ""
                Task { await model.send(text) }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding()
    }
}
