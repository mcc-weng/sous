import SwiftUI

struct CounterView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            tonightCard
            Divider()
            ChatView()
        }
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
