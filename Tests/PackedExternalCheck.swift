import Foundation
import BackupCore

@main enum PackedExternalCheck {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Pass an existing external test folder") }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FolderToolkit-packed-check-" + UUID().uuidString)
        let source = root.appendingPathComponent("Source")
        let internalDestination = root.appendingPathComponent("Backup")
        let externalDestination = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(".packed-check-" + UUID().uuidString)
        for url in [source, internalDestination, externalDestination.appendingPathComponent("Toolkit Backups")] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        for index in 0..<1000 {
            try autoreleasepool { try Data("small unique file \(index)".utf8).write(to: source.appendingPathComponent("file-\(index)")) }
        }
        try Data(repeating: 42, count: 2 * 1024 * 1024).write(to: source.appendingPathComponent("large"))
        let engine = BackupEngine(), plan = UUID()
        let first = try engine.backup(sources: [source], destination: internalDestination, planID: plan)
        let oldRoot = try engine.snapshotURL(snapshotID: first.id, destination: internalDestination, planID: plan).deletingLastPathComponent()
        try fm.copyItem(at: oldRoot, to: externalDestination.appendingPathComponent("Toolkit Backups/" + plan.uuidString))
        let before = try engine.storageBytes(destination: externalDestination, planID: plan)
        let du = Process()
        du.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        du.arguments = ["-sk", externalDestination.appendingPathComponent("Toolkit Backups/" + plan.uuidString).path]
        let pipe = Pipe(); du.standardOutput = pipe
        try du.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        du.waitUntilExit()
        let kib = Int64(String(decoding: output, as: UTF8.self).split(whereSeparator: \.isWhitespace)[0])!
        precondition(du.terminationStatus == 0 && before == kib * 1024)
        let compacted = try engine.compactStorage(destination: externalDestination, planID: plan)
        let after = try engine.storageBytes(destination: externalDestination, planID: plan)
        precondition(compacted == 1000 && after < before / 4)
        try engine.verify(snapshotID: first.id, destination: externalDestination, planID: plan)
        try Data("edited".utf8).write(to: source.appendingPathComponent("file-0"))
        try fm.moveItem(at: source.appendingPathComponent("file-1"), to: root.appendingPathComponent("removed"))
        let second = try engine.backup(sources: [source], destination: externalDestination, planID: plan)
        precondition(second.copiedFiles == 1 && second.copiedBytes == 6)
        let third = try engine.backup(sources: [source], destination: externalDestination, planID: plan)
        precondition(third.copiedFiles == 0 && third.copiedBytes == 0)
        let old = try engine.restore(snapshotID: first.id, destination: externalDestination, planID: plan, to: root)
        let oldFile = try Data(contentsOf: old.appendingPathComponent("Source/file-1"))
        precondition(oldFile == Data("small unique file 1".utf8))
        let newest = try engine.restore(snapshotID: third.id, destination: externalDestination, planID: plan, to: root)
        precondition(!fm.fileExists(atPath: newest.appendingPathComponent("Source/file-1").path))
        let newFile = try Data(contentsOf: newest.appendingPathComponent("Source/file-0"))
        precondition(newFile == Data("edited".utf8))
        let pruned = try engine.prune(destination: externalDestination, planID: plan, keeping: 1)
        precondition(pruned == 2)
        try engine.verify(snapshotID: third.id, destination: externalDestination, planID: plan)
        print("Packed exFAT check PASS: before=\(before), after=\(after), compacted=\(compacted), changed=6 bytes, unchanged=0 bytes, old/deleted and latest restore, retention verified; fixture=\(externalDestination.path)")
        try fm.trashItem(at: externalDestination, resultingItemURL: nil)
    }
}
