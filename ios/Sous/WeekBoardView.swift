import SwiftUI

struct WeekBoardView: View {
    @EnvironmentObject private var model: AppModel
    @State private var expandedDayID: UUID?
    // No auto-clear on failure — matches the plan's "no client-side timeout" constraint.
    // Recovery is dismiss/reopen (resets @State) or the cancel-ritual escape hatch via chat.
    @State private var pendingRitualStart = false
    @State private var pendingSwapDates: Set<String> = []
    // Long-press-to-select-then-swap: a real-device exit check found List row-to-row
    // drag-and-drop unreliable with both onDrag/onDrop and draggable/dropDestination
    // (drop target never registered a hover or drop, with or without a competing tap
    // gesture) — this achieves the same swap outcome with plain, reliable gestures.
    @State private var selectedForSwap: String?

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
        .onChange(of: model.nextWeekDays) { _, _ in pendingSwapDates.removeAll(); selectedForSwap = nil }
        .onChange(of: model.thisWeekDays) { _, _ in pendingSwapDates.removeAll(); selectedForSwap = nil }
        .task { await model.loadWeekBoard() }
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
                    if selectedForSwap == day.date {
                        Image(systemName: "arrow.left.arrow.right.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                    if let prep = day.prepNote {
                        Text(prep).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if expandedDayID == day.id, let reasoning = day.reasoning {
                    Text(reasoning).font(.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .listRowBackground(selectedForSwap == day.date ? Color.accentColor.opacity(0.15) : nil)
            .onTapGesture {
                expandedDayID = expandedDayID == day.id ? nil : day.id
            }
            .onLongPressGesture {
                handleLongPress(on: day.date)
            }
        }
    }

    private func handleLongPress(on date: String) {
        guard let selected = selectedForSwap else {
            selectedForSwap = date
            return
        }
        if selected == date {
            selectedForSwap = nil // long-press the same day again to cancel
            return
        }
        pendingSwapDates.insert(selected)
        pendingSwapDates.insert(date)
        selectedForSwap = nil
        Task { await model.requestSwap(dateA: selected, dateB: date) }
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
