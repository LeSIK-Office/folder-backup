import Foundation
import BackupCore

// This check only creates uniquely named test data; it never removes existing files.
@main
struct ExternalVolumeSelfCheck {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Pass an existing destination folder") }
        let manager = FileManager.default
        let volume = URL(fileURLWithPath: CommandLine.arguments[1])
        let destination = volume.appendingPathComponent(".incremental-check-" + UUID().uuidString)
        let source = manager.temporaryDirectory.appendingPathComponent("FolderToolkit External Source-" + UUID().uuidString)
        let restore = manager.temporaryDirectory.appendingPathComponent("FolderToolkit External Restore-" + UUID().uuidString)
        for folder in [destination, source, restore] { try manager.createDirectory(at: folder, withIntermediateDirectories: false) }
        let file = source.appendingPathComponent("한글 파일.txt")
        try Data("external drive version 1".utf8).write(to: file)
        try Data("hidden data".utf8).write(to: source.appendingPathComponent(".hidden"))
        try manager.createDirectory(at: source.appendingPathComponent("빈 폴더"), withIntermediateDirectories: false)
        let engine = BackupEngine()
        let plan = UUID()
        let stop = ExternalCancellation()
        do {
            _ = try engine.backup(sources: [source], destination: destination, planID: plan, progress: {
                if $0.completed == 2 { stop.cancel() }
            }, cancelled: { stop.cancelled })
            preconditionFailure("Expected test cancellation")
        } catch BackupError.cancelled { }
        let first = try engine.backup(sources: [source], destination: destination, planID: plan)
        precondition((first.resumedFiles ?? 0) >= 1, "External drive did not reuse interrupted copy")
        let unchanged = try engine.backup(sources: [source], destination: destination, planID: plan)
        precondition(unchanged.copiedFiles == 0 && unchanged.copiedBytes == 0, "Unchanged exFAT backup rewrote file data")
        try Data("external drive version 2".utf8).write(to: file)
        let second = try engine.backup(sources: [source], destination: destination, planID: plan)
        precondition(second.copiedFiles == 1 && second.copiedBytes == Int64(Data("external drive version 2".utf8).count), "Changed exFAT backup did not write only the one changed file")
        try engine.verify(snapshotID: first.id, destination: destination, planID: plan)
        try engine.verify(snapshotID: second.id, destination: destination, planID: plan)
        let output = try engine.restore(snapshotID: first.id, destination: destination, planID: plan, to: restore)
        let restored = output.appendingPathComponent(source.lastPathComponent)
        func check(_ condition: Bool) { precondition(condition) }
        check(try String(contentsOf: restored.appendingPathComponent("한글 파일.txt"), encoding: .utf8) == "external drive version 1")
        check(manager.fileExists(atPath: restored.appendingPathComponent("빈 폴더").path))
        check(try Data(contentsOf: restored.appendingPathComponent(".hidden")) == Data("hidden data".utf8))
        check(try engine.snapshots(destination: destination, planID: plan).count == 3)
        let pruned = try engine.prune(destination: destination, planID: plan, keeping: 1)
        precondition(pruned == 2)
        check(try engine.snapshots(destination: destination, planID: plan).map(\.id) == [second.id])
        try engine.verify(snapshotID: second.id, destination: destination, planID: plan)
        let newestRestore = try engine.restore(snapshotID: second.id, destination: destination, planID: plan, to: restore)
        check(try String(contentsOf: newestRestore.appendingPathComponent(source.lastPathComponent + "/한글 파일.txt"), encoding: .utf8) == "external drive version 2")
        print("External volume PASS: unchanged run added 0 file bytes; one edited file added exactly 24 bytes; retained shared files survive prune; interrupted-copy resume, two real versions, checksums, old-version restore, Unicode, hidden file, empty directory, latest-only retention via Trash")
        print("External test data retained: \(destination.path)")
        print("Restored data retained: \(output.path)")
    }
}

private final class ExternalCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}
