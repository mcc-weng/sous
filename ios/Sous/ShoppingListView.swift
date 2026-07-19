import SwiftUI

struct ShoppingListView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List {
            ForEach(groupedShoppingItems(model.shoppingItems), id: \.section) { group in
                Section(group.section.capitalized) {
                    ForEach(group.items) { item in
                        Button {
                            Task { await model.toggleShoppingItem(item) }
                        } label: {
                            HStack {
                                Image(systemName: item.checked ? "checkmark.circle.fill" : "circle")
                                VStack(alignment: .leading) {
                                    Text(item.name).strikethrough(item.checked)
                                    if let qty = item.qty {
                                        Text(qty).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(item.checked ? .secondary : .primary)
                    }
                }
            }
        }
        .listStyle(.plain)
    }
}
