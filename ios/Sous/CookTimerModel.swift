// ios/Sous/CookTimerModel.swift
import Foundation
import UserNotifications

/// A single timer — the step timer or one background timer — expressed as an absolute
/// end-time rather than a countdown, so remaining time is always correct from the wall
/// clock alone: no invalidation bookkeeping needed across step navigation,
/// backgrounding, or app relaunch (design spec: "pausing the step timer must not pause
/// the rice").
struct CookTimer: Identifiable, Equatable {
    let id: UUID
    var label: String
    let duration: TimeInterval
    var endTime: Date?              // nil while paused or not yet started
    var remainingAtPause: TimeInterval

    init(id: UUID = UUID(), label: String, duration: TimeInterval) {
        self.id = id
        self.label = label
        self.duration = duration
        self.endTime = nil
        self.remainingAtPause = duration
    }

    var isRunning: Bool { endTime != nil }

    func remaining(now: Date = Date()) -> TimeInterval {
        guard let endTime else { return remainingAtPause }
        return max(0, endTime.timeIntervalSince(now))
    }

    func isComplete(now: Date = Date()) -> Bool {
        remaining(now: now) <= 0
    }
}

/// Abstracts local-notification scheduling so `CookTimerModel` is testable without a
/// real `UNUserNotificationCenter` (simulator/CI can't reliably assert on delivered
/// notifications). `LocalNotificationScheduler` is the real implementation; tests inject
/// a fake.
protocol TimerNotificationScheduling {
    func schedule(id: UUID, label: String, fireAt: Date)
    func cancel(id: UUID)
}

struct LocalNotificationScheduler: TimerNotificationScheduling {
    func schedule(id: UUID, label: String, fireAt: Date) {
        let content = UNMutableNotificationContent()
        content.title = label
        content.body = "時間到了。"
        content.sound = .default
        let interval = max(0.01, fireAt.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: id.uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    func cancel(id: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id.uuidString])
    }
}

/// The step timer and any number of independent background timers (e.g. rice, soup).
/// Every start/resume schedules exactly one local notification per timer so it pings
/// even if the user has switched apps; every pause/removal cancels it. Permission denial
/// degrades silently to wall-clock-only — starting a timer is never blocked on it.
@MainActor
final class CookTimerModel: ObservableObject {
    @Published private(set) var stepTimer: CookTimer?
    @Published private(set) var backgroundTimers: [CookTimer] = []

    private let scheduler: TimerNotificationScheduling
    private var didRequestNotificationPermission = false

    init(scheduler: TimerNotificationScheduling = LocalNotificationScheduler()) {
        self.scheduler = scheduler
    }

    private func requestNotificationPermissionIfNeeded() {
        guard !didRequestNotificationPermission else { return }
        didRequestNotificationPermission = true
        Task {
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        }
    }

    // MARK: step timer — replaced wholesale on every step change, never paused across
    // step navigation (advancing the step always starts a fresh timer for the new step)

    func setStepTimer(label: String, duration: TimeInterval) {
        if let old = stepTimer { scheduler.cancel(id: old.id) }
        var timer = CookTimer(label: label, duration: duration)
        start(&timer)
        stepTimer = timer
    }

    func toggleStepTimerPause() {
        guard var timer = stepTimer else { return }
        if timer.isRunning { pause(&timer) } else { start(&timer) }
        stepTimer = timer
    }

    // MARK: background timers — independent of the step timer and of each other

    @discardableResult
    func addBackgroundTimer(label: String, duration: TimeInterval) -> UUID {
        var timer = CookTimer(label: label, duration: duration)
        start(&timer)
        backgroundTimers.append(timer)
        return timer.id
    }

    func togglePause(id: UUID) {
        guard let index = backgroundTimers.firstIndex(where: { $0.id == id }) else { return }
        var timer = backgroundTimers[index]
        if timer.isRunning { pause(&timer) } else { start(&timer) }
        backgroundTimers[index] = timer
    }

    func removeBackgroundTimer(id: UUID) {
        scheduler.cancel(id: id)
        backgroundTimers.removeAll { $0.id == id }
    }

    // MARK: shared start/pause mechanics

    private func start(_ timer: inout CookTimer) {
        requestNotificationPermissionIfNeeded()
        let end = Date().addingTimeInterval(timer.remainingAtPause)
        timer.endTime = end
        scheduler.schedule(id: timer.id, label: timer.label, fireAt: end)
    }

    private func pause(_ timer: inout CookTimer) {
        timer.remainingAtPause = timer.remaining()
        timer.endTime = nil
        scheduler.cancel(id: timer.id)
    }
}
