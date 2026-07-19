import SwiftUI

struct CounterView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showWeekBoard = false
    @State private var showShoppingList = false

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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding()
    }
}
