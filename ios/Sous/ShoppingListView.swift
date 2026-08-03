import SwiftUI

/// E1 · 採買清單 (shopping) — Reference: design_handoff_sous_m3/README.md "E1 · 採買清單
/// (shopping)" and `Sous App v2.dc.html` lines 634-682.
///
/// Uses a plain `ScrollView`/`VStack` composition rather than `List` — this screen has
/// no swipe/reorder needs, and manual layout gives exact control over the mock's 56pt
/// row height, aisle-chapter placement, and hairline row rules, avoiding `List`'s
/// default section/row inset chrome fighting the paper design's precise spacing.
///
/// Scope note: the mock also shows a "staples nudge" note box — a chef-voice callout
/// about a specific item deliberately left off the list (e.g. "醬油快沒了吧?我沒放進清
/// 單"). That's personalized content keyed to a real missing ingredient; there's no
/// such per-household nudge data or copy_pack key today, and generating one is a
/// content/brain concern, not a view restyle (see the mock's own caption: "The staples
/// nudge is a note, never an auto-added row"). Only the persistent `offline_note`
/// caption — an actual seeded copy_pack key — is implemented here, per task-8-brief.md.
struct ShoppingListView: View {
    @EnvironmentObject private var model: AppModel

    private var serifName: String { serifFontName(bundled: FontBook.isSerifBundled) }
    private var sansName: String { sansFontName(bundled: FontBook.isSansBundled) }

    /// Chinese display names for shopping list section labels, matching the canonical
    /// section vocabulary from ShoppingListLogic.swift. Keys are normalized (lowercased,
    /// trimmed), so lookups must normalize the input section before querying.
    /// Falls back to .capitalized for unrecognized sections.
    private static let chineseSectionNames: [String: String] = [
        "produce": "蔬果",
        "meat": "肉·海鮮",
        "seafood": "肉·海鮮",
        "dairy": "冷藏",
        "fridge": "冷藏",
        "pantry": "乾貨",
        "breakfast": "早餐",
    ]

    /// Normalize a section string for lookup consistency with ShoppingListLogic.
    private func normalizedSectionKey(_ section: String?) -> String {
        (section ?? "").lowercased().trimmingCharacters(in: .whitespaces)
    }

    /// Get the display name for a section: Chinese label if recognized, otherwise
    /// English .capitalized fallback.
    private func displaySectionName(_ section: String) -> String {
        let normalized = normalizedSectionKey(section)
        return Self.chineseSectionNames[normalized] ?? section.capitalized
    }

    private var remainingCount: Int { uncheckedCount(model.shoppingItems) }
    private var totalCount: Int { model.shoppingItems.count }
    private var progressFraction: CGFloat {
        guard totalCount > 0 else { return 0 }
        return CGFloat(totalCount - remainingCount) / CGFloat(totalCount)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            progressRule
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(groupedShoppingItems(model.shoppingItems), id: \.section) { group in
                        sectionBlock(group)
                    }
                }
                .padding(.bottom, Spacing.lg)
            }
            offlineNote
        }
        .background(PaperTokens.stock)
        .task { await model.loadShoppingItems() }
    }

    // MARK: Running head

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("採買清單")
                .font(.custom(sansName, size: 10))
                .tracking(3.4) // .34em at 10pt
                .foregroundStyle(PaperTokens.inkFaint)
            Spacer()
            Text("還剩 \(remainingCount) 項")
                .font(.custom(sansName, size: 10))
                .tracking(3.4) // .34em at 10pt
                .foregroundStyle(PaperTokens.inkFaint)
        }
        .padding(.horizontal, Spacing.pageMargin)
        .padding(.top, Spacing.sm)
    }

    /// Fills with `model.personaTint`, proportional to checked/total — a real value
    /// (not decorative), so `GeometryReader` is warranted here (cf. `ChatView.
    /// userBubble`'s comment on skipping it for a purely decorative max-width cap).
    private var progressRule: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(PaperTokens.rule)
                Rectangle()
                    .fill(model.personaTint)
                    .frame(width: proxy.size.width * progressFraction)
            }
        }
        .frame(height: 1)
        .padding(.horizontal, Spacing.pageMargin)
        .padding(.top, 14)
    }

    // MARK: Aisle sections

    private func sectionBlock(_ group: ShoppingSectionGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(displaySectionName(group.section))
                .font(.custom(sansName, size: 10))
                .tracking(4.2) // .42em at 10pt — seal-tint aisle chapter label
                .foregroundStyle(model.personaTint)
            ForEach(group.items) { item in
                row(item)
            }
        }
        .padding(.horizontal, Spacing.pageMargin)
        .padding(.top, Spacing.lg)
    }

    private func row(_ item: ShoppingItem) -> some View {
        Button {
            Task { await model.toggleShoppingItem(item) }
        } label: {
            HStack(spacing: Spacing.md) {
                checkbox(checked: item.checked)
                Text(item.name)
                    .font(.custom(serifName, size: 16))
                    .strikethrough(item.checked)
                    .foregroundStyle(PaperTokens.ink)
                Spacer(minLength: 0)
                if item.checked {
                    // Quantity replaced by 已買 — colour alone never carries the
                    // checked/unchecked distinction (README E1 caption).
                    Text("已買")
                        .font(.custom(sansName, size: 10.5))
                        .tracking(1.47) // .14em at 10.5pt
                        .foregroundStyle(PaperTokens.inkDim)
                } else if let qty = item.qty {
                    Text(qty)
                        .font(.custom(serifName, size: 14))
                        .foregroundStyle(PaperTokens.inkDim)
                        .monospacedDigit()
                }
            }
            .padding(.vertical, 15)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            Rectangle().fill(PaperTokens.rule).frame(height: 1)
        }
        // Applied last so the row's bottom rule dims with it too, matching the mock
        // (opacity:.5 on the whole row box, border included).
        .opacity(item.checked ? 0.5 : 1)
    }

    private func checkbox(checked: Bool) -> some View {
        ZStack {
            if checked {
                Rectangle().fill(model.personaTint)
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(PaperTokens.stock)
            } else {
                Rectangle().stroke(PaperTokens.ruleStrong, lineWidth: 1)
            }
        }
        .frame(width: 24, height: 24)
    }

    // MARK: Footer

    /// `offline_note` copy_pack key — a persistent caption below the list, not a
    /// conditional banner: no network-reachability detection exists in this codebase,
    /// so this is always shown rather than toggled on an actual offline state (see
    /// task-8-brief.md).
    private var offlineNote: some View {
        Text(model.personaCopy["offline_note"] ?? "打勾照樣有效,回到訊號範圍我再同步。")
            .font(.custom(sansName, size: 10.5))
            .tracking(1.47) // .14em at 10.5pt
            .foregroundStyle(PaperTokens.inkDim)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .padding(.horizontal, Spacing.pageMargin)
    }
}
