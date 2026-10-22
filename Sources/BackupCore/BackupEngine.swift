import Foundation
import CryptoKit
import Darwin

public struct BackupSnapshot: Codable, Sendable, Identifiable {
    public let id: String
    public let createdAt: Date
    public let files: Int
    public let bytes: Int64
    public let resumedFiles: Int?
    public var copiedFiles: Int? = nil
    public var copiedBytes: Int64? = nil
    public var skippedItems: [String]? = nil
}

public struct BackupProgress: Sendable {
    public let completed: Int
    public let total: Int
    public let path: String
    public let resumedFiles: Int
    public let retries: Int
    public var copiedFiles: Int = 0
    public var copiedBytes: Int64 = 0
    public var skippedFiles: Int = 0
}

public struct BackupRetention: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Identifiable, Sendable {
        case all, latest, recent
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .all: return L10n.text("Keep All Versions")
            case .latest: return L10n.text("Keep Latest Only")
            case .recent: return L10n.text("Keep Recent Versions")
            }
        }
    }
    public var mode: Mode
    public var count: Int
    public init(mode: Mode = .all, count: Int = 5) { self.mode = mode; self.count = count }
    public var limit: Int? { mode == .all ? nil : mode == .latest ? 1 : max(1, count) }
    public var title: String { mode == .recent ? L10n.text("Versions to keep: %@", max(1, count)) : mode.title }
}

public struct BackupFileEntry: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable { case file, directory, symbolicLink }
    public var id: String { path }
    public let path: String
    public let kind: Kind
    public let bytes: Int64
    public let modifiedAt: Date
    public let checksum: String?
    public let linkTarget: String?
    public let permissions: UInt16
    public let metadataSignature: String?
    public var objectSignature: String? = nil
    public var storageKey: String? = nil
    public var metadataArchive: Data? = nil
    public var createdAt: Date? = nil
}

public enum BackupError: LocalizedError {
    case invalid(String), changed(String), corrupted(String), incomplete([String]), cancelled, busy
    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .changed(let path): return L10n.text("The source changed while being copied: %@", path)
        case .incomplete(let paths): return L10n.text("Items not backed up: %@. Copied files are safe. Review the details, then resume the backup.", paths.count.formatted(.number.locale(L10n.locale)))
        case .corrupted(let path): return L10n.text("Backup verification failed: %@", path)
        case .cancelled: return L10n.text("Backup stopped. Copied files are safe and will be reused next time.")
        case .busy: return L10n.text("This backup is already running.")
        }
    }
}

public final class BackupEngine: Sendable {
    private var manager: FileManager { FileManager.default }
    public init() {}

