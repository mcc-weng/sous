import SwiftUI

struct CounterView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showWeekBoard = false
    @State private var showShoppingList = false
    @State private var showCookbook = false
    @State private var showNotificationsSettings = false
    @State private var showCookModeForTonight = false
    @State private var cookModeRecipe: Recipe?
    @State private var cookModePlanDay: PlanDay?

    private var tonightRecipe: Recipe? {
        guard let dish = model.tonight?.dish else { return nil }
        return model.recipes.first { $0.title == dish }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            tonightCard
            chipRow
            Divider()
            ChatView()
        }
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
    }

    private var chipRow: some View {
        HStack(spacing: 12) {
            Button {
                showWeekBoard = true
            } label: {
                Label("本週", systemImage: "calendar")
            }
            Button {
                showShoppingList = true
            } label: {
                Label("買菜 \(uncheckedCount(model.shoppingItems))", systemImage: "cart")
            }
            Button {
                showCookbook = true
            } label: {
                Label("食譜本", systemImage: "book.closed")
            }
            Button {
                showNotificationsSettings = true
            } label: {
                Label("通知", systemImage: "bell")
            }
        }
        .buttonStyle(.bordered)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private var header: some View {
        HStack {
            Text(model.household?.name ?? "…").font(.headline)
            Spacer()
            let present = chefIsPresent(workerSeenAt: model.household?.workerSeenAt)
            Label(present ? "chef in" : "chef out",
                  systemImage: present ? "flame.fill" : "moon.zzz")
                .font(.caption)
                .foregroundStyle(present ? .orange : .secondary)
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var tonightCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tonight").font(.caption).foregroundStyle(.secondary)
            Text(model.tonight?.dish ?? "—").font(.title2.bold())
            HStack(spacing: 8) {
                if let mode = model.tonight?.mode {
                    Text(mode).font(.caption2).padding(4)
                        .background(.quaternary, in: Capsule())
                }
                if let prep = model.tonight?.prepNote {
                    Text(prep).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let recipe = tonightRecipe {
                Button("開始煮") {
                    cookModeRecipe = recipe
                    cookModePlanDay = model.tonight
                    showCookModeForTonight = true
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding()
        .fullScreenCover(isPresented: $showCookModeForTonight) {
            if let cookModeRecipe, let cookModePlanDay {
                CookModeView(recipe: cookModeRecipe, planDay: cookModePlanDay).environmentObject(model)
            }
        }
    }
}
