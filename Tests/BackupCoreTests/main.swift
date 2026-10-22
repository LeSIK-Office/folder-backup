import Foundation
import BackupCore
import Darwin
import SQLite3

final class BackupEngineTests {
    private let fm = FileManager.default
    private let engine = BackupEngine()

    private func fixture() throws -> (URL, URL, URL) {
        let root = fm.temporaryDirectory.appendingPathComponent("FolderBackup-BackupTests-" + UUID().uuidString)
        let source = root.appendingPathComponent("원본")
        let destination = root.appendingPathComponent("Backup")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        return (root, source, destination)
    }

    private func storedFile(_ snapshot: BackupSnapshot, _ path: String, _ destination: URL, _ plan: UUID) throws -> URL {
        let folder = try engine.snapshotURL(snapshotID: snapshot.id, destination: destination, planID: plan)
        let entry = try require(engine.snapshotFiles(snapshotID: snapshot.id, destination: destination, planID: plan).first { $0.path == path })
        if let key = entry.storageKey { return folder.deletingLastPathComponent().appendingPathComponent(".objects/" + key.prefix(2) + "/" + key) }
        return folder.appendingPathComponent("Files/" + path)
    }

    private func write(_ value: String, _ url: URL) throws {
        try Data(value.utf8).write(to: url)
    }

    func testVersionedBackupRestoreAndIndependentIncrementalFiles() throws {
        let (root, source, destination) = try fixture()
        let plan = UUID()
        try write("first", source.appendingPathComponent("changed.txt"))
        try write("retained", source.appendingPathComponent("deleted.txt"))
        try write("stable", source.appendingPathComponent(".hidden"))
        try fm.createDirectory(at: source.appendingPathComponent("빈 폴더"), withIntermediateDirectories: false)
        let first = try engine.backup(sources: [source], destination: destination, planID: plan)
        try write("second", source.appendingPathComponent("changed.txt"))
        try fm.moveItem(at: source.appendingPathComponent("deleted.txt"), to: root.appendingPathComponent("moved-out.txt"))
        let second = try engine.backup(sources: [source], destination: destination, planID: plan)
        expectEqual(try engine.snapshots(destination: destination, planID: plan).count, 2)
        expectEqual(first.files, 3)
        expectEqual(second.files, 2)
        let original = try engine.restore(snapshotID: first.id, destination: destination, planID: plan, to: root)
        expectEqual(try String(contentsOf: original.appendingPathComponent("원본/changed.txt"), encoding: .utf8), "first")
        expectEqual(try String(contentsOf: original.appendingPathComponent("원본/deleted.txt"), encoding: .utf8), "retained")
        expect(fm.fileExists(atPath: original.appendingPathComponent("원본/빈 폴더").path))
        expectEqual(try String(contentsOf: source.appendingPathComponent("changed.txt"), encoding: .utf8), "second")
        for id in [first.id, second.id] { try engine.verify(snapshotID: id, destination: destination, planID: plan) }
        let firstHidden = try storedFile(first, "원본/.hidden", destination, plan)
        let secondHidden = try storedFile(second, "원본/.hidden", destination, plan)
        let firstInode = try fm.attributesOfItem(atPath: firstHidden.path)[.systemFileNumber] as? NSNumber
        let secondInode = try fm.attributesOfItem(atPath: secondHidden.path)[.systemFileNumber] as? NSNumber
        expectEqual(firstInode, secondInode)
        expectEqual(first.copiedFiles, 3)
        expectEqual(second.copiedFiles, 1)
        expectEqual(second.copiedBytes, 6)
        let third = try engine.backup(sources: [source], destination: destination, planID: plan)
        expectEqual(third.copiedFiles, 0)
        expectEqual(third.copiedBytes, 0)
        let restoredStable = try engine.restore(snapshotID: first.id, destination: destination, planID: plan, to: root, relativePaths: ["원본/.hidden"])
        expectEqual(try String(contentsOf: restoredStable.appendingPathComponent("원본/.hidden"), encoding: .utf8), "stable")
        let beside = try engine.restoreBesideOriginal(snapshotID: first.id, destination: destination, planID: plan)
        expectEqual(beside.count, 1)
        expectEqual(try fm.attributesOfItem(atPath: beside[0].deletingLastPathComponent().path)[.systemFileNumber] as? NSNumber,
                    try fm.attributesOfItem(atPath: source.deletingLastPathComponent().path)[.systemFileNumber] as? NSNumber)
        expectEqual(try String(contentsOf: beside[0].appendingPathComponent("changed.txt"), encoding: .utf8), "first")
    }