    public func backup(sources: [URL], destination: URL, planID: UUID, exclusions: [String] = [],
                       progress: @escaping @Sendable (BackupProgress) -> Void = { _ in },
                       cancelled: @escaping @Sendable () -> Bool = { false }) throws -> BackupSnapshot {
        let destination = try existingDirectory(destination)
        guard !sources.isEmpty else { throw BackupError.invalid(L10n.text("Choose a folder to back up.")) }
        let sources = try sources.map { try existingDirectory($0) }
        for source in sources {
            if source.path == "/" { throw BackupError.invalid(L10n.text("Choose specific folders rather than an entire disk.")) }
            if overlaps(source, destination) { throw BackupError.invalid(L10n.text("The source and backup destination cannot be inside one another.")) }
        }
        for (index, source) in sources.enumerated() {
            if sources.dropFirst(index + 1).contains(where: { overlaps(source, $0) }) {
                throw BackupError.invalid(L10n.text("Source folders cannot overlap or contain one another."))
            }
        }
        let root = try planRoot(destination, planID, create: true)
        let handle = try acquireLock(root)
        defer { _ = flock(handle.fileDescriptor, LOCK_UN); try? handle.close() }
        var filesystem = statfs()
        guard statfs(root.path, &filesystem) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let packed = try PackedObjects.open(at: root, create: filesystem.f_bsize > 4096 || manager.fileExists(atPath: root.appendingPathComponent(PackedObjects.filename).path))
        defer { try? packed?.flush() }
        let previous = try snapshots(destination: destination, planID: planID).first
        let previousEntries = try previous.map { try snapshotFiles(snapshotID: $0.id, destination: destination, planID: planID, cancelled: cancelled) } ?? []
        var previousByPath = Dictionary(uniqueKeysWithValues: previousEntries.map { ($0.path, $0) })
        let partials = try incompleteBackups(destination: destination, planID: planID)
        let objects = root.appendingPathComponent(".objects", isDirectory: true)
        try rejectSymlink(objects)
        try manager.createDirectory(at: objects, withIntermediateDirectories: true)
        var pending: [(URL, String)] = []
        var sourceLocations: [String: String] = [:]
        let counts = Dictionary(grouping: sources, by: { $0.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased() }).mapValues(\.count)
        progress(BackupProgress(completed: 0, total: 0, path: L10n.text("Scanning folders · Preparing to resume interrupted backups: %@", partials.count), resumedFiles: 0, retries: 0))
        var scanFailures: [String] = []
        var skipped: [String] = []
        func collect(_ url: URL, _ path: String) throws {
            try autoreleasepool {
                if cancelled() { throw BackupError.cancelled }
                if Self.isExcluded(path, patterns: exclusions) { return }
                let attributes: [FileAttributeKey: Any]
                do { attributes = try manager.attributesOfItem(atPath: url.path) }
                catch {
                    if sourceDisappeared(error, at: url) { skipped.append(L10n.text("Removed from source · ") + path); return }
                    scanFailures.append(path + ": " + error.localizedDescription); return
                }
                if attributes[.type] as? FileAttributeType == .typeSocket {
                    skipped.append(L10n.text("Runtime socket · ") + path); return
                }
                if attributes[.type] as? FileAttributeType == .typeUnknown {
                    var info = stat()
                    if lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFIFO {
                        skipped.append(L10n.text("Runtime pipe · ") + path); return
                    }
                }
                pending.append((url, path))
                if pending.count % 500 == 0 {
                    progress(BackupProgress(completed: 0, total: 0, path: L10n.text("Scanning source · Items: %@", pending.count.formatted(.number.locale(L10n.locale))), resumedFiles: 0, retries: 0))
                }
                if attributes[.type] as? FileAttributeType == .typeDirectory {
                    let children: [URL]
                    do { children = try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) }
                    catch {
                        if !sourceDisappeared(error, at: url) { scanFailures.append(path + ": " + error.localizedDescription) }
                        return
                    }
                    for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) { try collect(child, path + "/" + child.lastPathComponent) }
                }
            }
        }
        for source in sources.sorted(by: { $0.path < $1.path }) {
            var label = source.lastPathComponent
            if counts[label.precomposedStringWithCanonicalMapping.lowercased(), default: 0] > 1 { label += "-" + String(SHA256.hash(data: Data(source.path.utf8)).description.suffix(8)) }
            guard !label.isEmpty else { throw BackupError.invalid(L10n.text("Choose specific folders rather than an entire disk.")) }
            sourceLocations[label] = source.path
            try collect(source, label)
        }
        guard !pending.isEmpty else { throw BackupError.invalid(L10n.text("No files remain after applying exclusions.")) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let id = formatter.string(from: Date()) + "-" + UUID().uuidString
        let staging = root.appendingPathComponent(".partial-current", isDirectory: true)
        let work = staging.appendingPathComponent("Work", isDirectory: true)
        for url in [staging, work] {
            try rejectSymlink(url)
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try JSONEncoder().encode(sourceLocations).write(to: staging.appendingPathComponent("sources.json"), options: .atomic)
        let checkpointURL = staging.appendingPathComponent("checkpoint.jsonl")
        try rejectSymlink(checkpointURL)
        if let data = try? Data(contentsOf: checkpointURL) {
            let decoder = JSONDecoder()
            for (index, line) in [UInt8](data).split(separator: 10).enumerated() {
                if cancelled() { throw BackupError.cancelled }
                if let entry = autoreleasepool(invoking: { try? decoder.decode(BackupFileEntry.self, from: Data(line)) }) {
                    previousByPath[entry.path] = entry
                }
                if index % 1000 == 0 {
                    progress(BackupProgress(completed: 0, total: 0, path: L10n.text("Checking resume records · %@", index.formatted(.number.locale(L10n.locale))), resumedFiles: 0, retries: 0))
                }
            }
        }
        if !manager.fileExists(atPath: checkpointURL.path) { manager.createFile(atPath: checkpointURL.path, contents: nil) }
        let checkpoint = try FileHandle(forWritingTo: checkpointURL)
        defer { try? checkpoint.close() }
        try checkpoint.seekToEnd()
        var entries: [String: BackupFileEntry] = [:]
        var resumed = 0
        var retries = 0
        var copiedFiles = 0
        var copiedBytes: Int64 = 0
        var vanished = 0

        func report(_ path: String) {
            progress(BackupProgress(completed: entries.count + vanished, total: pending.count, path: path, resumedFiles: resumed, retries: retries, copiedFiles: copiedFiles, copiedBytes: copiedBytes, skippedFiles: skipped.count))
        }
        func copyEntry(_ source: URL, _ path: String) throws -> (BackupFileEntry, Bool) {
            if cancelled() { throw BackupError.cancelled }
            let before = try manager.attributesOfItem(atPath: source.path)
            let metadata = try changeTime(source)
            let type = before[.type] as? FileAttributeType
            let modified = before[.modificationDate] as? Date ?? .distantPast
            let permissions = (before[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
            var checksum: String?
            var linkTarget: String?
            var bytes: Int64 = 0
            var reused = false
            var archive: Data?
            var packedEntry = false
            let kind: BackupFileEntry.Kind
            switch type {
            case .typeDirectory:
                kind = .directory
                archive = try packMetadata(source)
            case .typeSymbolicLink:
                kind = .symbolicLink
                linkTarget = try manager.destinationOfSymbolicLink(atPath: source.path)
            case .typeRegular:
                kind = .file
                bytes = (before[.size] as? NSNumber)?.int64Value ?? 0
                // ctime plus device/inode catches replaced files and edits with restored mtime.
                if let old = previousByPath[path], old.kind == .file, old.storageKey != nil,
                   old.bytes == bytes, old.modifiedAt == modified, old.permissions == permissions,
                   old.metadataSignature == metadata {
                    if let data = try packed?.read(old.storageKey!) {
                        guard data.count == bytes, sameFile(before, try manager.attributesOfItem(atPath: source.path)),
                              metadata == (try changeTime(source)) else { throw BackupError.changed(source.path) }
                        return (old, true)
                    }
                    let object = try objectURL(root: root, key: old.storageKey!)
                    if let cached = try? manager.attributesOfItem(atPath: object.path),
                       cached[.type] as? FileAttributeType == .typeRegular,
                       (cached[.size] as? NSNumber)?.int64Value == bytes,
                       old.objectSignature == (try changeTime(object)) {
                        guard sameFile(before, try manager.attributesOfItem(atPath: source.path)),
                              metadata == (try changeTime(source)) else { throw BackupError.changed(source.path) }
                        return (old, true)
                    }
                }
                if let packed, bytes <= PackedObjects.maximumBytes {
                    let data = try Data(contentsOf: source)
                    guard data.count == bytes else { throw BackupError.changed(source.path) }
                    checksum = String(SHA256.hash(data: data).description.suffix(64))
                    reused = try !packed.put(data, key: checksum!)
                    packedEntry = true
                    if !reused { copiedFiles += 1; copiedBytes += bytes }
                } else {
                    checksum = try hash(source, cancelled: cancelled)
                    let target = try objectURL(root: root, key: checksum!)
                    try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if let cached = try? manager.attributesOfItem(atPath: target.path) {
                        guard cached[.type] as? FileAttributeType == .typeRegular,
                              (cached[.size] as? NSNumber)?.int64Value == bytes,
                              try hash(target, cancelled: cancelled) == checksum else { throw BackupError.corrupted(path) }
                        reused = true
                    } else {
                        var cachedSource: URL?
                        for partial in partials {
                            let candidate = try safeChild(partial.appendingPathComponent("Files"), path)
                            guard let attributes = try? manager.attributesOfItem(atPath: candidate.path),
                                  attributes[.type] as? FileAttributeType == .typeRegular,
                                  (attributes[.size] as? NSNumber)?.int64Value == bytes else { continue }
                            if try hash(candidate, cancelled: cancelled) == checksum { cachedSource = candidate; break }
                        }
                        if let cachedSource {
                            // Adopt verified legacy copies on the same volume without duplicating their data.
                            try manager.moveItem(at: cachedSource, to: target)
                            reused = true
                        } else {
                            let attempt = work.appendingPathComponent(UUID().uuidString)
                            try copyData(source, to: attempt, cancelled: cancelled)
                            guard try hash(attempt, cancelled: cancelled) == checksum else {
                                if try !sameFile(before, manager.attributesOfItem(atPath: source.path)) || metadata != changeTime(source) {
                                    throw BackupError.changed(source.path)
                                }
                                throw BackupError.corrupted(path)
                            }
                            try manager.moveItem(at: attempt, to: target)
                            copiedFiles += 1
                            copiedBytes += bytes
                        }
                    }
                }
                archive = try packMetadata(source)
            default: throw BackupError.invalid(L10n.text("This file type cannot be backed up: %@", source.path))
            }
            if kind != .directory {
                guard sameFile(before, try manager.attributesOfItem(atPath: source.path)), metadata == (try changeTime(source)) else {
                    throw BackupError.changed(source.path)
                }
            }
            var entry = BackupFileEntry(path: path, kind: kind, bytes: bytes, modifiedAt: modified, checksum: checksum,
                                        linkTarget: linkTarget, permissions: permissions, metadataSignature: metadata)
            entry.storageKey = checksum ?? ""
            if let checksum, !packedEntry { entry.objectSignature = try changeTime(objectURL(root: root, key: checksum)) }
            entry.metadataArchive = archive
            entry.createdAt = before[.creationDate] as? Date
            return (entry, reused)
        }
        var deferred: [(URL, String)] = []
        var failures: [String] = scanFailures
        func attempt(_ item: (URL, String)) throws -> Bool {
            for number in 0..<3 {
                do {
                    return try autoreleasepool {
                        let (entry, reused) = try copyEntry(item.0, item.1)
                        if previousByPath[entry.path] != entry {
                            var line = try JSONEncoder().encode(entry)
                            line.append(10)
                            do { try checkpoint.write(contentsOf: line) }
                            catch { throw ioError(error, operation: L10n.text("Saving resume records"), path: checkpointURL) }
                            previousByPath[entry.path] = entry
                        }
                        entries[item.1] = entry
                        if reused { resumed += 1 }
                        report(item.1)
                        return true
                    }
                } catch BackupError.changed {
                    retries += 1
                    report(L10n.text("Retrying changed file %@/3 · ", number + 1) + item.1)
                } catch BackupError.cancelled { throw BackupError.cancelled }
                  catch { throw ioError(error, operation: L10n.text("Processing backup item"), path: item.0) }
            }
            return false
        }
        for item in pending {
            do {
                if try !attempt(item) { deferred.append(item) }
            } catch {
                if cancelled() { throw BackupError.cancelled }
                if isFatalStorageError(error) { throw error }
                guard manager.fileExists(atPath: root.path) else {
                    throw BackupError.invalid(L10n.text("The selected drive is not connected: %@", destination.path))
                }
                if sourceDisappeared(error, at: item.0) {
                    skipped.append(L10n.text("Removed from source during backup · ") + item.1)
                    vanished += 1
                    report(item.1)
                    continue
                }
                failures.append(item.1 + ": " + error.localizedDescription)
                report(L10n.text("Continuing with other files · ") + item.1)
            }
        }
        for item in deferred {
            do { if try !attempt(item) { failures.append(item.1 + L10n.text(": could not copy because the file kept changing.")) } }
            catch {
                if cancelled() { throw BackupError.cancelled }
                if isFatalStorageError(error) { throw error }
                guard manager.fileExists(atPath: root.path) else {
                    throw BackupError.invalid(L10n.text("The selected drive is not connected: %@", destination.path))
                }
                if sourceDisappeared(error, at: item.0) {
                    skipped.append(L10n.text("Removed from source · ") + item.1); vanished += 1; report(item.1)
                } else { failures.append(item.1 + ": " + error.localizedDescription) }
            }
        }
        if cancelled() { throw BackupError.cancelled }
        guard failures.isEmpty else { throw BackupError.incomplete(failures) }
        try packed?.flush()
        let manifest = pending.compactMap { entries[$0.1] }
        var snapshot = BackupSnapshot(id: id, createdAt: Date(), files: manifest.filter { $0.kind != .directory }.count, bytes: manifest.reduce(0) { $0 + $1.bytes }, resumedFiles: resumed)
        snapshot.copiedFiles = copiedFiles
        snapshot.copiedBytes = copiedBytes
        snapshot.skippedItems = skipped.isEmpty ? nil : skipped
        try checkpoint.synchronize()
        try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        try JSONEncoder().encode(snapshot).write(to: staging.appendingPathComponent("snapshot.json"), options: .atomic)
        try manager.moveItem(at: staging, to: root.appendingPathComponent(id, isDirectory: true))
        return snapshot
    }

    public func compactStorage(destination: URL, planID: UUID,
                               progress: @escaping @Sendable (BackupProgress) -> Void = { _ in }) throws -> Int {
        let root = try planRoot(try existingDirectory(destination), planID, create: false)
        let handle = try acquireLock(root)
        defer { _ = flock(handle.fileDescriptor, LOCK_UN); try? handle.close() }
        guard try incompleteBackups(destination: destination, planID: planID).isEmpty else {
            throw BackupError.invalid(L10n.text("Finish or resume the incomplete backup before optimizing storage."))
        }
        var references: [String: Int64] = [:]
        for snapshot in try snapshots(destination: destination, planID: planID) {
            progress(BackupProgress(completed: 0, total: 0, path: L10n.text("Checking saved backup · ") + snapshot.id, resumedFiles: 0, retries: 0))
            try autoreleasepool {
                let folder = try snapshotURL(snapshotID: snapshot.id, destination: destination, planID: planID)
                let catalog = folder.appendingPathComponent("manifest.json")
                try rejectSymlink(catalog)
                let entries = try JSONDecoder().decode([BackupFileEntry].self, from: Data(contentsOf: catalog))
                var paths = Set<String>()
                var files = 0
                var bytes: Int64 = 0
                for entry in entries {
                    let parts = entry.path.split(separator: "/", omittingEmptySubsequences: false)
                    guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                          paths.insert(entry.path).inserted, entry.bytes >= 0 else { throw BackupError.corrupted(entry.path) }
                    if entry.kind != .directory { files += 1 }
                    bytes += entry.bytes
                    if entry.kind == .file, let key = entry.storageKey {
                        guard key.utf8.count == 64, key.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                              key == entry.checksum, references[key] == nil || references[key] == entry.bytes else { throw BackupError.corrupted(entry.path) }
                        references[key] = entry.bytes
                    } else if entry.kind != .file, entry.storageKey?.isEmpty == false { throw BackupError.corrupted(entry.path) }
                }
                guard files == snapshot.files, bytes == snapshot.bytes else { throw BackupError.corrupted(snapshot.id) }
            }
        }
        guard !references.isEmpty else { return 0 }
        let packed = try PackedObjects.open(at: root, create: true)!
        var originals: [(String, URL, stat)] = []
        let keys = references.keys.sorted()
        for (index, key) in keys.enumerated() {
            try autoreleasepool {
                let size = references[key]!
                let file = try objectURL(root: root, key: key)
                var attributes = stat()
                if lstat(file.path, &attributes) == 0 {
                    guard attributes.st_mode & S_IFMT == S_IFREG, attributes.st_size == size else { throw BackupError.corrupted(key) }
                    if size <= PackedObjects.maximumBytes {
                        let data = try Data(contentsOf: file)
                        _ = try packed.put(data, key: key)
                        originals.append((key, file, attributes))
                    }
                } else {
                    guard errno == ENOENT, let data = try packed.read(key), Int64(data.count) == size else { throw BackupError.corrupted(key) }
                }
                if index % 256 == 0 {
                    progress(BackupProgress(completed: index, total: keys.count, path: L10n.text("Packing small files"), resumedFiles: 0, retries: 0))
                }
            }
        }
        try packed.flush()
        try packed.checkIntegrity()
        let committed = try PackedObjects.open(at: root)!
        // Verify the committed replacement before removing any original content.
        for (index, original) in originals.enumerated() {
            try autoreleasepool {
                guard let data = try committed.read(original.0), Int64(data.count) == references[original.0] else { throw BackupError.corrupted(original.0) }
                if index % 256 == 0 { progress(BackupProgress(completed: index, total: originals.count, path: L10n.text("Verifying packed contents"), resumedFiles: 0, retries: 0)) }
            }
        }
        for (index, original) in originals.enumerated() {
            try autoreleasepool {
            var current = stat()
            let before = original.2
            guard lstat(original.1.path, &current) == 0, current.st_mode & S_IFMT == S_IFREG,
                  current.st_dev == before.st_dev, (before.st_size == 0 || current.st_ino == before.st_ino),
                  current.st_size == before.st_size,
                  current.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec, current.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
                  current.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec, current.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec else {
                throw BackupError.changed(original.1.path)
            }
            guard unlink(original.1.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            let sidecar = original.1.deletingLastPathComponent().appendingPathComponent("._" + original.1.lastPathComponent)
            var extra = stat()
            if lstat(sidecar.path, &extra) == 0 {
                guard extra.st_mode & S_IFMT == S_IFREG else { throw BackupError.invalid(L10n.text("Check the metadata file path: ") + sidecar.path) }
                guard unlink(sidecar.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            }
            if index % 256 == 0 { progress(BackupProgress(completed: index, total: originals.count, path: L10n.text("Removing verified loose copies"), resumedFiles: 0, retries: 0)) }
            }
        }
        return originals.count
    }

    public func storageBytes(destination: URL, planID: UUID) throws -> Int64 {
        let root = try planRoot(try existingDirectory(destination), planID, create: false)
        // Foundation hides AppleDouble entries; POSIX includes their real allocation on exFAT.
        func allocated(_ url: URL) throws -> Int64 {
            var attributes = stat()
            guard lstat(url.path, &attributes) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            guard attributes.st_mode & S_IFMT != S_IFLNK else { throw BackupError.invalid(L10n.text("A backup storage path contains a symbolic link: ") + url.path) }
            var total = Int64(attributes.st_blocks) * 512
            if attributes.st_mode & S_IFMT == S_IFDIR {
                guard let directory = opendir(url.path) else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                defer { closedir(directory) }
                errno = 0
                while let entry = readdir(directory) {
                    let name = withUnsafeBytes(of: entry.pointee.d_name) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
                    if name != "." && name != ".." { total += try autoreleasepool { try allocated(url.appendingPathComponent(name)) } }
                    errno = 0
                }
                if errno != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            }
            return total
        }
        return try allocated(root)
    }

    private func isFatalStorageError(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSPOSIXErrorDomain && [ENOSPC, EIO, ENXIO].contains(Int32(error.code))
            || error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError
    }

    private func ioError(_ error: Error, operation: String, path: URL) -> NSError {
        let original = error as NSError
        if original.userInfo["FolderToolkitOperation"] != nil { return original }
        return NSError(domain: original.domain, code: original.code, userInfo: [
            NSLocalizedDescriptionKey: L10n.text("%@ failed · %@\n%@ (%@ %@)", operation, path.path, original.localizedDescription, original.domain, original.code),
            NSUnderlyingErrorKey: original, NSFilePathErrorKey: path.path, "FolderToolkitOperation": operation
        ])
    }

    private func sourceDisappeared(_ error: Error, at source: URL) -> Bool {
        let error = error as NSError
        let missing = error.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code)
            || error.domain == NSPOSIXErrorDomain && [ENOENT, ENOTDIR].contains(Int32(error.code))
        var info = stat()
        return missing && lstat(source.path, &info) != 0 && [ENOENT, ENOTDIR].contains(errno)
    }

    private func copyData(_ source: URL, to target: URL, cancelled: () -> Bool) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let descriptor = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o666)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? output.close() }
        while try autoreleasepool(invoking: {
            if cancelled() { throw BackupError.cancelled }
            guard let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty else { return false }
            do { try output.write(contentsOf: data) }
            catch { throw ioError(error, operation: L10n.text("Saving backup file contents"), path: target) }
            return true
        }) { }
    }

    private func copyMetadata(_ source: URL, to target: URL) throws {
        if copyfile(source.path, target.path, nil, copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW)) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    public func snapshotsToPrune(destination: URL, planID: UUID, keeping count: Int) throws -> [BackupSnapshot] {
        guard count >= 1 else { throw BackupError.invalid(L10n.text("Keep at least one completed backup.")) }
        return Array(try snapshots(destination: destination, planID: planID).dropFirst(count))
    }

    public func prune(destination: URL, planID: UUID, keeping count: Int) throws -> Int {
        let root = try planRoot(try existingDirectory(destination), planID, create: false)
        let handle = try acquireLock(root)
        defer { _ = flock(handle.fileDescriptor, LOCK_UN); try? handle.close() }
        let obsolete = try snapshotsToPrune(destination: destination, planID: planID, keeping: count)
        for snapshot in obsolete { try trashSnapshotUnlocked(snapshotID: snapshot.id, destination: destination, planID: planID) }
        return obsolete.count
    }

    public func trashSnapshot(snapshotID: String, destination: URL, planID: UUID) throws {
        let root = try planRoot(try existingDirectory(destination), planID, create: false)
        let handle = try acquireLock(root)
        defer { _ = flock(handle.fileDescriptor, LOCK_UN); try? handle.close() }
        try trashSnapshotUnlocked(snapshotID: snapshotID, destination: destination, planID: planID)
    }

    private func trashSnapshotUnlocked(snapshotID: String, destination: URL, planID: UUID) throws {
        let snapshot = try snapshotURL(snapshotID: snapshotID, destination: destination, planID: planID)
        let entries = try snapshotFiles(snapshotID: snapshotID, destination: destination, planID: planID)
        var retained = Set<String>()
        for other in try snapshots(destination: destination, planID: planID) where other.id != snapshotID {
            for entry in try snapshotFiles(snapshotID: other.id, destination: destination, planID: planID) where entry.kind == .file {
                if let key = entry.storageKey { retained.insert(key) }
            }
        }
        let exclusive = Set(entries.filter { $0.kind == .file }.compactMap(\.storageKey)).subtracting(retained)
        let packed = try PackedObjects.open(at: snapshot.deletingLastPathComponent(), create: manager.fileExists(atPath: snapshot.deletingLastPathComponent().appendingPathComponent(PackedObjects.filename).path))
        var archive: PackedObjects?
        var archivedKeys = Set<String>()
        for key in exclusive {
            if let data = try packed?.read(key) {
                if archive == nil { archive = try PackedObjects.open(at: snapshot, create: true) }
                _ = try archive!.put(data, key: key)
                archivedKeys.insert(key)
            }
            let source = try objectURL(root: snapshot.deletingLastPathComponent(), key: key)
            if manager.fileExists(atPath: source.path) {
                let target = try objectURL(root: snapshot, key: key)
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.moveItem(at: source, to: target)
            }
        }
        try archive?.checkIntegrity()
        if !archivedKeys.isEmpty {
            let committed = try PackedObjects.open(at: snapshot)!
            for key in archivedKeys { guard try committed.read(key) != nil else { throw BackupError.corrupted(key) } }
        }
        archive = nil
        try manager.trashItem(at: snapshot, resultingItemURL: nil)
        try packed?.remove(archivedKeys)
    }

    public func incompleteBackups(destination: URL, planID: UUID) throws -> [URL] {
        let root = try planRoot(try existingDirectory(destination), planID, create: false)
        guard manager.fileExists(atPath: root.path) else { return [] }
        return try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".partial-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { url in
                try rejectSymlink(url)
                guard (try manager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeDirectory else { throw BackupError.invalid(L10n.text("Invalid interrupted backup: %@", url.path)) }
                return url
            }
    }

    public func trashIncompleteBackups(destination: URL, planID: UUID) throws -> Int {
        let root = try planRoot(try existingDirectory(destination), planID, create: false)
        let handle = try acquireLock(root)
        defer { _ = flock(handle.fileDescriptor, LOCK_UN); try? handle.close() }
        let partials = try incompleteBackups(destination: destination, planID: planID)
        for url in partials { try manager.trashItem(at: url, resultingItemURL: nil) }
        return partials.count
    }

    private func acquireLock(_ root: URL) throws -> FileHandle {
        let descriptor = open(root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { try? handle.close(); throw BackupError.busy }
        return handle
    }

    public func snapshots(destination: URL, planID: UUID) throws -> [BackupSnapshot] {
        let root = try planRoot(try existingDirectory(destination), planID, create: false)
        guard manager.fileExists(atPath: root.path) else { return [] }
        return try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .map { url in
                try rejectSymlink(url)
                let snapshot = try JSONDecoder().decode(BackupSnapshot.self, from: Data(contentsOf: url.appendingPathComponent("snapshot.json")))
                guard snapshot.id == url.lastPathComponent else { throw BackupError.corrupted(url.path) }
                return snapshot
            }.sorted { $0.createdAt > $1.createdAt }
    }

    public func snapshotURL(snapshotID: String, destination: URL, planID: UUID) throws -> URL {
        guard !snapshotID.isEmpty, !snapshotID.hasPrefix("."), !snapshotID.contains("/"), !snapshotID.contains("\\"), !snapshotID.contains("\0") else {
            throw BackupError.invalid(L10n.text("Invalid backup identifier."))
        }
        let root = try planRoot(try existingDirectory(destination), planID, create: false)
        let url = root.appendingPathComponent(snapshotID, isDirectory: true)
        try rejectSymlink(url)
        return url
    }

    public func snapshotFiles(snapshotID: String, destination: URL, planID: UUID, cancelled: @Sendable () -> Bool = { false }) throws -> [BackupFileEntry] {
        if cancelled() { throw BackupError.cancelled }
        let url = try snapshotURL(snapshotID: snapshotID, destination: destination, planID: planID)
        let catalog = url.appendingPathComponent("manifest.json")
        try rejectSymlink(catalog)
        let entries = try JSONDecoder().decode([BackupFileEntry].self, from: Data(contentsOf: catalog))
        var paths = Set<String>()
        for entry in entries {
            if cancelled() { throw BackupError.cancelled }
            try autoreleasepool {
                // Browsing validates the catalog; disk paths are checked when data is read or restored.
                _ = try validatedPathComponents(entry.path)
                if entry.kind == .symbolicLink {
                    guard let target = entry.linkTarget, !target.isEmpty, !target.contains("\0") else { throw BackupError.corrupted(entry.path) }
                }
                if let key = entry.storageKey {
                    if entry.kind == .file {
                        guard key == entry.checksum else { throw BackupError.corrupted(entry.path) }
                        try validateStorageKey(key)
                    } else if !key.isEmpty { throw BackupError.corrupted(entry.path) }
                }
                guard paths.insert(entry.path).inserted else { throw BackupError.corrupted(entry.path) }
            }
        }
        return entries
    }

    public func verify(snapshotID: String, destination: URL, planID: UUID) throws {
        let root = try snapshotURL(snapshotID: snapshotID, destination: destination, planID: planID).appendingPathComponent("Files")
        let stores = try packedStores(root: root)
        for entry in try snapshotFiles(snapshotID: snapshotID, destination: destination, planID: planID) {
            try verify(entry, root: root, stores: stores)
        }
    }

    public func restore(snapshotID: String, destination: URL, planID: UUID, to restoreParent: URL, relativePaths: [String] = []) throws -> URL {
        let parent = try existingDirectory(restoreParent)
        let snapshot = try snapshotURL(snapshotID: snapshotID, destination: destination, planID: planID)
        if parent.path == snapshot.path || parent.path.hasPrefix(snapshot.path + "/") { throw BackupError.invalid(L10n.text("Choose a restore location outside the backup.")) }
        let root = snapshot.appendingPathComponent("Files")
        let selected = try selectedEntries(snapshotID: snapshotID, destination: destination, planID: planID, relativePaths: relativePaths)
        let result = parent.appendingPathComponent("Toolkit Restore-" + UUID().uuidString, isDirectory: true)
        try writeRestore(selected, root: root, result: result)
        return result
    }

    public func restoreBesideOriginal(snapshotID: String, destination: URL, planID: UUID, relativePaths: [String] = []) throws -> [URL] {
        let snapshot = try snapshotURL(snapshotID: snapshotID, destination: destination, planID: planID)
        let metadata = snapshot.appendingPathComponent("sources.json")
        try rejectSymlink(metadata)
        let locations = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: metadata))
        let entries = try selectedEntries(snapshotID: snapshotID, destination: destination, planID: planID, relativePaths: relativePaths)
        let groups = Dictionary(grouping: entries, by: { String($0.path.split(separator: "/")[0]) })
        var outputs: [(String, URL)] = []
        for label in groups.keys.sorted() {
            guard let path = locations[label], path.hasPrefix("/"), path != "/", !path.contains("//"), !path.contains("\0"),
                  !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
                throw BackupError.invalid(L10n.text("The original folder location is not valid."))
            }
            let original = URL(fileURLWithPath: path)
            var parent = original.deletingLastPathComponent()
            while parent.path != "/" {
                try rejectSymlink(parent)
                parent.deleteLastPathComponent()
            }
            let originalParent = try existingDirectory(original.deletingLastPathComponent())
            if originalParent.path == snapshot.path || originalParent.path.hasPrefix(snapshot.path + "/") {
                throw BackupError.invalid(L10n.text("Choose a restore location outside the backup."))
            }
            outputs.append((label, originalParent.appendingPathComponent(original.lastPathComponent + L10n.text(" (Restored-") + UUID().uuidString + ")", isDirectory: true)))
        }
        let root = snapshot.appendingPathComponent("Files")
        let stores = try packedStores(root: root)
        for entry in entries { try verify(entry, root: root, stores: stores) }
        for (label, output) in outputs {
            try writeRestore(groups[label]!, root: root, result: output, strippingRoot: true)
        }
        return outputs.map(\.1)
    }

    private func selectedEntries(snapshotID: String, destination: URL, planID: UUID, relativePaths: [String]) throws -> [BackupFileEntry] {
        let root = try snapshotURL(snapshotID: snapshotID, destination: destination, planID: planID).appendingPathComponent("Files")
        let entries = try snapshotFiles(snapshotID: snapshotID, destination: destination, planID: planID)
        for path in relativePaths {
            _ = try safeChild(root, path)
            guard entries.contains(where: { $0.path == path }) else { throw BackupError.invalid(L10n.text("This file is not in the backup: %@", path)) }
        }
        let selected = entries.filter { entry in
            relativePaths.isEmpty || relativePaths.contains { entry.path == $0 || entry.path.hasPrefix($0 + "/") || $0.hasPrefix(entry.path + "/") }
        }
        let stores = try packedStores(root: root)
        for entry in selected { try verify(entry, root: root, stores: stores) }
        return selected
    }

    private func writeRestore(_ entries: [BackupFileEntry], root: URL, result: URL, strippingRoot: Bool = false) throws {
        let staging = result.deletingLastPathComponent().appendingPathComponent(".partial-restore-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        func output(_ entry: BackupFileEntry) throws -> URL {
            if !strippingRoot { return try safeChild(staging, entry.path) }
            let path = entry.path.split(separator: "/").dropFirst().joined(separator: "/")
            return path.isEmpty ? staging : try safeChild(staging, path)
        }
        let stores = try packedStores(root: root)
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            try autoreleasepool {
                let source = entry.kind == .file ? try storedFile(entry, root: root) : try safeChild(root, entry.path)
                let target = try output(entry)
                switch entry.kind {
                case .directory:
                    if target != staging { try manager.createDirectory(at: target, withIntermediateDirectories: false) }
                case .symbolicLink: try manager.createSymbolicLink(atPath: target.path, withDestinationPath: entry.linkTarget!)
                case .file:
                    if let data = try packedData(entry, stores: stores) { try data.write(to: target) }
                    else { try manager.copyItem(at: source, to: target) }
                    guard try hash(target) == entry.checksum else { throw BackupError.corrupted(entry.path) }
                }
            }
        }
        for entry in entries.reversed() where entry.kind != .symbolicLink {
            try autoreleasepool {
                let target = try output(entry)
                if entry.storageKey != nil {
                    try restoreMetadata(entry, to: target)
                } else if entry.kind == .directory {
                    try copyMetadata(safeChild(root, entry.path), to: target)
                }
            }
        }
        try manager.moveItem(at: staging, to: result)
    }

    private func verify(_ entry: BackupFileEntry, root: URL, stores: [PackedObjects]) throws {
        try autoreleasepool {
            if let data = try packedData(entry, stores: stores) {
                guard data.count == entry.bytes else { throw BackupError.corrupted(entry.path) }
                return
            }
            if entry.storageKey != nil && entry.kind != .file {
                if entry.kind == .symbolicLink && entry.linkTarget == nil { throw BackupError.corrupted(entry.path) }
                return
            }
            let url = try storedFile(entry, root: root)
            let attributes = try manager.attributesOfItem(atPath: url.path)
            let type = attributes[.type] as? FileAttributeType
            switch entry.kind {
            case .file:
                guard type == .typeRegular, entry.checksum != nil, try hash(url) == entry.checksum else { throw BackupError.corrupted(entry.path) }
            case .directory:
                guard type == .typeDirectory else { throw BackupError.corrupted(entry.path) }
            case .symbolicLink:
                guard type == .typeSymbolicLink, let expected = entry.linkTarget,
                      try manager.destinationOfSymbolicLink(atPath: url.path) == expected else { throw BackupError.corrupted(entry.path) }
            }
        }
    }

    private func packedStores(root: URL) throws -> [PackedObjects] {
        try [root.deletingLastPathComponent(), root.deletingLastPathComponent().deletingLastPathComponent()]
            .compactMap { try PackedObjects.open(at: $0) }
    }

    private func packedData(_ entry: BackupFileEntry, stores: [PackedObjects]) throws -> Data? {
        guard entry.kind == .file, let key = entry.storageKey else { return nil }
        for store in stores { if let data = try store.read(key) { return data } }
        return nil
    }

    private func validateStorageKey(_ key: String) throws {
        guard key.utf8.count == 64, key.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw BackupError.corrupted(key)
        }
    }

    private func objectURL(root: URL, key: String) throws -> URL {
        try validateStorageKey(key)
        let url = try safeChild(root, ".objects/" + key.prefix(2) + "/" + key)
        try rejectSymlink(url)
        return url
    }

    private func storedFile(_ entry: BackupFileEntry, root: URL) throws -> URL {
        if let key = entry.storageKey, entry.kind == .file {
            let archived = try objectURL(root: root.deletingLastPathComponent(), key: key)
            if manager.fileExists(atPath: archived.path) { return archived }
            return try objectURL(root: root.deletingLastPathComponent().deletingLastPathComponent(), key: key)
        }
        return try safeChild(root, entry.path)
    }

    private func packMetadata(_ source: URL) throws -> Data? {
        let flags = copyfile_flags_t(COPYFILE_XATTR | COPYFILE_ACL | COPYFILE_NOFOLLOW)
        let check = copyfile(source.path, nil, nil, flags | copyfile_flags_t(COPYFILE_CHECK))
        guard check >= 0 else { throw ioError(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)), operation: L10n.text("Reading and staging source metadata"), path: source) }
        if check == 0 { return nil }
        guard let temporary = tmpfile() else { throw ioError(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)), operation: L10n.text("Reading and staging source metadata"), path: source) }
        defer { fclose(temporary) }
        let input = open(source.path, O_RDONLY | O_NOFOLLOW)
        guard input >= 0 else { throw ioError(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)), operation: L10n.text("Reading and staging source metadata"), path: source) }
        defer { close(input) }
        let descriptor = fileno(temporary)
        guard fcopyfile(input, descriptor, nil, copyfile_flags_t(COPYFILE_PACK | COPYFILE_METADATA)) == 0 else {
            throw ioError(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)), operation: L10n.text("Reading and staging source metadata"), path: source)
        }
        _ = lseek(descriptor, 0, SEEK_SET)
        return try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readToEnd()
    }

    private func restoreMetadata(_ entry: BackupFileEntry, to target: URL) throws {
        if let archive = entry.metadataArchive {
            guard let temporary = tmpfile() else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            defer { fclose(temporary) }
            let descriptor = fileno(temporary)
            try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).write(contentsOf: archive)
            _ = lseek(descriptor, 0, SEEK_SET)
            let output = open(target.path, O_RDONLY | O_NOFOLLOW)
            guard output >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            defer { close(output) }
            guard fcopyfile(descriptor, output, nil, copyfile_flags_t(COPYFILE_UNPACK | COPYFILE_METADATA)) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
        var attributes: [FileAttributeKey: Any] = [.modificationDate: entry.modifiedAt, .posixPermissions: NSNumber(value: entry.permissions)]
        if let created = entry.createdAt { attributes[.creationDate] = created }
        try manager.setAttributes(attributes, ofItemAtPath: target.path)
    }

    private func hash(_ url: URL, cancelled: () -> Bool = { false }) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while try autoreleasepool(invoking: {
            if cancelled() { throw BackupError.cancelled }
            guard let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty else { return false }
            hasher.update(data: data)
            return true
        }) { }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func existingDirectory(_ url: URL) throws -> URL {
        guard let resolved = realpath(url.path, nil) else { throw BackupError.invalid(L10n.text("Cannot access this folder or drive: %@", url.path)) }
        let url = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        free(resolved)
        var directory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else {
            throw BackupError.invalid(L10n.text("Cannot access this folder or drive: %@", url.path))
        }
        return url
    }

    private func planRoot(_ destination: URL, _ id: UUID, create: Bool) throws -> URL {
        let container = destination.appendingPathComponent("Toolkit Backups", isDirectory: true)
        let root = container.appendingPathComponent(id.uuidString, isDirectory: true)
        for url in [container, root] {
            try rejectSymlink(url)
            if create {
                do { try manager.createDirectory(at: url, withIntermediateDirectories: false) }
                catch {
                    var directory: ObjCBool = false
                    guard manager.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else { throw error }
                    try rejectSymlink(url)
                }
            }
        }
        return root
    }

    private func rejectSymlink(_ url: URL) throws {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw BackupError.invalid(L10n.text("A backup storage path contains a symbolic link: %@", url.path))
        }
    }

    private func validatedPathComponents(_ path: String) throws -> [Substring] {
        let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.contains("\0"), !pieces.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw BackupError.invalid(L10n.text("Invalid backup path: %@", path))
        }
        return pieces
    }

    private func safeChild(_ root: URL, _ path: String) throws -> URL {
        let pieces = try validatedPathComponents(path)
        try rejectSymlink(root)
        var parent = root
        for piece in pieces.dropLast() {
            parent.appendPathComponent(String(piece))
            try rejectSymlink(parent)
        }
        return root.appendingPathComponent(path)
    }

    private func overlaps(_ first: URL, _ second: URL) -> Bool {
        first.path == "/" || second.path == "/" || first.path == second.path || first.path.hasPrefix(second.path + "/") || second.path.hasPrefix(first.path + "/")
    }

    private func sameFile(_ first: [FileAttributeKey: Any], _ second: [FileAttributeKey: Any]) -> Bool {
        [FileAttributeKey.type, .size, .modificationDate, .systemFileNumber, .posixPermissions].allSatisfy {
            guard let first = first[$0] as? NSObject, let second = second[$0] as? NSObject else { return false }
            return first == second
        }
    }

    private func changeTime(_ url: URL) throws -> String {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return "\(info.st_dev):\(info.st_ino):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
    }

    public static func isExcluded(_ path: String, patterns: [String]) -> Bool {
        patterns.contains { pattern in
            let normalized = pattern.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !normalized.isEmpty else { return false }
            let parts = path.split(separator: "/")
            return path == normalized || path.hasPrefix(normalized + "/") ||
                parts.contains { fnmatch(normalized, String($0), 0) == 0 } ||
                parts.indices.contains { fnmatch(normalized, parts[$0...].joined(separator: "/"), 0) == 0 }
        }
    }
}
