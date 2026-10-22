import XCTest
@testable import FolderBackup

final class RuntimeTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    func testHourlyDailyAndWeeklyAreCalendarAnchored() {
        let now = date(2026, 10, 19, 9, 37)
        XCTAssertEqual(BackupSchedule(frequency: .hourly, minute: 15).next(after: now, calendar: calendar), date(2026, 10, 19, 10, 15))
        XCTAssertEqual(BackupSchedule(frequency: .daily, hour: 9, minute: 30).next(after: now, calendar: calendar), date(2026, 10, 20, 9, 30))
        XCTAssertEqual(BackupSchedule(frequency: .weekly, hour: 10, weekday: 2).next(after: now, calendar: calendar), date(2026, 10, 19, 10))
        XCTAssertEqual(BackupSchedule(frequency: .weekly, hour: 9, weekday: 2).next(after: now, calendar: calendar), date(2026, 10, 26, 9))
    }

    func testMonthlyClampsToLastDayAndNeverSkipsAMonth() {
        let monthly = BackupSchedule(frequency: .monthly, hour: 20, day: 31)
        XCTAssertEqual(monthly.next(after: date(2026, 1, 31, 21), calendar: calendar), date(2026, 2, 28, 20))
        XCTAssertEqual(monthly.next(after: date(2026, 2, 28, 21), calendar: calendar), date(2026, 3, 31, 20))
        XCTAssertEqual(monthly.next(after: date(2028, 1, 31, 21), calendar: calendar), date(2028, 2, 29, 20))
    }

    func testDailyScheduleAcrossDaylightSavingTime() {
        let daily = BackupSchedule(frequency: .daily, hour: 2, minute: 30)
        let next = daily.next(after: date(2026, 3, 7, 20), calendar: calendar)!
        XCTAssertEqual(calendar.component(.day, from: next), 8)
        XCTAssertEqual(calendar.component(.hour, from: next), 3)
        XCTAssertEqual(daily.next(after: date(2026, 10, 31, 20), calendar: calendar), date(2026, 11, 1, 2, 30))
    }

    func testContinuousAndManual() {
        let now = Date()
        XCTAssertEqual(BackupSchedule(frequency: .continuous).next(after: now), now.addingTimeInterval(60))
        XCTAssertNil(BackupSchedule(frequency: .manual).next(after: now))
    }

    @MainActor
    func testCorruptSettingsAreNeverOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FolderBackup-RuntimeTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("plans.json")
        let corrupt = Data("not valid JSON".utf8)
        try corrupt.write(to: path)
        let store = BackupStore(storageURL: path, startScheduler: false)
        XCTAssertNotNil(store.error)
        store.removePlan(id: UUID())
        XCTAssertEqual(try Data(contentsOf: path), corrupt)
    }

    @MainActor
    func testSaveReloadPauseAndRemovePreserveDestinationFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FolderBackup-RuntimeTests-" + UUID().uuidString)
        let source = directory.appendingPathComponent("Source")
        let destination = directory.appendingPathComponent("Destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let retained = destination.appendingPathComponent("existing-backup")
        try Data("preserve me".utf8).write(to: retained)
        let plan = BackupPlan(name: "Test", sources: [try FolderSelection(url: source)], destination: try FolderSelection(url: destination), schedule: BackupSchedule(frequency: .manual))
        let storage = directory.appendingPathComponent("Settings/plans.json")
        let store = BackupStore(storageURL: storage, startScheduler: false)
        store.savePlan(plan)
        XCTAssertNil(store.error)
        XCTAssertEqual(store.plans.first?.sources.first?.id, plan.sources.first?.id)
        let reloaded = BackupStore(storageURL: storage, startScheduler: false)
        XCTAssertEqual(reloaded.plans.first?.id, plan.id)
        reloaded.togglePause(plan)
        XCTAssertTrue(reloaded.plans[0].paused)
        reloaded.removePlan(id: plan.id)
        XCTAssertTrue(reloaded.plans.isEmpty)
        XCTAssertEqual(try String(contentsOf: retained, encoding: .utf8), "preserve me")
    }
}