    func testIncrementalStorageAndCheckpointDoNotMultiplyCopies() throws {
        let (_, source, destination) = try fixture()
        let plan = UUID()
        try write("stable", source.appendingPathComponent("a"))
        try write("stable", source.appendingPathComponent("duplicate"))
        let first = try engine.backup(sources: [source], destination: destination, planID: plan)
        expectEqual(first.copiedFiles, 1)
        expectEqual(first.copiedBytes, 6)
        let object = try storedFile(first, "원본/a", destination, plan)
        let stableInode = try fm.attributesOfItem(atPath: object.path)[.systemFileNumber] as? NSNumber
        let stop = CancelState()
        expectThrows(try engine.backup(sources: [source], destination: destination, planID: plan,
            progress: { if $0.completed == 2 { stop.cancel() } }, cancelled: { stop.cancelled }))
        let partial = try require(engine.incompleteBackups(destination: destination, planID: plan).first)
        expectEqual(partial.lastPathComponent, ".partial-current")
        expect(fm.fileExists(atPath: partial.appendingPathComponent("checkpoint.jsonl").path))
        let second = try engine.backup(sources: [source], destination: destination, planID: plan)
        expectEqual(second.copiedFiles, 0)
        expectEqual(second.copiedBytes, 0)
        expectEqual(try fm.attributesOfItem(atPath: storedFile(second, "원본/a", destination, plan).path)[.systemFileNumber] as? NSNumber, stableInode)
        // A same-size edit to the shared object must not pass the stat shortcut.
        try write("broken", object)
        expectThrows(try engine.backup(sources: [source], destination: destination, planID: plan))
        expectThrows(try engine.verify(snapshotID: first.id, destination: destination, planID: plan))
        expectEqual(try String(contentsOf: source.appendingPathComponent("a"), encoding: .utf8), "stable")
    }

    func testLegacyCompletedSnapshotStillRestores() throws {
        let (root, source, destination) = try fixture()
        let plan = UUID()
        try write("legacy", source.appendingPathComponent("a"))
        let snapshot = try engine.backup(sources: [source], destination: destination, planID: plan)
        let folder = try engine.snapshotURL(snapshotID: snapshot.id, destination: destination, planID: plan)
        let files = folder.appendingPathComponent("Files/원본")
        try fm.createDirectory(at: files, withIntermediateDirectories: true)
        try fm.copyItem(at: source.appendingPathComponent("a"), to: files.appendingPathComponent("a"))
        let manifest = folder.appendingPathComponent("manifest.json")
        var entries = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [[String: Any]]
        for i in entries.indices {
            for key in ["storageKey", "objectSignature", "metadataArchive", "createdAt"] { entries[i].removeValue(forKey: key) }
        }
        try JSONSerialization.data(withJSONObject: entries).write(to: manifest)
        try engine.verify(snapshotID: snapshot.id, destination: destination, planID: plan)
        let restored = try engine.restore(snapshotID: snapshot.id, destination: destination, planID: plan, to: root)
        expectEqual(try String(contentsOf: restored.appendingPathComponent("원본/a"), encoding: .utf8), "legacy")
    }

    func testLargeCheckpointCanCancelAndUnchangedResumeDoesNotAppend() throws {
        let (_, source, destination) = try fixture()
        try write("cached", source.appendingPathComponent("a"))
        let plan = UUID()
        let stop = CancelState()
        expectThrows(try engine.backup(sources: [source], destination: destination, planID: plan,
            progress: { if $0.completed == 2 { stop.cancel() } }, cancelled: { stop.cancelled }))
        let partial = try require(engine.incompleteBackups(destination: destination, planID: plan).first)
        let checkpoint = partial.appendingPathComponent("checkpoint.jsonl")
        let rows = try Data(contentsOf: checkpoint)
        var large = Data()
        for _ in 0..<3000 { large.append(rows) }
        try large.write(to: checkpoint)
        let reading = CancelState()
        expectThrows(try engine.backup(sources: [source], destination: destination, planID: plan,
            progress: { if $0.path.hasPrefix("이어받기 기록 확인") { reading.cancel() } }, cancelled: { reading.cancelled }))
        expectEqual(try Data(contentsOf: checkpoint).count, large.count)
        let resumed = try engine.backup(sources: [source], destination: destination, planID: plan)
        expectEqual(resumed.copiedFiles, 0)
        let savedCheckpoint = try engine.snapshotURL(snapshotID: resumed.id, destination: destination, planID: plan).appendingPathComponent("checkpoint.jsonl")
        expectEqual(try Data(contentsOf: savedCheckpoint).count, large.count)
        try engine.verify(snapshotID: resumed.id, destination: destination, planID: plan)
    }

