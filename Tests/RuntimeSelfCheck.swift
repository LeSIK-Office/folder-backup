import AppKit
import BackupCore
import Foundation

@main
struct RuntimeSelfCheck {
    @MainActor
    static func main() async throws {
        func check(_ value: Bool, _ message: String = "") { precondition(value, message) }
        let longFailure = BackupError.incomplete(Array(repeating: "/private/developer/path: NSCocoaErrorDomain 260", count: 23480))
        let shortSummary = BackupStore.failureSummary(longFailure)
        check(shortSummary.count < 180 && !shortSummary.contains("\n") && !shortSummary.contains("NSCocoaErrorDomain"), "Raw file details leaked into the alert")
        check(BackupStore.failureSummary(NSError(domain: NSPOSIXErrorDomain, code: 13)) == L10n.text("Backup could not access a file or destination. Check the details and allow access to the affected folder."))
        check(BackupStore.failureSummary(NSError(domain: NSPOSIXErrorDomain, code: 28)) == L10n.text("Backup stopped because storage is full. Copied files are safe. Free up space, then resume the backup."))
        check(BackupStore.failureSummary(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)) == L10n.text("Backup stopped because storage is full. Copied files are safe. Free up space, then resume the backup."))
        let originalLanguage = L10n.selection
        let languageStore = BackupStore(storageURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"), startScheduler: false)
        languageStore.maintenance = true
        languageStore.status = L10n.text("Cleaning up saved backups…")
        languageStore.language = .es
        check(languageStore.maintenance && languageStore.status == L10n.text("Cleaning up saved backups…"), "Language change cleared an active maintenance status")
        languageStore.language = originalLanguage
        let arguments = CommandLine.arguments
        if arguments.count == 3, arguments[1] == "--resolve-settings" {
            let reloaded = BackupStore(storageURL: URL(fileURLWithPath: arguments[2]), startScheduler: false)
            precondition(reloaded.error == nil, reloaded.error ?? "")
            precondition(reloaded.plans.count == 1)
            let plan = reloaded.plans[0]
            for selection in plan.sources + [plan.destination] {
                let resolved = try selection.resolve()
                precondition(resolved.standardizedFileURL.resolvingSymlinksInPath().path == URL(fileURLWithPath: selection.path).standardizedFileURL.resolvingSymlinksInPath().path)
            }
            precondition(plan.history.count == 6)
            print("Process restart self-check PASS: persisted source/destination bookmarks resolve in a fresh process, volume identity and history preserved")
            return
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
        }
        let monthly = BackupSchedule(frequency: .monthly, hour: 20, day: 31)
        precondition(monthly.next(after: date(2026, 1, 31, 21), calendar: calendar) == date(2026, 2, 28, 20))
        precondition(monthly.next(after: date(2028, 1, 31, 21), calendar: calendar) == date(2028, 2, 29, 20))
        precondition(BackupSchedule(frequency: .daily, hour: 2, minute: 30).next(after: date(2026, 3, 7, 20), calendar: calendar) == date(2026, 3, 8, 3))
        precondition(BackupSchedule(frequency: .weekly, hour: 9, weekday: 2).next(after: date(2026, 10, 19, 9, 37), calendar: calendar) == date(2026, 10, 26, 9))
        precondition(BackupSchedule(frequency: .manual).next(after: Date()) == nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FolderToolkit-RuntimeSelfCheck-" + UUID().uuidString)
        let source = directory.appendingPathComponent("Source")
        let destination = directory.appendingPathComponent("Destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("sample.txt")
        try Data("version one".utf8).write(to: file)
        var sourceSelection = try FolderSelection(url: source)
        sourceSelection.volumeUUID = "a-different-volume"
        do { _ = try sourceSelection.resolve(); preconditionFailure("Wrong volume identity was accepted") } catch { }
        let storage = directory.appendingPathComponent("Settings/plans.json")
        let store = BackupStore(storageURL: storage, startScheduler: false)
        let plan = BackupPlan(name: "Runtime self-check", sources: [try FolderSelection(url: source)], destination: try FolderSelection(url: destination), schedule: BackupSchedule(frequency: .continuous))
        store.savePlan(plan)
        precondition(store.error == nil, store.error ?? "")
        precondition(store.plans.count == 1)
        store.maintenance = true
        store.run(plan)
        precondition(store.runningID == nil)
        store.maintenance = false
        store.run(plan)
        precondition(store.runningID == plan.id)
        precondition(store.plans[0].lastAttempt != nil)
        func waitForCompletion(expectSuccess: Bool = true) async throws {
            for _ in 0..<200 where store.runningID != nil { try await Task.sleep(for: .milliseconds(25)) }
            precondition(store.runningID == nil, "Backup did not finish")
            if expectSuccess { precondition(store.error == nil, store.error ?? "") }
        }
        try await waitForCompletion()
        precondition(store.plans[0].lastSuccess != nil)
        precondition(store.plans[0].history.count == 1)
        let engine = BackupEngine()
        check(try engine.snapshots(destination: destination, planID: plan.id).count == 1)
        store.plans[0].nextRun = .distantPast
        store.checkSchedules()
        try await waitForCompletion()
        check(try engine.snapshots(destination: destination, planID: plan.id).count == 1, "Unchanged continuous scan made a new snapshot")
        let oldModification = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]!
        try Data("version two".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: oldModification], ofItemAtPath: file.path)
        store.plans[0].nextRun = .distantPast
        store.checkSchedules()
        try await waitForCompletion()
        check(try engine.snapshots(destination: destination, planID: plan.id).count == 2, "Preserved mtime edit was missed")
        store.run(plan)
        store.cancel()
        try await waitForCompletion()
        precondition(store.plans[0].history.first?.outcome == .cancelled)
        precondition(store.progress?.total == nil && store.status == L10n.text("Stopped · Copied files will be reused when resumed."), "Queued progress overwrote cancelled state")
        check(try engine.snapshots(destination: destination, planID: plan.id).count == 2)
        store.plans[0].destination.volumeUUID = "a-different-volume"
        store.run(plan)
        try await waitForCompletion(expectSuccess: false)
        precondition(store.error != nil)
        precondition(store.plans[0].history.first?.outcome == .failure)
        store.plans[0].destination.volumeUUID = try FolderSelection(url: destination).volumeUUID
        store.savePlan(store.plans[0])
        store.plans[0].nextRun = .distantPast
        store.checkSchedules()
        try await waitForCompletion()
        precondition(store.plans[0].lastError == nil, "Successful unchanged scan retained an old error")
        precondition(store.plans[0].history.count == 4)
        let baseline = try engine.snapshots(destination: destination, planID: plan.id).first!
        let baselineURL = try engine.snapshotURL(snapshotID: baseline.id, destination: destination, planID: plan.id)
        try FileManager.default.moveItem(at: baselineURL, to: directory.appendingPathComponent("RetainedLatestSnapshot"))
        store.plans[0].nextRun = .distantPast
        store.checkSchedules()
        try await waitForCompletion()
        precondition(store.plans[0].history.count == 5, "Removing latest snapshot left current content unprotected")
        check(try engine.snapshots(destination: destination, planID: plan.id).count == 2)
        let planRoot = destination.appendingPathComponent("Toolkit Backups").appendingPathComponent(plan.id.uuidString)
        try FileManager.default.moveItem(at: planRoot, to: directory.appendingPathComponent("RetainedPlanArchive"))
        store.plans[0].nextRun = .distantPast
        store.checkSchedules()
        try await waitForCompletion()
        check(try engine.snapshots(destination: destination, planID: plan.id).count == 1, "Missing archive root was not recreated")
        let reloaded = BackupStore(storageURL: storage, startScheduler: false)
        precondition(reloaded.plans[0].history.count == 6)
        precondition(reloaded.plans[0].lastFingerprint != nil)
        reloaded.togglePause(reloaded.plans[0])
        reloaded.plans[0].nextRun = .distantPast
        reloaded.checkSchedules()
        precondition(reloaded.runningID == nil)
        if arguments.count == 3, arguments[1] == "--save-process-fixture" {
            let restartStore = BackupStore(storageURL: URL(fileURLWithPath: arguments[2]), startScheduler: false)
            restartStore.savePlan(store.plans[0])
            precondition(restartStore.error == nil, restartStore.error ?? "")
        }
        reloaded.removePlan(id: plan.id)
        precondition(reloaded.plans.isEmpty)
        check(try engine.snapshots(destination: destination, planID: plan.id).count == 1, "Removing a plan removed backup data")
        let corruptURL = directory.appendingPathComponent("corrupt.json")
        let corrupt = Data("invalid json".utf8)
        try corrupt.write(to: corruptURL)
        let broken = BackupStore(storageURL: corruptURL, startScheduler: false)
        precondition(broken.error != nil)
        broken.removePlan(id: UUID())
        check(try Data(contentsOf: corruptURL) == corrupt)

        let policyURL = directory.appendingPathComponent("policy-settings.json")
        let policyStore = BackupStore(storageURL: policyURL, startScheduler: false)
        var configured = BackupPlan(name: "Policy check", sources: [try FolderSelection(url: source)], destination: try FolderSelection(url: destination))
        configured.schedule = BackupSchedule(frequency: .weekly, hour: 7, minute: 35, weekday: 2)
        configured.retention = BackupRetention(mode: .latest)
        configured.exclusions = [".DS_Store", "node_modules"]
        policyStore.savePlan(configured)
        let policyReload = BackupStore(storageURL: policyURL, startScheduler: false)
        precondition(policyReload.plans[0].retention?.mode == .latest)
        precondition(policyReload.plans[0].schedule == configured.schedule)
        precondition(policyReload.plans[0].exclusions == configured.exclusions)
        func waitForPolicy() async throws {
            for _ in 0..<400 where policyStore.runningID != nil { try await Task.sleep(for: .milliseconds(25)) }
            precondition(policyStore.runningID == nil)
            precondition(policyStore.error == nil, policyStore.error ?? "")
        }
        policyStore.run(configured)
        let editedSchedule = BackupSchedule(frequency: .weekly, hour: 9, minute: 15, weekday: 4)
        policyStore.saveSchedule(id: configured.id, schedule: editedSchedule, paused: true)
        precondition(policyStore.runningID == configured.id, "Editing schedule stopped the active backup")
        precondition(policyStore.error == nil)
        try await waitForPolicy()
        precondition(policyStore.plans[0].history.first?.outcome == .success)
        precondition(policyStore.plans[0].schedule == editedSchedule && policyStore.plans[0].paused)
        precondition(policyStore.plans[0].nextRun == editedSchedule.next(after: Date()), "Completion restored the old schedule")
        let editedReload = BackupStore(storageURL: policyURL, startScheduler: false)
        precondition(editedReload.plans[0].schedule == editedSchedule && editedReload.plans[0].paused)
        policyStore.togglePause(policyStore.plans[0])
        precondition(!policyStore.plans[0].paused)
        print("Live schedule edit PASS: active backup completes, edited next run survives completion and restart, schedule toggle works")
        let retained = try engine.snapshots(destination: destination, planID: configured.id).first!
        policyStore.run(configured); policyStore.cancel()
        try await waitForPolicy()
        check(try engine.snapshots(destination: destination, planID: configured.id).first?.id == retained.id, "Cancellation replaced the last completed backup")
        try Data("policy new version".utf8).write(to: file)
        policyStore.run(configured)
        try await waitForPolicy()
        let kept = try engine.snapshots(destination: destination, planID: configured.id)
        precondition(kept.count == 1 && kept[0].id != retained.id, "Latest-only retention did not keep only the new completed version")
        precondition(policyStore.plans[0].history.first?.outcome == .success)
        let retryStore = BackupStore(storageURL: directory.appendingPathComponent("retry-settings.json"), startScheduler: false)
        var retryPlan = BackupPlan(name: "Failure schedule", sources: [try FolderSelection(url: source)], destination: try FolderSelection(url: destination))
        retryStore.savePlan(retryPlan)
        retryStore.plans[0].sources[0].volumeUUID = "not-the-source-volume"
        retryStore.plans[0].nextRun = .distantPast
        retryStore.checkSchedules()
        for _ in 0..<200 where retryStore.runningID != nil { try await Task.sleep(for: .milliseconds(25)) }
        precondition(retryStore.plans[0].history.first?.outcome == .failure)
        precondition(retryStore.plans[0].nextRun! > Date(), "Failed overdue plan retried every minute")
        retryStore.checkSchedules()
        precondition(retryStore.runningID == nil)
        retryPlan.lastAttempt = Date()
        retryPlan.nextRun = .distantPast
        retryStore.savePlan(retryPlan)
        let interruptedStore = BackupStore(storageURL: directory.appendingPathComponent("retry-settings.json"), startScheduler: false)
        precondition(interruptedStore.plans[0].paused, "Interrupted backup was automatically restarted")
        precondition(interruptedStore.plans[0].history.first?.outcome == .cancelled)
        interruptedStore.checkSchedules()
        precondition(interruptedStore.runningID == nil)
        print("Retry/restart self-check PASS: failure advances schedule, interrupted run is recorded and paused without automatic restart")
        print("Settings/retention self-check PASS: weekly schedule + exclusions persisted, last completed version survives cancellation, latest-only replaces after successful backup via Trash")
        print("Runtime self-check PASS: calendar/DST, volume identity, real backup, ctime change detection, unchanged scan, persistence, pause, maintenance, cancellation, canonical plan lookup, failure history, cleared recovered error, missing latest snapshot regeneration, missing archive root regeneration, plan removal preservation, corrupt settings preservation")
        print("Test artifacts: \(directory.path)")
    }
}
