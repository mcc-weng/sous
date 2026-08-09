import XCTest
@testable import Sous

final class FakeNotificationScheduler: TimerNotificationScheduling {
    private(set) var scheduled: [(id: UUID, label: String, fireAt: Date)] = []
    private(set) var cancelled: [UUID] = []

    func schedule(id: UUID, label: String, fireAt: Date) {
        scheduled.append((id, label, fireAt))
    }

    func cancel(id: UUID) {
        cancelled.append(id)
    }
}

@MainActor
final class CookTimerModelTests: XCTestCase {
    // MARK: CookTimer — pure wall-clock math

    func testRemainingComputedFromEndTimeNotDecremented() {
        var timer = CookTimer(label: "步驟", duration: 300)
        timer.endTime = Date().addingTimeInterval(300)
        let remainingNow = timer.remaining(now: Date())
        let remainingLater = timer.remaining(now: Date().addingTimeInterval(10))
        XCTAssertEqual(remainingNow, 300, accuracy: 0.5)
        XCTAssertEqual(remainingLater, 290, accuracy: 0.5)
    }

    func testRemainingNeverGoesNegative() {
        var timer = CookTimer(label: "步驟", duration: 10)
        timer.endTime = Date().addingTimeInterval(-5)
        XCTAssertEqual(timer.remaining(), 0)
    }

    func testIsCompleteWhenPastEndTime() {
        var timer = CookTimer(label: "步驟", duration: 10)
        timer.endTime = Date().addingTimeInterval(-1)
        XCTAssertTrue(timer.isComplete())
    }

    func testIsRunningReflectsEndTimePresence() {
        var timer = CookTimer(label: "步驟", duration: 10)
        XCTAssertFalse(timer.isRunning)
        timer.endTime = Date().addingTimeInterval(10)
        XCTAssertTrue(timer.isRunning)
    }

    // MARK: CookTimerModel — step timer

    func testSetStepTimerStartsRunningAndSchedulesNotification() {
        let scheduler = FakeNotificationScheduler()
        let model = CookTimerModel(scheduler: scheduler)
        model.setStepTimer(label: "步驟 一", duration: 120)
        XCTAssertEqual(model.stepTimer?.isRunning, true)
        XCTAssertEqual(model.stepTimer?.remaining() ?? 0, 120, accuracy: 0.5)
        XCTAssertEqual(scheduler.scheduled.count, 1)
        XCTAssertEqual(scheduler.scheduled.first?.label, "步驟 一")
    }

    func testSetStepTimerReplacesPreviousAndCancelsItsNotification() {
        let scheduler = FakeNotificationScheduler()
        let model = CookTimerModel(scheduler: scheduler)
        model.setStepTimer(label: "步驟 一", duration: 120)
        let firstId = model.stepTimer!.id
        model.setStepTimer(label: "步驟 二", duration: 60)
        XCTAssertNotEqual(model.stepTimer!.id, firstId)
        XCTAssertEqual(scheduler.cancelled, [firstId])
        XCTAssertEqual(scheduler.scheduled.count, 2)
    }

    func testToggleStepTimerPausePreservesRemainingTime() {
        let scheduler = FakeNotificationScheduler()
        let model = CookTimerModel(scheduler: scheduler)
        model.setStepTimer(label: "步驟", duration: 100)
        model.toggleStepTimerPause() // pause
        XCTAssertFalse(model.stepTimer!.isRunning)
        let pausedRemaining = model.stepTimer!.remainingAtPause
        XCTAssertEqual(pausedRemaining, 100, accuracy: 0.5)
        model.toggleStepTimerPause() // resume
        XCTAssertTrue(model.stepTimer!.isRunning)
        XCTAssertEqual(model.stepTimer!.remaining(), 100, accuracy: 0.5)
    }

    func testClearStepTimerCancelsNotificationAndClearsStepTimer() {
        let scheduler = FakeNotificationScheduler()
        let model = CookTimerModel(scheduler: scheduler)
        model.setStepTimer(label: "步驟 一", duration: 120)
        let timerId = model.stepTimer!.id
        model.clearStepTimer()
        XCTAssertNil(model.stepTimer)
        XCTAssertTrue(scheduler.cancelled.contains(timerId))
    }

    // MARK: CookTimerModel — background timers independent of the step timer

    func testBackgroundTimerSurvivesStepTimerReplacement() {
        let scheduler = FakeNotificationScheduler()
        let model = CookTimerModel(scheduler: scheduler)
        let riceId = model.addBackgroundTimer(label: "白飯", duration: 600)
        model.setStepTimer(label: "步驟 一", duration: 60)
        model.setStepTimer(label: "步驟 二", duration: 60)
        XCTAssertEqual(model.backgroundTimers.first(where: { $0.id == riceId })?.remaining() ?? 0,
                       600, accuracy: 0.5)
    }

    func testPausingStepTimerDoesNotPauseBackgroundTimers() {
        let scheduler = FakeNotificationScheduler()
        let model = CookTimerModel(scheduler: scheduler)
        let riceId = model.addBackgroundTimer(label: "白飯", duration: 600)
        model.setStepTimer(label: "步驟", duration: 60)
        model.toggleStepTimerPause()
        XCTAssertTrue(model.backgroundTimers.first(where: { $0.id == riceId })!.isRunning)
    }

    func testMultipleBackgroundTimersPauseIndependently() {
        let scheduler = FakeNotificationScheduler()
        let model = CookTimerModel(scheduler: scheduler)
        let riceId = model.addBackgroundTimer(label: "白飯", duration: 600)
        let soupId = model.addBackgroundTimer(label: "湯", duration: 900)
        model.togglePause(id: riceId)
        XCTAssertFalse(model.backgroundTimers.first(where: { $0.id == riceId })!.isRunning)
        XCTAssertTrue(model.backgroundTimers.first(where: { $0.id == soupId })!.isRunning)
    }

    func testRemoveBackgroundTimerCancelsNotificationAndRemovesIt() {
        let scheduler = FakeNotificationScheduler()
        let model = CookTimerModel(scheduler: scheduler)
        let riceId = model.addBackgroundTimer(label: "白飯", duration: 600)
        model.removeBackgroundTimer(id: riceId)
        XCTAssertTrue(scheduler.cancelled.contains(riceId))
        XCTAssertFalse(model.backgroundTimers.contains { $0.id == riceId })
    }
}