    func testCollisionExclusionsAndSymlinks() throws {
        let (root, source, destination) = try fixture()
        let second = root.appendingPathComponent("Other/원본")
        try fm.createDirectory(at: second, withIntermediateDirectories: true)
        try write("one", source.appendingPathComponent("keep.txt"))
        try write("excluded", source.appendingPathComponent("cache.tmp"))
        try write("two", second.appendingPathComponent("keep.txt"))
        try fm.createSymbolicLink(atPath: source.appendingPathComponent("external-link").path, withDestinationPath: second.path)
        let plan = UUID()
        let snapshot = try engine.backup(sources: [source, second], destination: destination, planID: plan, exclusions: ["*.tmp"])
        let entries = try engine.snapshotFiles(snapshotID: snapshot.id, destination: destination, planID: plan)
        let roots = entries.filter { !$0.path.contains("/") }
        expectEqual(roots.count, 2)
        expectNotEqual(roots[0].path, roots[1].path)
        expectFalse(entries.contains { $0.path.hasSuffix(".tmp") })
        let link = try require(entries.first { $0.kind == .symbolicLink })
        expectEqual(link.linkTarget, second.path)
        expectFalse(entries.contains { $0.path.contains("external-link/") })
        let restored = try engine.restore(snapshotID: snapshot.id, destination: destination, planID: plan, to: root, relativePaths: [link.path])
        expectEqual(try fm.destinationOfSymbolicLink(atPath: restored.appendingPathComponent(link.path).path), second.path)
        expectFalse(fm.fileExists(atPath: restored.appendingPathComponent(roots[1].path + "/keep.txt").path))
    }

    func testRejectsNestedDestinationAndTraversal() throws {
        let (root, source, destination) = try fixture()
        let plan = UUID()
        try write("safe", source.appendingPathComponent("a.txt"))
        expectThrows(try engine.backup(sources: [root], destination: destination, planID: plan))
        expectThrows(try engine.backup(sources: [source, source], destination: destination, planID: plan))
        expectThrows(try engine.backup(sources: [source], destination: root.appendingPathComponent("not-mounted"), planID: plan))
        let snapshot = try engine.backup(sources: [source], destination: destination, planID: plan)
        for id in ["../escape", ".partial-unsafe", "a/b", "id\0hidden"] {
            expectThrows(try engine.snapshotURL(snapshotID: id, destination: destination, planID: plan))
        }
        expectThrows(try engine.restore(snapshotID: snapshot.id, destination: destination, planID: plan, to: root, relativePaths: ["../escape"]))
        let snapshotURL = try engine.snapshotURL(snapshotID: snapshot.id, destination: destination, planID: plan)
        let catalog = snapshotURL.appendingPathComponent("manifest.json")
        let original = try Data(contentsOf: catalog)
        let valid: [String: Any] = ["path": "Root/file", "kind": "file", "bytes": 4, "modifiedAt": 0, "permissions": 420, "checksum": String(repeating: "a", count: 64), "storageKey": String(repeating: "a", count: 64)]
        for path in ["../escape", "/absolute", "Root//file", "Root/./file", "Root/../file", "Root/file\0extra"] {
            var invalid = valid; invalid["path"] = path
            try JSONSerialization.data(withJSONObject: [invalid]).write(to: catalog)
            expectThrows(try engine.snapshotFiles(snapshotID: snapshot.id, destination: destination, planID: plan))
            expectThrows(try engine.restore(snapshotID: snapshot.id, destination: destination, planID: plan, to: root))
        }
        for key in ["../escape", String(repeating: "z", count: 64), String(repeating: "b", count: 64)] {
            var invalid = valid; invalid["storageKey"] = key
            try JSONSerialization.data(withJSONObject: [invalid]).write(to: catalog)
            expectThrows(try engine.snapshotFiles(snapshotID: snapshot.id, destination: destination, planID: plan))
        }
        try JSONSerialization.data(withJSONObject: [valid, valid]).write(to: catalog)
        expectThrows(try engine.snapshotFiles(snapshotID: snapshot.id, destination: destination, planID: plan))
        for target in ["", "target\0extra"] {
            var invalid = valid; invalid["kind"] = "symbolicLink"; invalid["storageKey"] = ""; invalid["linkTarget"] = target
            try JSONSerialization.data(withJSONObject: [invalid]).write(to: catalog)
            expectThrows(try engine.snapshotFiles(snapshotID: snapshot.id, destination: destination, planID: plan))
        }
        try original.write(to: catalog)
        let outside = root.appendingPathComponent("catalog.json")
        try fm.moveItem(at: catalog, to: outside)
        try fm.createSymbolicLink(atPath: catalog.path, withDestinationPath: outside.path)
        expectThrows(try engine.snapshotFiles(snapshotID: snapshot.id, destination: destination, planID: plan))
    }

