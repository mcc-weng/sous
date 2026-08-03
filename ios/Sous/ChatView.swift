import SwiftUI

/// A3 · 便條 (the slip thread) — Reference: design_handoff_sous_m3/README.md "A3 · 便條
/// (the slip thread)" and `Sous App v2.dc.html` lines 111-170.
///
/// Scope note: this restyles the existing flat conversation view only. Two things the
/// mock shows are deliberately *not* built here:
/// - The 邊欄 (message-answers-written-into-a-recipe-page) concept is new information
///   architecture, deferred to Pass 2 (design spec §4).
/// - The `已修改 → ` changed-state link row on a slip (README: "Any slip whose reply
///   changed something carries a link row...") needs message metadata — which page,
///   what changed — that `ChatMessage` doesn't carry. Adding fake, non-functional
///   chips would misrepresent what the app can do; skipped until that data exists.
/// The mock's header also shows a `關閉` (close) affordance, appropriate for 便條 as a
/// standalone/modal screen. This view is still embedded inline at the foot of
/// `CounterView`, not presented modally, so there's nothing to dismiss — `關閉` is
/// omitted rather than wired to a no-op.
struct ChatView: View {
    @EnvironmentObject private var model: AppModel
    @State private var draft = ""
    @FocusState private var isDraftFocused: Bool
    @State private var pendingFocusScroll: Task<Void, Never>?

    private var serifName: String { serifFontName(bundled: FontBook.isSerifBundled) }
    private var sansName: String { sansFontName(bundled: FontBook.isSansBundled) }

    private var householdTimezone: TimeZone {
        guard let identifier = model.household?.timezone else { return .current }
        return TimeZone(identifier: identifier) ?? .current
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(PaperTokens.rule)
                .frame(height: 1)
                .padding(.horizontal, Spacing.pageMargin)
                .padding(.top, 14)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 18) { // thread gap (mock: `gap:18px`)
                        ForEach(model.messages) { bubble($0) }
                        if model.messages.last?.sender == "user" {
                            HStack(spacing: 8) {
                                ProgressView().tint(model.personaTint)
                                Text("…")
                                    .font(.custom(serifName, size: 14.5))
                                    .foregroundStyle(PaperTokens.inkFaint)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Spacing.pageMargin)
                        }
                    }
                    .padding(.vertical, 22)
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
        .background(PaperTokens.stock)
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

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 11) {
            Text("當")
                .font(.custom(serifName, size: 13))
                .foregroundStyle(PaperTokens.slip)
                .frame(width: 26, height: 26)
                .background(model.personaTint)
            /// `inbox_title` copy_pack key (migration 0016) — "與小當家的往來".
            Text(model.personaCopy["inbox_title"] ?? "與小當家的往來")
                .font(.custom(sansName, size: 10))
                .tracking(3.4) // .34em at 10pt
                .foregroundStyle(PaperTokens.inkFaint)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Spacing.pageMargin)
        .padding(.top, Spacing.sm)
    }

    // MARK: Messages

    @ViewBuilder
    private func bubble(_ msg: ChatMessage) -> some View {
        if msg.sender == "user" {
            userBubble(msg)
        } else {
            slip(msg)
        }
    }

    /// His slip: `paper.slip` fill, 2px `personaTint` left border, offset hard shadow,
    /// italic serif body, signed bottom-right with a timestamp (see `slipSignature`).
    private func slip(_ msg: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(msg.content)
                .font(.custom(serifName, size: 14.5).italic())
                .lineSpacing(11.6) // lh 2 at 14.5pt: (2 - 1 - 0.2) * 14.5
                .foregroundStyle(PaperTokens.ink)
            Text(slipSignature(for: msg.createdAt, timezone: householdTimezone))
                .font(.custom(sansName, size: 9.5))
                .tracking(2.09) // .22em at 9.5pt
                .foregroundStyle(PaperTokens.inkFaint)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 18)
        .background(PaperTokens.slip)
        .overlay(alignment: .leading) {
            Rectangle().fill(model.personaTint).frame(width: 2)
        }
        .shadow(color: PaperTokens.ink.opacity(0.1), radius: 0, x: 1, y: 2)
        .padding(.horizontal, Spacing.pageMargin)
        .id(msg.id)
    }

    /// Your message: right-aligned, outlined (no fill), sans-serif — unsigned, per the
    /// mock. Capped at ~264pt, an approximation of the mock's `max-width:78%` (SwiftUI
    /// has no percent-of-container sizing without a GeometryReader, which would be
    /// overkill for one decorative cap).
    private func userBubble(_ msg: ChatMessage) -> some View {
        Text(msg.content)
            .font(.custom(sansName, size: 13.5).weight(.light))
            .lineSpacing(8.78) // lh 1.85 at 13.5pt: (1.85 - 1 - 0.2) * 13.5
            .foregroundStyle(PaperTokens.ink)
            .padding(.vertical, 13)
            .padding(.horizontal, 16)
            .overlay(Rectangle().stroke(PaperTokens.ink.opacity(0.28), lineWidth: 1))
            .frame(maxWidth: 264, alignment: .trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, Spacing.pageMargin)
            .id(msg.id)
    }

    // MARK: Composer

    private var inputBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(PaperTokens.rule).frame(height: 1)
            HStack(spacing: 12) {
                TextField("寫給小當家…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.custom(sansName, size: 13).weight(.light))
                    .foregroundStyle(PaperTokens.ink)
                    .focused($isDraftFocused)
                Button {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    draft = ""
                    Task { await model.send(text) }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(model.personaTint)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.35 : 1)
            }
            .padding(.top, 14)
            .padding(.horizontal, Spacing.pageMargin)
            .padding(.bottom, Spacing.sm)
        }
    }
}

/// Formats a chef slip's sign-off timestamp. The mock signs slips two ways —
/// `小當家 · 18:40` for same-day messages, a bare relative/absolute day otherwise (e.g.
/// `昨天`) — but the app has no persona display-name field to put before the time (only
/// `copy_pack`/`tint` are exposed via `AppModel`, see `DesignTokens.swift`), so this
/// renders the time/day portion only. Falls back to `chineseDateString` (CounterView.swift)
/// for anything older than yesterday, rather than adding a weekday-name table the mock's
/// exact `週日 19:30` form would need.
func slipSignature(for date: Date, now: Date = Date(), timezone: TimeZone = .current) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timezone
    if calendar.isDate(date, inSameDayAs: now) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = timezone
        return formatter.string(from: date)
    }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
       calendar.isDate(date, inSameDayAs: yesterday) {
        return "昨天"
    }
    return chineseDateString(date, timezone: timezone)
}
