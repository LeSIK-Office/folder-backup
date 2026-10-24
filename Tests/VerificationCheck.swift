import Foundation
import BackupCore
import CryptoKit
import SQLite3
import Darwin

@main enum VerificationCheck {
    static func main() throws {
        func check(_ value: Bool, _ message: String = "") { precondition(value, message) }
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent("FolderBackup-Verification-" + UUID().uuidString)
        defer { try? fm.removeItem(at: fixture) }
        let source = fixture.appendingPathComponent("Source")
        let destination = fixture.appendingPathComponent("Backup")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        let plan = UUID(), engine = BackupEngine()
        let planRoot = destination.appendingPathComponent("Toolkit Backups/" + plan.uuidString)
        try fm.createDirectory(at: planRoot, withIntermediateDirectories: true)
        let database = planRoot.appendingPathComponent(".objects.sqlite")
        var db: OpaquePointer?
        check(sqlite3_open(database.path, &db) == SQLITE_OK); sqlite3_close(db)
        for name in ["same-a", "same-b"] { try Data("shared contents".utf8).write(to: source.appendingPathComponent(name)) }
        try Data("unaffected contents".utf8).write(to: source.appendingPathComponent("good"))
        let large = source.appendingPathComponent("large.bin")
        fm.createFile(atPath: large.path, contents: nil)
        let output = try FileHandle(forWritingTo: large)
        for _ in 0..<32 { try output.write(contentsOf: Data(repeating: 42, count: 1024 * 1024)) }; try output.close()
        let first = try engine.backup(sources: [source], destination: destination, planID: plan)
        try fm.moveItem(at: source.appendingPathComponent("same-a"), to: source.appendingPathComponent("renamed"))
        let second = try engine.backup(sources: [source], destination: destination, planID: plan)
        let before = try inventory(destination), originalSource = try inventory(source)
        let progress = ProgressCapture()
        let results = try engine.verifyVersions(snapshotIDs: [first.id, second.id], destination: destination, planID: plan,
            progress: { progress.add($0) })
        check(results.count == 2 && results.allSatisfy { $0.passed && $0.files == 4 })
        check(results.map(\.uniqueObjectsChecked) == [3, 0], "Shared objects were read again across versions")
        check(progress.last?.completed == 4 && progress.last?.total == 4)
        check(try inventory(destination) == before && inventory(source) == originalSource, "Verification wrote to backup/source")
        print("PASS: full read-only checks, packed/loose contents, renames, progress, 8 file references / 3 unique reads")

        let lockURL = planRoot.appendingPathComponent(".lock")
        let lockBytes = try Data(contentsOf: lockURL)
        try fm.removeItem(at: lockURL)
        let noLockBefore = try inventory(destination)
        check(try engine.verifyVersions(snapshotIDs: [first.id], destination: destination, planID: plan)[0].passed)
        check(!fm.fileExists(atPath: lockURL.path))
        check(try inventory(destination) == noLockBefore)
        try lockBytes.write(to: lockURL)
        let paths = [planRoot] + (fm.enumerator(at: planRoot, includingPropertiesForKeys: nil)!.allObjects as! [URL])
        for path in paths { try fm.setAttributes([.posixPermissions: (try path.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true) ? 0o555 : 0o444], ofItemAtPath: path.path) }
        let readOnlyBefore = try inventory(destination)
        check(try engine.verifyVersions(snapshotIDs: [first.id], destination: destination, planID: plan)[0].passed)
        check(try inventory(destination) == readOnlyBefore)
        for path in paths { try fm.setAttributes([.posixPermissions: (try path.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true) ? 0o755 : 0o644], ofItemAtPath: path.path) }
        let afterReadOnly = try inventory(destination)
        print("PASS: read-only files/directories and missing legacy lock; no SQLite sidecars or lock created")

        let cancellation = ProgressCapture()
        do {
            _ = try engine.verifyVersions(snapshotIDs: [first.id], destination: destination, planID: plan,
                progress: { update in if update.completed == 1 { cancellation.stop() } }, cancelled: { cancellation.stopped })
            preconditionFailure("Cancellation was ignored")
        } catch BackupError.cancelled { }
        check(try inventory(destination) == afterReadOnly)
        do {
            _ = try engine.verifyVersions(snapshotIDs: [".partial-current"], destination: destination, planID: plan)
            preconditionFailure("Incomplete version was accepted")
        } catch { }
        let lock = open(planRoot.appendingPathComponent(".lock").path, O_RDWR)
        check(lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0)
        do {
            _ = try engine.verifyVersions(snapshotIDs: [first.id], destination: destination, planID: plan)
            preconditionFailure("Concurrent writer was ignored")
        } catch BackupError.busy { }
        _ = flock(lock, LOCK_UN); close(lock)
        print("PASS: cancellation keeps data unchanged, incomplete versions rejected, active writer excluded")

        check(sqlite3_open(database.path, &db) == SQLITE_OK)
        let sharedHash = String(SHA256.hash(data: Data("shared contents".utf8)).description.suffix(64))
        check(sqlite3_exec(db, "UPDATE objects SET data=zeroblob(length(data)) WHERE hash='" + sharedHash + "'", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let largeEntry = try engine.snapshotFiles(snapshotID: first.id, destination: destination, planID: plan).first { $0.path.hasSuffix("large.bin") }!
        let key = largeEntry.storageKey!
        try fm.removeItem(at: planRoot.appendingPathComponent(".objects/" + key.prefix(2) + "/" + key))
        let damagedBefore = try inventory(destination)
        let damaged = try engine.verifyVersions(snapshotIDs: [first.id, second.id], destination: destination, planID: plan)
        check(damaged.allSatisfy { !$0.passed && $0.files == 4 && $0.issues.count == 3 })
        check(damaged[1].issues.contains { $0.path.hasSuffix("renamed") })
        check(damaged.allSatisfy { $0.issues.contains { $0.path.hasSuffix("large.bin") } })
        check(damaged.map(\.uniqueObjectsChecked) == [3, 0])
        check(try inventory(destination) == damagedBefore)
        print("PASS: every missing/corrupt alias reported; unaffected contents checked; failed shared objects read only once")

        let manifest = planRoot.appendingPathComponent(first.id + "/manifest.json")
        let saved = try Data(contentsOf: manifest)
        try Data("[]".utf8).write(to: manifest)
        let catalogResult = try engine.verifyVersions(snapshotIDs: [first.id], destination: destination, planID: plan)[0]
        check(!catalogResult.passed && catalogResult.issues.first?.path == "manifest.json")
        var entries = try JSONSerialization.jsonObject(with: saved) as! [[String: Any]]
        for i in entries.indices { entries[i]["bytes"] = Int64.max }
        try JSONSerialization.data(withJSONObject: entries).write(to: manifest)
        check(try !engine.verifyVersions(snapshotIDs: [first.id], destination: destination, planID: plan)[0].passed)
        try saved.write(to: manifest)
        print("PASS: truncated and overflowing catalogs cannot be marked healthy")
        print("VerificationCheck: all workflows passed; test fixture removed on exit")
    }

    static func inventory(_ root: URL) throws -> [String: String] {
        let fm = FileManager.default
        let paths = [root] + (fm.enumerator(at: root, includingPropertiesForKeys: nil)!.allObjects as! [URL])
        var result: [String: String] = [:]
        for path in paths {
            let a = try fm.attributesOfItem(atPath: path.path)
            let digest: String
            if a[.type] as? FileAttributeType == .typeRegular { digest = String(SHA256.hash(data: try Data(contentsOf: path)).description) }
            else { digest = String(describing: a[.type]) }
            result[path.path] = digest + ":" + String((a[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0) + ":" + String(describing: a[.posixPermissions])
        }
        return result
    }
}

private final class ProgressCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: BackupVerificationProgress?
    private var cancelled = false
    func add(_ update: BackupVerificationProgress) { lock.lock(); value = update; lock.unlock() }
    var last: BackupVerificationProgress? { lock.lock(); defer { lock.unlock() }; return value }
    func stop() { lock.lock(); cancelled = true; lock.unlock() }
    var stopped: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}
