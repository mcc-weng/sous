import SwiftUI

/// A2 · 廚房 (Kitchen Counter — root) — tonight's dish, one action, and the four
/// destinations. Reference: design_handoff_sous_m3/README.md "A2 · 廚房 (Kitchen
/// Counter — root)" and Sous App v2.dc.html lines 63-109.
///
/// Scope note: this restyle re-skins the existing shell (running head, tonight
/// section, one action, four-destination footer, embedded chat) to the paper design
/// language. It does not add the mock's his-slip/reply-chip section or the 想吃什麼
/// swipe-card row — those are net-new interactive surfaces, not a restyle, and 便條
/// (A3, the slip thread) is its own task (Task 6). See task-5-report.md "Concerns".
struct CounterView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showWeekBoard = false
    @State private var showShoppingList = false
    @State private var showCookbook = false
    @State private var showNotificationsSettings = false
    @State private var showCookModeForTonight = false
    @State private var showExploreDeck = false
    @State private var showOnboarding = false
    @State private var cookModeRecipe: Recipe?
    @State private var cookModePlanDay: PlanDay?

    private var serifName: String { serifFontName(bundled: FontBook.isSerifBundled) }
    private var sansName: String { sansFontName(bundled: FontBook.isSansBundled) }

    private var tonightRecipe: Recipe? {
        guard let dish = model.tonight?.dish else { return nil }
        return model.recipes.first { $0.title == dish }
    }

    /// `empty_book` copy_pack key (migration 0016) — shown in the dish-name slot when
    /// there's no `tonight` row yet (README §G "第一頁", the empty-book state). This
    /// task implements the copy substitution only; the full two-door state (排這一週 /
    /// 今晚先煮一道) is new interactive behaviour, out of scope here (see file header).
    private var dishNameText: String {
        model.tonight?.dish ?? (model.personaCopy["empty_book"] ?? "這本書還沒有第一道菜")
    }

    private var metaLine: String? {
        let parts = [model.tonight?.mode, model.tonight?.prepNote].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

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
            tonightSection
            exploreDeckPeek
                .padding(.horizontal, Spacing.pageMargin)
                .padding(.top, 20)
            footerNav
            ChatView()
        }
        .background(PaperTokens.stock)
        .sheet(isPresented: $showWeekBoard) {
            WeekBoardView().environmentObject(model)
        }
        .sheet(isPresented: $showShoppingList) {
            ShoppingListView().environmentObject(model)
        }
        .sheet(isPresented: $showCookbook) {
            CookbookView().environmentObject(model)
        }
        .sheet(isPresented: $showNotificationsSettings) {
            NotificationsSettingsView().environmentObject(model)
        }
        .task { await model.loadCookbook() }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView().environmentObject(model)
        }
        .fullScreenCover(isPresented: $showExploreDeck) {
            ExploreDeckView().environmentObject(model)
        }
        .onChange(of: model.onboardingRestartRequested) { _, requested in
            guard requested else { return }
            showOnboarding = true
            model.onboardingRestartRequested = false
        }
        .task {
            await model.loadPreferences()
            showOnboarding = needsOnboarding(preferencesContent: model.preferencesContent)
        }
    }

    // MARK: Running head

    private var header: some View {
        HStack(alignment: .center) {
            Text(model.household?.name ?? "…")
                .font(.custom(sansName, size: 10))
                .tracking(3.4) // .34em at 10pt
                .foregroundStyle(PaperTokens.inkFaint)
            Spacer()
            presenceOrDate
        }
        .padding(.horizontal, Spacing.pageMargin)
        .padding(.top, Spacing.sm)
    }

    /// Presence swap (the one behaviour change in this task): `chefIsPresent(...)` is
    /// unchanged (Models.swift:88, tested by PresenceTests) — only how it renders
    /// changed, from a flame/moon icon + colour label to a seal-glyph treatment. When
    /// present: nothing extra, just today's date — "a book's author has no presence
    /// indicator when things are fine" (README line 61). When absent: a hollow seal
    /// (transparent fill, 1px `ink@30%` border — deliberately NOT `model.personaTint`,
    /// since an absent state shouldn't wear the active accent colour) plus the
    /// existing `presence_out` copy string (README §G "離線", line 352-354).
    @ViewBuilder
    private var presenceOrDate: some View {
        if chefIsPresent(workerSeenAt: model.household?.workerSeenAt) {
            Text(chineseDateString(Date(), timezone: householdTimezone))
                .font(.custom(sansName, size: 10))
                .tracking(3.4) // .34em at 10pt
                .foregroundStyle(PaperTokens.inkFaint)
        } else {
            HStack(spacing: 6) {
                Text("當")
                    .font(.custom(serifName, size: 9))
                    .foregroundStyle(PaperTokens.inkFaint)
                    .frame(width: 18, height: 18)
                    .overlay(Rectangle().stroke(PaperTokens.leader, lineWidth: 1)) // ink@30%, no fill
                Text(model.personaCopy["presence_out"] ?? "外出中")
                    .font(.custom(sansName, size: 10))
                    .tracking(3.4) // .34em at 10pt
                    .foregroundStyle(PaperTokens.inkFaint)
            }
        }
    }

    // MARK: Tonight

    private var tonightSection: some View {
        VStack(spacing: 0) {
            Text("今　晚")
                .font(.custom(sansName, size: 10))
                .tracking(5) // .5em at 10pt
                .foregroundStyle(model.personaTint)
                .padding(.top, 26)

            Text(dishNameText)
                .font(.custom(serifName, size: 31))
                .tracking(1.24) // .04em at 31pt
                .lineSpacing(6.2) // lh 1.4 (see AuthView headline comment: SwiftUI's
                // .lineSpacing() adds to the font's own ~1.2x leading rather than
                // replacing it, so use (multiplier - 1 - 0.2) * size)
                .multilineTextAlignment(.center)
                .foregroundStyle(PaperTokens.ink)
                .padding(.top, 16)

            if let metaLine {
                Text(metaLine)
                    .font(.custom(sansName, size: 10.5))
                    .tracking(2.31) // .22em at 10.5pt
                    .foregroundStyle(PaperTokens.inkDim)
                    .padding(.top, 13)
            }

            // Only shown once there's an actual tonight row — an always-on "dish
            // photo" placeholder next to the empty_book fallback text would show a
            // photo slot for a dish that doesn't exist, which reads as incoherent.
            if model.tonight != nil {
                photoPlate
                    .padding(.top, 22)
            }

            if let recipe = tonightRecipe {
                VStack(spacing: 0) {
                    Button {
                        cookModeRecipe = recipe
                        cookModePlanDay = model.tonight
                        showCookModeForTonight = true
                    } label: {
                        Text("開始做菜")
                            .font(.custom(sansName, size: 13.5))
                            .fontWeight(.medium)
                            .tracking(4.59) // .34em at 13.5pt
                            .foregroundStyle(PaperTokens.stock)
                            .frame(maxWidth: .infinity)
                            .padding(16)
                            .background(PaperTokens.ink) // ink-filled: the one
                            // irreversible action on this screen
                    }
                    .buttonStyle(.plain)

                    Text("進入灶前 · 畫面會暗下來")
                        .font(.custom(sansName, size: 10.5))
                        .tracking(1.47) // .14em at 10.5pt
                        .foregroundStyle(PaperTokens.inkFaint)
                        .padding(.top, 11)
                }
                .padding(.top, 20)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Spacing.pageMargin)
        .fullScreenCover(isPresented: $showCookModeForTonight) {
            if let cookModeRecipe, let cookModePlanDay {
                CookModeView(recipe: cookModeRecipe, planDay: cookModePlanDay).environmentObject(model)
            }
        }
    }

    /// Static placeholder for tonight's dish photo — the design mock always renders
    /// this slot as a hatched placeholder (`料理照片`, "dish photo"); no photo field
    /// exists on `Recipe`/`PlanDay` to bind here, so wiring a real image is out of
    /// scope for a data-untouched restyle. Uses a flat tint rather than the mock's
    /// exact diagonal-hatch gradient — same placeholder purpose, without hand-rolled
    /// Canvas trigonometry for a decorative-only element.
    private var photoPlate: some View {
        Rectangle()
            .fill(PaperTokens.ink.opacity(0.06))
            .frame(height: 178)
            .overlay(
                Text("料理照片")
                    .font(.system(size: 10, design: .monospaced))
                    .tracking(1.6) // .16em at 10pt
                    .foregroundStyle(PaperTokens.inkDim)
            )
    }

    // MARK: 想吃什麼 — Explore Deck (D3) entry point

    private var exploreDeckPeek: some View {
        Button { showExploreDeck = true } label: {
            HStack(spacing: 12) {
                Rectangle().fill(PaperTokens.stockAlt).frame(width: 54, height: 54)
                VStack(alignment: .leading, spacing: 3) {
                    Text("想吃什麼")
                        .font(.custom(sansName, size: 10))
                        .tracking(2)
                        .foregroundStyle(PaperTokens.inkFaint)
                    Text("滑一下,我記著")
                        .font(.custom(serifName, size: 14.5))
                        .foregroundStyle(PaperTokens.ink)
                }
                Spacer()
                Image(systemName: "arrow.right").foregroundStyle(model.personaTint)
            }
            .padding(14)
            .overlay(Rectangle().stroke(PaperTokens.rule, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: Footer — the four destinations

    private var footerNav: some View {
        HStack(spacing: 0) {
            footerCell("本週") { showWeekBoard = true }
            divider
            footerCell("買菜", count: uncheckedCount(model.shoppingItems)) { showShoppingList = true }
            divider
            footerCell("食譜本") { showCookbook = true }
            divider
            footerCell("通知") { showNotificationsSettings = true }
        }
        .padding(.top, 24)
        .overlay(alignment: .top) { Rectangle().fill(PaperTokens.rule).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(PaperTokens.rule).frame(height: 1) }
        .padding(.horizontal, Spacing.pageMargin)
    }

    private var divider: some View {
        Rectangle()
            .fill(PaperTokens.ink.opacity(0.14))
            .frame(width: 1)
    }

    private func footerCell(_ title: String, count: Int? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title)
                if let count {
                    Text("\(count)")
                        .foregroundStyle(model.personaTint)
                }
            }
            .font(.custom(sansName, size: 11))
            .tracking(1.98) // .18em at 11pt
            .foregroundStyle(PaperTokens.inkDim)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.vertical, 16)
        }
        .buttonStyle(.plain)
    }
}

/// Formats `date` as `八月二日`-style Chinese numerals (month `月` day `日`), matching
/// the running-head date in the A2 design mock. A manual digit mapping rather than a
/// locale numbering system — Foundation's Han-numeral locale variants aren't
/// guaranteed to produce this exact word-per-digit shape for two-digit values, and a
/// silently-wrong locale render is worse than an explicit, testable pure function.
func chineseDateString(_ date: Date, timezone: TimeZone) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timezone
    let month = calendar.component(.month, from: date)
    let day = calendar.component(.day, from: date)
    return "\(chineseNumeral(month))月\(chineseNumeral(day))日"
}

func chineseNumeral(_ n: Int) -> String {
    let digits = ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
    guard n > 0, n < 100 else { return "\(n)" }
    if n < 10 { return digits[n] }
    if n == 10 { return "十" }
    if n < 20 { return "十" + digits[n % 10] }
    let tens = n / 10
    let ones = n % 10
    return digits[tens] + "十" + (ones == 0 ? "" : digits[ones])
}