    func testCancellationPreservesOnlyCompletedSnapshots() throws {
        let (_, source, destination) = try fixture()
        let plan = UUID()
        try write("one", source.appendingPathComponent("a"))
        let snapshot = try engine.backup(sources: [source], destination: destination, planID: plan)
        let state = CancelState()
        expectThrows(try engine.backup(sources: [source], destination: destination, planID: plan,
                                               progress: { if $0.completed > 0 { state.cancel() } }, cancelled: { state.cancelled })) { error in
            guard case BackupError.cancelled = error else { preconditionFailure("Unexpected error: \(error)") }
        }
        expectEqual(try engine.snapshots(destination: destination, planID: plan).map(\.id), [snapshot.id])
        let planRoot = destination.appendingPathComponent("Toolkit Backups/" + plan.uuidString)
        expect(try fm.contentsOfDirectory(atPath: planRoot.path).contains { $0.hasPrefix(".partial-") })
        try engine.verify(snapshotID: snapshot.id, destination: destination, planID: plan)
    }

    func testDetectsSourceMutationAndCorruptedCopy() throws {
        let (root, source, destination) = try fixture()
        let plan = UUID()
        try write("old", source.appendingPathComponent("a"))
        let snapshot = try engine.backup(sources: [source], destination: destination, planID: plan, progress: { progress in
            if progress.completed == 1 { try? Data("modified".utf8).write(to: source.appendingPathComponent("a")) }
        })
        let liveRestore = try engine.restore(snapshotID: snapshot.id, destination: destination, planID: plan, to: root)
        expectEqual(try String(contentsOf: liveRestore.appendingPathComponent("원본/a"), encoding: .utf8), "modified")
        let file = try storedFile(snapshot, "원본/a", destination, plan)
        try write("corrupt", file)
        expectThrows(try engine.verify(snapshotID: snapshot.id, destination: destination, planID: plan))
        expectThrows(try engine.restore(snapshotID: snapshot.id, destination: destination, planID: plan, to: root))
    }

    func testResumeReusesVerifiedFilesAndRecopiesChangedFiles() throws {
        let (root, source, destination) = try fixture()
        let plan = UUID()
        try write("preserved", source.appendingPathComponent("a"))
        try write("later", source.appendingPathComponent("b"))
        let state = CancelState()
        expectThrows(try engine.backup(sources: [source], destination: destination, planID: plan,
            progress: { if $0.completed == 2 { state.cancel() } }, cancelled: { state.cancelled }))
        let partial = try require(engine.incompleteBackups(destination: destination, planID: plan).first)
        let objects = partial.deletingLastPathComponent().appendingPathComponent(".objects")
        let cached = try require(fm.enumerator(at: objects, includingPropertiesForKeys: nil)?.allObjects.compactMap { $0 as? URL }.first { $0.lastPathComponent.count == 64 })
        let inode = try fm.attributesOfItem(atPath: cached.path)[.systemFileNumber] as? NSNumber
        let snapshot = try engine.backup(sources: [source], destination: destination, planID: plan)
        expectEqual(snapshot.resumedFiles, 1)
        let resumed = try storedFile(snapshot, "원본/a", destination, plan)
        expectEqual(try fm.attributesOfItem(atPath: resumed.path)[.systemFileNumber] as? NSNumber, inode)
        let restored = try engine.restore(snapshotID: snapshot.id, destination: destination, planID: plan, to: root)
        expectEqual(try String(contentsOf: restored.appendingPathComponent("원본/b"), encoding: .utf8), "later")

        let changedPlan = UUID()
        let stop = CancelState()
        expectThrows(try engine.backup(sources: [source], destination: destination, planID: changedPlan,
            progress: { if $0.completed == 2 { stop.cancel() } }, cancelled: { stop.cancelled }))
        try write("new source", source.appendingPathComponent("a"))
        let fresh = try engine.backup(sources: [source], destination: destination, planID: changedPlan)
        expectEqual(fresh.resumedFiles, 0)
        let freshRestore = try engine.restore(snapshotID: fresh.id, destination: destination, planID: changedPlan, to: root)
        expectEqual(try String(contentsOf: freshRestore.appendingPathComponent("원본/a"), encoding: .utf8), "new source")
    }

