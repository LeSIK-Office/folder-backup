import Foundation
import BackupCore

@main enum VerificationRuntimeCheck {
    @MainActor static func main() async throws {
        func check(_ value: Bool, _ message: String = "") { precondition(value, message) }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FolderBackup-VerificationRuntime-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("Source"), destination = root.appendingPathComponent("Backup")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        try Data("verification runtime".utf8).write(to: source.appendingPathComponent("sample"))
        let plan = BackupPlan(name: "Verification", sources: [try FolderSelection(url: source)], destination: try FolderSelection(url: destination), schedule: BackupSchedule(frequency: .manual))
        let engine = BackupEngine()
        let first = try engine.backup(sources: [source], destination: destination, planID: plan.id)
        let second = try engine.backup(sources: [source], destination: destination, planID: plan.id)
        let settings = root.appendingPathComponent("Settings/plans.json")
        let store = BackupStore(storageURL: settings, startScheduler: false)
        store.savePlan(plan)
        let original = try Data(contentsOf: settings)
        check(!String(decoding: original, as: UTF8.self).contains("verificationSchedule"))
        let reloaded = BackupStore(storageURL: settings, startScheduler: false)
        check((reloaded.plans[0].verificationSchedule ?? .off) == .off)
        check(try Data(contentsOf: settings) == original)
        reloaded.checkSchedules(); check(reloaded.verificationPlanID == nil)
        reloaded.saveSchedule(id: plan.id, schedule: plan.schedule, paused: true, verificationSchedule: .daily)
        let before = try VerificationInventory.capture(destination)
        func wait() async throws {
            for _ in 0..<800 where reloaded.maintenance || reloaded.runningID != nil { try await Task.sleep(for: .milliseconds(10)) }
            check(!reloaded.maintenance && reloaded.runningID == nil, "Verification never finished")
        }
        let now = Date()
        reloaded.checkSchedules(now: now); check(reloaded.verificationPlanID == plan.id)
        try await wait()
        let records = reloaded.plans[0].verificationResults!
        check(records.count == 2 && records.values.allSatisfy { $0.passed && $0.files == 1 })
        check(try VerificationInventory.capture(destination) == before)
        let fresh = BackupStore(storageURL: settings, startScheduler: false)
        check(fresh.plans[0].verificationResults?.count == 2 && fresh.plans[0].verificationSchedule == .daily)
        let saved = records[first.id]!
        check(!VerificationSchedule.daily.isDue(saved, at: saved.lastVerifiedAt.addingTimeInterval(3600)))
        check(VerificationSchedule.daily.isDue(saved, at: saved.lastVerifiedAt.addingTimeInterval(172800)))
        check(!VerificationSchedule.off.isDue(nil, at: now))
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        for frequency in [VerificationSchedule.weekly, .monthly] {
            let component: Calendar.Component = frequency == .weekly ? .weekOfYear : .month
            let due = calendar.date(byAdding: component, value: 1, to: saved.lastVerifiedAt)!
            check(!frequency.isDue(saved, at: due.addingTimeInterval(-1), calendar: calendar))
            check(frequency.isDue(saved, at: due, calendar: calendar))
        }
        reloaded.checkSchedules(now: now.addingTimeInterval(7200)); try await wait()
        check(reloaded.plans[0].verificationResults?[first.id]?.lastVerifiedAt == saved.lastVerifiedAt)
        let third = try engine.backup(sources: [source], destination: destination, planID: plan.id)
        reloaded.checkSchedules(now: now.addingTimeInterval(14400)); try await wait()
        check(reloaded.plans[0].verificationResults?.count == 3)
        check(reloaded.plans[0].verificationResults?[third.id]?.passed == true)
        check(reloaded.plans[0].verificationResults?[second.id]?.lastVerifiedAt == records[second.id]?.lastVerifiedAt)
        reloaded.verifyVersions(planID: plan.id, snapshotID: first.id); reloaded.cancelVerification(); try await wait()
        check(reloaded.plans[0].verificationResults?[first.id]?.lastVerifiedAt == saved.lastVerifiedAt)
        reloaded.saveSchedule(id: plan.id, schedule: BackupSchedule(frequency: .continuous), paused: false, verificationSchedule: .daily)
        reloaded.run(reloaded.plans[0]); try await wait()
        check(reloaded.plans[0].verificationResults?.count == 4, "Continuous backups starved verification of the new version")
        reloaded.saveSchedule(id: plan.id, schedule: plan.schedule, paused: true)
        let entry = try engine.snapshotFiles(snapshotID: first.id, destination: destination, planID: plan.id).first { $0.kind == .file }!
        let key = entry.storageKey!
        try Data("damaged".utf8).write(to: destination.appendingPathComponent("Toolkit Backups/" + plan.id.uuidString + "/.objects/" + key.prefix(2) + "/" + key))
        reloaded.verifyVersions(planID: plan.id, snapshotID: first.id); try await wait()
        check(reloaded.plans[0].verificationResults?[first.id]?.passed == false)
        check(reloaded.plans[0].verificationResults?[first.id]?.issues.first?.path == "Source/sample")
        check(reloaded.runningID == nil)
        print("VerificationRuntimeCheck PASS: old settings/default OFF; per-job opt-in; paused backup independent; existing/new versions; interval boundaries; dedup; persisted results; cancel preserves timestamps; failure paths/status; read-only store")
    }
}

private enum VerificationInventory {
    static func capture(_ root: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for case let url as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)! {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { files[url.path] = try Data(contentsOf: url) }
        }
        return files
    }
}
