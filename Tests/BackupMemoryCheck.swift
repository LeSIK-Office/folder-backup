import Foundation
import BackupCore
import Darwin

@main
enum BackupMemoryCheck {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FolderToolkit-memory-" + UUID().uuidString)
        let source = root.appendingPathComponent("Source")
        let destination = root.appendingPathComponent("Backup")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        let file = source.appendingPathComponent("large.bin")
        let descriptor = open(file.path, O_CREAT | O_WRONLY, 0o600)
        precondition(descriptor >= 0)
        precondition(ftruncate(descriptor, 256 * 1024 * 1024) == 0)
        close(descriptor)
        for index in 0..<2000 {
            try autoreleasepool {
                try Data("small file \(index)".utf8).write(to: source.appendingPathComponent("file-\(index)"))
            }
        }
        let engine = BackupEngine()
        let plan = UUID()
        // Keep one outer pool, matching a long synchronous job on a detached task.
        try autoreleasepool {
            let first = try engine.backup(sources: [source], destination: destination, planID: plan)
            precondition(first.files == 2001)
            let compacted = try engine.compactStorage(destination: destination, planID: plan)
            precondition(compacted == 2000)
            let second = try engine.backup(sources: [source], destination: destination, planID: plan)
            precondition(second.copiedFiles == 0)
            let restored = try engine.restore(snapshotID: first.id, destination: destination, planID: plan, to: root)
            let restoredSize = try fm.attributesOfItem(atPath: restored.appendingPathComponent("Source/large.bin").path)[.size] as? NSNumber
            precondition(restoredSize?.int64Value == 256 * 1024 * 1024)
            var usage = rusage()
            precondition(getrusage(RUSAGE_SELF, &usage) == 0)
            let megabytes = usage.ru_maxrss / (1024 * 1024)
            print("BackupMemoryCheck peak=\(megabytes) MiB, backup/packing/incremental/restore passed, fixture=\(root.path)")
            if !CommandLine.arguments.contains("--baseline") {
                precondition(megabytes < 256, "File buffers accumulated across operations")
            }
        }
    }
}