    func testLegacyPartialAndDirectoryChangesDoNotInvalidateBackup() throws {
        let (root, source, destination) = try fixture()
        let plan = UUID()
        try write("cached", source.appendingPathComponent("a"))
        try write("initial", source.appendingPathComponent(".DS_Store"))
        let legacy = destination.appendingPathComponent("Toolkit Backups/" + plan.uuidString + "/.partial-legacy/Files/원본")
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try fm.copyItem(at: source.appendingPathComponent("a"), to: legacy.appendingPathComponent("a"))
        let snapshot = try engine.backup(sources: [source], destination: destination, planID: plan, progress: { progress in
            if progress.total > 0 && progress.completed == 1 {
                try? Data("changed during run".utf8).write(to: source.appendingPathComponent(".DS_Store"))
                try? Data("created after scan".utf8).write(to: source.appendingPathComponent("new-file"))
            }
        })
        expectEqual(snapshot.resumedFiles, 1)
        let restored = try engine.restore(snapshotID: snapshot.id, destination: destination, planID: plan, to: root)
        expectEqual(try String(contentsOf: restored.appendingPathComponent("원본/.DS_Store"), encoding: .utf8), "changed during run")
        try engine.verify(snapshotID: snapshot.id, destination: destination, planID: plan)
    }

    func testRetentionOnlySelectsOldCompletedVersions() throws {
        let (_, source, destination) = try fixture()
        let plan = UUID()
        try write("first", source.appendingPathComponent("a"))
        let first = try engine.backup(sources: [source], destination: destination, planID: plan)
        try write("second", source.appendingPathComponent("a"))
        let second = try engine.backup(sources: [source], destination: destination, planID: plan)
        expectEqual(try engine.snapshotsToPrune(destination: destination, planID: plan, keeping: 1).map(\.id), [first.id])
        expect(try engine.snapshotsToPrune(destination: destination, planID: plan, keeping: 2).isEmpty)
        expectThrows(try engine.snapshotsToPrune(destination: destination, planID: plan, keeping: 0))
        let stop = CancelState()
        expectThrows(try engine.backup(sources: [source], destination: destination, planID: plan, progress: { _ in stop.cancel() }, cancelled: { stop.cancelled }))
        expectEqual(try engine.snapshots(destination: destination, planID: plan).first?.id, second.id)
        expectEqual(BackupRetention(mode: .latest).limit, 1)
        expectEqual(BackupRetention(mode: .recent, count: 3).limit, 3)
        expectEqual(BackupRetention().limit, nil)
    }

    func testMutationDuringCopyRetriesWithoutLosingOtherFiles() throws {
        let (root, source, destination) = try fixture()
        let plan = UUID()
        let file = source.appendingPathComponent("active.bin")
        try Data(repeating: 65, count: 3 * 1024 * 1024).write(to: file)
        try write("other file", source.appendingPathComponent("z.txt"))
        let mutated = CancelState()
        let retried = CancelState()
        let snapshot = try engine.backup(sources: [source], destination: destination, planID: plan,
            progress: { if $0.retries > 0 { retried.cancel() } }, cancelled: {
                if !mutated.cancelled,
                   let partial = try? self.engine.incompleteBackups(destination: destination, planID: plan).first,
                   !(try? self.fm.contentsOfDirectory(atPath: partial.appendingPathComponent("Work").path))!.isEmpty {
                    mutated.cancel()
                    try? Data(repeating: 66, count: 3 * 1024 * 1024).write(to: file)
                }
                return false
            })
        expect(mutated.cancelled)
        expect(retried.cancelled)
        let restored = try engine.restore(snapshotID: snapshot.id, destination: destination, planID: plan, to: root)
        expectEqual(try Data(contentsOf: restored.appendingPathComponent("원본/active.bin")), Data(repeating: 66, count: 3 * 1024 * 1024))
        expectEqual(try String(contentsOf: restored.appendingPathComponent("원본/z.txt"), encoding: .utf8), "other file")
    }

