import SwiftUI
import UniformTypeIdentifiers

struct WeekBoardView: View {
    @EnvironmentObject private var model: AppModel
    @State private var expandedDayID: UUID?
    // No auto-clear on failure — matches the plan's "no client-side timeout" constraint.
    // Recovery is dismiss/reopen (resets @State) or the cancel-ritual escape hatch via chat.
    @State private var pendingRitualStart = false
    @State private var pendingSwapDates: Set<String> = []

    var body: some View {
        List {
            Section("這週") {
                ForEach(model.thisWeekDays) { day in
                    dayRow(day)
                }
            }
            Section("下週") {
                nextWeekContent
            }
        }
        .listStyle(.plain)
        .onChange(of: model.nextWeekDays) { _, _ in pendingSwapDates.removeAll() }
        .onChange(of: model.thisWeekDays) { _, _ in pendingSwapDates.removeAll() }
    }

    @ViewBuilder
    private var nextWeekContent: some View {
        switch nextWeekDisplayState(week: model.nextWeek, days: model.nextWeekDays) {
        case .startRitual:
            if pendingRitualStart {
                pendingRow(text: "chef is thinking…")
            } else {
                Button("開始本週儀式") {
                    pendingRitualStart = true
                    Task { await model.startRitual() }
                }
            }
        case .ritualInProgress:
            Text("本週儀式進行中 — 到聊天室繼續")
                .foregroundStyle(.secondary)
        case .days(let days):
            ForEach(days) { day in dayRow(day) }
        }
    }

    @ViewBuilder
    private func dayRow(_ day: PlanDay) -> some View {
        if pendingSwapDates.contains(day.date) {
            pendingRow(text: "對調中…")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(day.dish)
                    Text(day.mode).font(.caption).foregroundStyle(.secondary)
                    if day.status != "planned" {
                        Text(statusLabel(day.status)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let prep = day.prepNote {
                        Text(prep).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if expandedDayID == day.id, let reasoning = day.reasoning {
                    Text(reasoning).font(.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                expandedDayID = expandedDayID == day.id ? nil : day.id
            }
            .onDrag { NSItemProvider(object: day.date as NSString) }
            .onDrop(of: [.text], isTargeted: nil) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: NSString.self) { reading, _ in
                    guard let draggedDate = reading as? String, draggedDate != day.date else { return }
                    Task { @MainActor in
                        pendingSwapDates.insert(draggedDate)
                        pendingSwapDates.insert(day.date)
                        await model.requestSwap(dateA: draggedDate, dateB: day.date)
                    }
                }
                return true
            }
        }
    }

    private func pendingRow(text: String) -> some View {
        HStack {
            ProgressView()
            Text(text).foregroundStyle(.secondary)
        }
    }

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "cooked": return "已煮"
        case "skipped": return "skip"
        default: return status
        }
    }
}