    func testUnreadableFilePreservesOtherProgressForResume() throws {
        let (_, source, destination) = try fixture()
        let plan = UUID()
        let blocked = source.appendingPathComponent("a-blocked")
        try write("blocked contents", blocked)
        try write("safe contents", source.appendingPathComponent("b-safe"))
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
        expectThrows(try engine.backup(sources: [source], destination: destination, planID: plan)) { error in
            guard case BackupError.incomplete(let failures) = error, failures.count == 1 else { preconditionFailure("Expected one deferred failure: \(error)") }
            expect(failures[0].contains("a-blocked") && failures[0].contains(L10n.text("Processing backup item")))
        }
        expect(try engine.snapshots(destination: destination, planID: plan).isEmpty)
        let partial = try require(engine.incompleteBackups(destination: destination, planID: plan).first)
        expect(fm.fileExists(atPath: partial.deletingLastPathComponent().appendingPathComponent(".objects").path))
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: blocked.path)
        let completed = try engine.backup(sources: [source], destination: destination, planID: plan)
        expectEqual(completed.resumedFiles, 1)
        expectEqual(completed.files, 2)
        try engine.verify(snapshotID: completed.id, destination: destination, planID: plan)
    }

    func testRuntimeEndpointsAndVanishedSourcesDoNotBlockCompletion() throws {
        let root = URL(fileURLWithPath: "/tmp/ft-" + UUID().uuidString)
        let source = root.appendingPathComponent("Source")
        let destination = root.appendingPathComponent("Backup")
        let gone = source.appendingPathComponent("gone")
        try fm.createDirectory(at: gone, withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        try write("temporary build", gone.appendingPathComponent("build.o"))
        try write("keep this file", source.appendingPathComponent("kept.txt"))
        expectEqual(mkfifo(source.appendingPathComponent("runtime.pipe").path, 0o600), 0)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        expect(descriptor >= 0)
        defer { close(descriptor) }
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(source.appendingPathComponent("runtime.sock").path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        expectEqual(bound, 0)
        let moved = CancelState()
        let plan = UUID()
        let first = try engine.backup(sources: [source], destination: destination, planID: plan, progress: {
            if $0.completed == 1 && !moved.cancelled {
                moved.cancel()
                try? self.fm.moveItem(at: gone, to: root.appendingPathComponent("moved-out"))
            }
        })
        expect(moved.cancelled)
        expectEqual(first.files, 1)
        expectEqual(first.skippedItems?.count, 4)
        let entries = try engine.snapshotFiles(snapshotID: first.id, destination: destination, planID: plan)
        expectEqual(entries.map(\.path).sorted(), ["Source", "Source/kept.txt"])
        let cancelListing = CancelState()
        expectThrows(try engine.snapshotFiles(snapshotID: first.id, destination: destination, planID: plan,
            cancelled: { cancelListing.cancelAfterChecks(3) })) { error in
                guard case BackupError.cancelled = error else { preconditionFailure("Listing did not cancel: \(error)") }
            }
        let restored = try engine.restore(snapshotID: first.id, destination: destination, planID: plan, to: root)
        expectEqual(try String(contentsOf: restored.appendingPathComponent("Source/kept.txt"), encoding: .utf8), "keep this file")
        let second = try engine.backup(sources: [source], destination: destination, planID: plan)
        expectEqual(second.copiedFiles, 0)
        expectEqual(second.skippedItems?.count, 2)
        try engine.verify(snapshotID: second.id, destination: destination, planID: plan)
    }

    func testPackedMigrationIncrementalRestoreRetentionAndCorruption() throws {
        let (root, source, destination) = try fixture()
        let plan = UUID()
        for (name, value) in [("a", "first"), ("duplicate", "first"), ("deleted", "retained"), ("empty", ""), ("attribute", "metadata")] {
            try write(value, source.appendingPathComponent(name))
        }
        let attribute = source.appendingPathComponent("attribute")
        let value = Data("preserved attribute".utf8)
        expectEqual(value.withUnsafeBytes { setxattr(attribute.path, "com.folderbackup.packed-check", $0.baseAddress, value.count, 0, 0) }, 0)
        try fm.setAttributes([.posixPermissions: 0o640], ofItemAtPath: attribute.path)
        try Data(repeating: 42, count: 2 * 1024 * 1024).write(to: source.appendingPathComponent("large"))
        let first = try engine.backup(sources: [source], destination: destination, planID: plan)
        let original = try storedFile(first, "원본/a", destination, plan)
        expectEqual(try engine.compactStorage(destination: destination, planID: plan), 4)
        expectFalse(fm.fileExists(atPath: original.path))
        expectEqual(try engine.compactStorage(destination: destination, planID: plan), 0)
        try engine.verify(snapshotID: first.id, destination: destination, planID: plan)
        let restored = try engine.restore(snapshotID: first.id, destination: destination, planID: plan, to: root)
        expectEqual(try String(contentsOf: restored.appendingPathComponent("원본/deleted"), encoding: .utf8), "retained")
        expectEqual(try Data(contentsOf: restored.appendingPathComponent("원본/empty")).count, 0)
        var buffer = [UInt8](repeating: 0, count: 128)
        let count = getxattr(restored.appendingPathComponent("원본/attribute").path, "com.folderbackup.packed-check", &buffer, buffer.count, 0, 0)
        expectEqual(Data(buffer.prefix(count)), value)
        expectEqual(try fm.attributesOfItem(atPath: restored.appendingPathComponent("원본/attribute").path)[.posixPermissions] as? NSNumber, NSNumber(value: 0o640))
        try write("second", source.appendingPathComponent("a"))
        try write("new", source.appendingPathComponent("b"))
        try fm.moveItem(at: source.appendingPathComponent("deleted"), to: root.appendingPathComponent("removed-original"))
        let second = try engine.backup(sources: [source], destination: destination, planID: plan)
        expectEqual(second.copiedFiles, 2)
        expectEqual(second.copiedBytes, 9)
        let cancel = CancelState()
        expectThrows(try engine.backup(sources: [source], destination: destination, planID: plan,
            progress: { if $0.completed == 2 { cancel.cancel() } }, cancelled: { cancel.cancelled }))
        expectThrows(try engine.compactStorage(destination: destination, planID: plan))
        let third = try engine.backup(sources: [source], destination: destination, planID: plan)
        expectEqual(third.copiedFiles, 0)
        expectEqual(third.copiedBytes, 0)
        expectEqual(try engine.prune(destination: destination, planID: plan, keeping: 1), 2)
        try engine.verify(snapshotID: third.id, destination: destination, planID: plan)
        let recent = try engine.restore(snapshotID: third.id, destination: destination, planID: plan, to: root)
        expectFalse(fm.fileExists(atPath: recent.appendingPathComponent("원본/deleted").path))
        expectEqual(try String(contentsOf: recent.appendingPathComponent("원본/a"), encoding: .utf8), "second")
        let key = try require(engine.snapshotFiles(snapshotID: third.id, destination: destination, planID: plan).first { $0.path == "원본/a" }?.storageKey)
        let dbURL = try engine.snapshotURL(snapshotID: third.id, destination: destination, planID: plan).deletingLastPathComponent().appendingPathComponent(".objects.sqlite")
        var db: OpaquePointer?
        expectEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        expectEqual(sqlite3_exec(db, "UPDATE objects SET data=X'62726f6b656e' WHERE hash='" + key + "'", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        expectThrows(try engine.verify(snapshotID: third.id, destination: destination, planID: plan))
        expectThrows(try engine.backup(sources: [source], destination: destination, planID: plan))
    }

    func testFailedCompactionKeepsOriginalObjects() throws {
        let (_, source, destination) = try fixture()
        let plan = UUID()
        try write("safe", source.appendingPathComponent("a"))
        try write("other", source.appendingPathComponent("b"))
        let snapshot = try engine.backup(sources: [source], destination: destination, planID: plan)
        let a = try storedFile(snapshot, "원본/a", destination, plan)
        let b = try storedFile(snapshot, "원본/b", destination, plan)
        try write("broken", b)
        expectThrows(try engine.compactStorage(destination: destination, planID: plan))
        expect(fm.fileExists(atPath: a.path))
        expect(fm.fileExists(atPath: b.path))
        expectEqual(try String(contentsOf: a, encoding: .utf8), "safe")
    }

    func testExtendedAttributesAndPermissionsSurviveIncrementalBackup() throws {
        let (root, source, destination) = try fixture()
        let file = source.appendingPathComponent("metadata.txt")
        try write("unchanged contents", file)
        func setAttribute(_ value: String, at url: URL) {
            let data = Data(value.utf8)
            let status = data.withUnsafeBytes { setxattr(url.path, "com.folderbackup.backup-check", $0.baseAddress, data.count, 0, 0) }
            expectEqual(status, 0)
        }
        func attribute(at url: URL) -> String {
            var bytes = [UInt8](repeating: 0, count: 128)
            let count = getxattr(url.path, "com.folderbackup.backup-check", &bytes, bytes.count, 0, 0)
            precondition(count >= 0)
            return String(decoding: bytes.prefix(count), as: UTF8.self)
        }
        setAttribute("first attribute", at: file)
        setAttribute("folder attribute", at: source)
        try fm.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        let plan = UUID()
        let first = try engine.backup(sources: [source], destination: destination, planID: plan)
        setAttribute("second attribute", at: file)
        let second = try engine.backup(sources: [source], destination: destination, planID: plan)
        let oldFile = try storedFile(first, "원본/metadata.txt", destination, plan)
        let newFile = try storedFile(second, "원본/metadata.txt", destination, plan)
        expectEqual(oldFile, newFile)
        expectEqual(second.copiedFiles, 0)
        let newerRestore = try engine.restore(snapshotID: second.id, destination: destination, planID: plan, to: root)
        expectEqual(attribute(at: newerRestore.appendingPathComponent("원본/metadata.txt")), "second attribute")
        let restored = try engine.restore(snapshotID: first.id, destination: destination, planID: plan, to: root)
        expectEqual(attribute(at: restored.appendingPathComponent("원본/metadata.txt")), "first attribute")
        expectEqual(attribute(at: restored.appendingPathComponent("원본")), "folder attribute")
        expectEqual(try fm.attributesOfItem(atPath: restored.appendingPathComponent("원본/metadata.txt").path)[.posixPermissions] as? NSNumber, NSNumber(value: 0o640))
    }
}

private final class CancelState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    private var checks = 0
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
    func cancelAfterChecks(_ count: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        checks += 1
        return checks >= count
    }
}


private func expect(_ value: @autoclosure () throws -> Bool, file: StaticString = #file, line: UInt = #line) {
    do { let result = try value(); precondition(result, "Expectation failed", file: file, line: line) }
    catch { preconditionFailure("Unexpected error: \(error)", file: file, line: line) }
}
private func expectFalse(_ value: @autoclosure () throws -> Bool, file: StaticString = #file, line: UInt = #line) {
    do { let result = try value(); precondition(!result, "Expected false", file: file, line: line) }
    catch { preconditionFailure("Unexpected error: \(error)", file: file, line: line) }
}
private func expectEqual<T: Equatable>(_ first: @autoclosure () throws -> T, _ second: @autoclosure () throws -> T, file: StaticString = #file, line: UInt = #line) {
    do {
        let lhs = try first(), rhs = try second()
        precondition(lhs == rhs, "Expected \(lhs) == \(rhs)", file: file, line: line)
    } catch { preconditionFailure("Unexpected error: \(error)", file: file, line: line) }
}
private func expectNotEqual<T: Equatable>(_ first: T, _ second: T, file: StaticString = #file, line: UInt = #line) {
    precondition(first != second, "Expected unequal values", file: file, line: line)
}
private func expectThrows<T>(_ operation: @autoclosure () throws -> T, check: (Error) -> Void = { _ in }, file: StaticString = #file, line: UInt = #line) {
    do { _ = try operation(); preconditionFailure("Expected an error", file: file, line: line) }
    catch { check(error) }
}
private func require<T>(_ value: T?) throws -> T {
    guard let value else { throw NSError(domain: "BackupCoreChecks", code: 1) }
    return value
}

let checks = BackupEngineTests()
try checks.testVersionedBackupRestoreAndIndependentIncrementalFiles()
try checks.testIncrementalStorageAndCheckpointDoNotMultiplyCopies()
try checks.testLegacyCompletedSnapshotStillRestores()
try checks.testLargeCheckpointCanCancelAndUnchangedResumeDoesNotAppend()
try checks.testCollisionExclusionsAndSymlinks()
try checks.testRejectsNestedDestinationAndTraversal()
try checks.testCancellationPreservesOnlyCompletedSnapshots()
try checks.testDetectsSourceMutationAndCorruptedCopy()
try checks.testExtendedAttributesAndPermissionsSurviveIncrementalBackup()
try checks.testResumeReusesVerifiedFilesAndRecopiesChangedFiles()
try checks.testLegacyPartialAndDirectoryChangesDoNotInvalidateBackup()
try checks.testRetentionOnlySelectsOldCompletedVersions()
try checks.testMutationDuringCopyRetriesWithoutLosingOtherFiles()
try checks.testUnreadableFilePreservesOtherProgressForResume()
try checks.testRuntimeEndpointsAndVanishedSourcesDoNotBlockCompletion()
try checks.testPackedMigrationIncrementalRestoreRetentionAndCorruption()
try checks.testFailedCompactionKeepsOriginalObjects()
print("BackupCoreChecks: 17 workflows passed (shared incremental bytes, large checkpoint cancellation/no-growth, checkpoint resume, corrupt object, legacy restore, metadata, retry, retention, socket/FIFO and vanished source handling)")
