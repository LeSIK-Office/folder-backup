import AppKit
import BackupCore
import Combine
import CryptoKit
import Foundation
import Darwin

struct FolderSelection: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var bookmark: Data
    var path: String
    var volumeUUID: String?

    init(url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .volumeUUIDStringKey])
        guard values.isDirectory == true else { throw RuntimeError.message(L10n.text("Choose a folder: %@", url.path)) }
        bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        path = url.path
        volumeUUID = values.volumeUUIDString
    }

    func resolve() throws -> URL {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .volumeUUIDStringKey])
        guard values.isDirectory == true else { throw RuntimeError.message(L10n.text("Folder not found: %@", path)) }
        if let volumeUUID, values.volumeUUIDString != volumeUUID {
            throw RuntimeError.message(L10n.text("The selected drive is not connected: %@", path))
        }
        // A stale bookmark can still resolve; saving a plan or completing a scan refreshes it.
        return url
    }
}

struct BackupSchedule: Codable, Equatable {
    enum Frequency: String, CaseIterable, Codable, Identifiable {
        case continuous, hourly, daily, weekly, monthly, manual
        var id: String { rawValue }
        var title: String {
            switch self {
            case .continuous: return L10n.text("Continuous")
            case .hourly: return L10n.text("Hourly")
            case .daily: return L10n.text("Daily")
            case .weekly: return L10n.text("Weekly")
            case .monthly: return L10n.text("Monthly")
            case .manual: return L10n.text("Manual")
            }
        }
    }
    var frequency: Frequency = .daily
    var hour: Int = 20
    var minute: Int = 0
    var weekday: Int = 2
    var day: Int = 1

    func next(after date: Date, calendar: Calendar = .current) -> Date? {
        guard frequency != .manual else { return nil }
        if frequency == .continuous { return date.addingTimeInterval(60) }
        var components = DateComponents()
        components.minute = min(59, max(0, minute))
        components.second = 0
        if frequency != .hourly { components.hour = min(23, max(0, hour)) }
        if frequency == .weekly { components.weekday = min(7, max(1, weekday)) }
        if frequency == .monthly {
            // The last day of a short month also runs a plan configured for the 29th–31st.
            var month = calendar.dateInterval(of: .month, for: date)!.start
            for _ in 0..<3 {
                let days = calendar.range(of: .day, in: .month, for: month)!.count
                components.day = min(days, max(1, min(31, day)))
                let start = calendar.date(byAdding: .second, value: -1, to: month)!
                if let candidate = calendar.nextDate(after: start, matching: components, matchingPolicy: .nextTime, repeatedTimePolicy: .first), candidate > date {
                    return candidate
                }
                month = calendar.date(byAdding: .month, value: 1, to: month)!
            }
            return nil
        }
        return calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime, repeatedTimePolicy: .first)
    }
}

struct BackupRun: Identifiable, Codable {
    enum Outcome: String, Codable { case success, failure, cancelled }
    var id: UUID = UUID()
    var startedAt: Date
    var finishedAt: Date
    var outcome: Outcome
    var snapshotID: String?
    var message: String?
}

struct BackupPlan: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var sources: [FolderSelection]
    var destination: FolderSelection
    var schedule: BackupSchedule = BackupSchedule()
    var paused: Bool = false
    var exclusions: [String] = []
    var createdAt: Date = Date()
    var lastSuccess: Date?
    var lastAttempt: Date?
    var nextRun: Date?
    var lastError: String?
    var history: [BackupRun] = []
    var lastFingerprint: String?
    var retention: BackupRetention?
}

private enum RuntimeError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(message) = self { return message }; return nil }
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    private var publishedAt: TimeInterval = 0
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func shouldPublish(_ progress: BackupProgress) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        guard progress.total == 0 || progress.completed == progress.total || now - publishedAt >= 0.15 else { return false }
        publishedAt = now
        return true
    }
}

@MainActor
final class BackupStore: ObservableObject {
    @Published var language = L10n.selection {
        didSet {
            L10n.selection = language
            status = L10n.message(status)
        }
    }
    @Published var plans: [BackupPlan] = []
    @Published var selectedID: UUID?
    @Published var runningID: UUID?
    @Published var maintenance = false
    @Published var progress: BackupProgress?
    @Published var status = L10n.text("Choose a folder to back up.")
    @Published var error: String?

    private let storageURL: URL
    private var canSave = true
    private var cancellation: CancellationFlag?
    private var scheduler: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    init(storageURL: URL? = nil, startScheduler: Bool = true) {
        // 기존 설치의 계획과 예약을 같은 위치에서 계속 사용한다.
        self.storageURL = storageURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FolderToolkit/plans.json")
        if FileManager.default.fileExists(atPath: self.storageURL.path) {
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                plans = try decoder.decode([BackupPlan].self, from: Data(contentsOf: self.storageURL))
                selectedID = plans.first?.id
                status = L10n.text("Ready to back up")
                var interrupted = false
                for index in plans.indices {
                    if let attempt = plans[index].lastAttempt,
                       attempt > (plans[index].history.map(\.finishedAt).max() ?? .distantPast) {
                        plans[index].history.insert(BackupRun(startedAt: attempt, finishedAt: Date(), outcome: .cancelled,
                                                             message: L10n.text("The app closed during a backup. The schedule is paused; resume manually when ready.")), at: 0)
                        plans[index].paused = true
                        plans[index].nextRun = plans[index].schedule.next(after: Date())
                        interrupted = true
                    }
                }
                if interrupted {
                    try persist(plans)
                    status = L10n.text("Previous backup interrupted · Schedule paused · Resume manually when ready")
                }
            } catch {
                canSave = false
                self.error = L10n.text("Could not read backup settings. The original file was preserved. %@", error.localizedDescription)
            }
        }
        if startScheduler {
            scheduler = Task { [weak self] in
                while !Task.isCancelled {
                    self?.checkSchedules()
                    try? await Task.sleep(for: .seconds(60))
                }
            }
            for name in [NSWorkspace.didWakeNotification, NSWorkspace.didMountNotification] {
                observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.checkSchedules() }
                })
            }
        }
    }

    deinit {
        scheduler?.cancel()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    func savePlan(_ plan: BackupPlan) {
        guard canSave else { error = L10n.text("Existing settings could not be read and will not be overwritten."); return }
        guard runningID != plan.id else { error = L10n.text("Stop the running backup first."); return }
        do {
            guard !plan.sources.isEmpty else { throw RuntimeError.message(L10n.text("Choose at least one folder to back up.")) }
            guard !plan.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RuntimeError.message(L10n.text("Enter a backup name.")) }
            var saved = plan
            saved.sources = try plan.sources.map { selection in
                var refreshed = try FolderSelection(url: selection.resolve())
                refreshed.id = selection.id
                return refreshed
            }
            saved.destination = try FolderSelection(url: plan.destination.resolve())
            saved.destination.id = plan.destination.id
            if let existing = plans.first(where: { $0.id == plan.id }), existing.schedule == plan.schedule {
                saved.nextRun = existing.nextRun ?? plan.schedule.next(after: existing.lastSuccess ?? existing.createdAt)
            } else {
                saved.nextRun = plan.schedule.next(after: Date())
            }
            if let existing = plans.first(where: { $0.id == plan.id }),
               existing.destination.path != saved.destination.path || existing.destination.volumeUUID != saved.destination.volumeUUID {
                saved.lastFingerprint = nil
            }
            var updated = plans
            if let index = updated.firstIndex(where: { $0.id == plan.id }) { updated[index] = saved }
            else { updated.append(saved) }
            try persist(updated)
            plans = updated
            selectedID = saved.id
            error = nil
            status = L10n.text("Backup plan saved.")
        } catch { self.error = error.localizedDescription }
    }

    func removePlan(id: UUID) {
        guard runningID != id else { error = L10n.text("Stop the running backup first."); return }
        do {
            let updated = plans.filter { $0.id != id }
            try persist(updated)
            plans = updated
            if selectedID == id { selectedID = plans.first?.id }
            status = L10n.text("Backup plan removed. Saved backups are kept.")
        } catch { self.error = error.localizedDescription }
    }

    func saveSchedule(id: UUID, schedule: BackupSchedule, paused: Bool) {
        guard canSave else { error = L10n.text("Settings could not be read, so no changes were saved."); return }
        guard let index = plans.firstIndex(where: { $0.id == id }) else { return }
        var updated = plans
        updated[index].schedule = schedule
        updated[index].paused = paused
        updated[index].nextRun = schedule.next(after: Date())
        do {
            try persist(updated)
            plans = updated
            error = nil
            if runningID == nil { status = paused ? L10n.text("Scheduled backups turned off.") : L10n.text("Schedule saved.") }
        } catch { self.error = error.localizedDescription }
    }

    func togglePause(_ plan: BackupPlan) {
        guard let current = plans.first(where: { $0.id == plan.id }) else { return }
        saveSchedule(id: current.id, schedule: current.schedule, paused: !current.paused)
    }

    func nextRun(for plan: BackupPlan, after date: Date = Date()) -> Date? {
        guard !plan.paused else { return nil }
        return plan.nextRun ?? plan.schedule.next(after: plan.lastSuccess ?? plan.createdAt)
    }

    func checkSchedules(now: Date = Date()) {
        guard runningID == nil, !maintenance, canSave else { return }
        for plan in plans.sorted(by: { ($0.lastAttempt ?? .distantPast) < ($1.lastAttempt ?? .distantPast) }) where !plan.paused && plan.schedule.frequency != .manual {
            let due = plan.nextRun ?? (plan.schedule.frequency == .continuous && plan.lastSuccess == nil ? plan.createdAt : plan.schedule.next(after: plan.lastSuccess ?? plan.createdAt))
            if let due, due <= now {
                // An unplugged drive keeps its due time so mounting it catches up immediately.
                guard (try? plan.destination.resolve()) != nil else { status = L10n.text("Waiting for the backup drive: %@", plan.name); continue }
                start(plan, skipUnchanged: plan.schedule.frequency == .continuous)
                return
            }
        }
    }

    func run(_ plan: BackupPlan) { start(plan, skipUnchanged: false) }

    func cancel() {
        cancellation?.cancel()
        if runningID != nil { status = L10n.text("Stopping backup…") }
    }

    private func start(_ requestedPlan: BackupPlan, skipUnchanged: Bool) {
        guard canSave else { error = L10n.text("Cannot start a backup because settings could not be read."); return }
        guard runningID == nil, !maintenance else { error = L10n.text("Another backup or restore operation is in progress."); return }
        guard let plan = plans.first(where: { $0.id == requestedPlan.id }) else { return }
        let started = Date()
        do {
            var updated = plans
            let index = updated.firstIndex(where: { $0.id == plan.id })!
            updated[index].lastAttempt = started
            updated[index].lastError = nil
            try persist(updated)
            plans = updated
        } catch { self.error = error.localizedDescription; return }
        let token = CancellationFlag()
        cancellation = token
        runningID = plan.id
        progress = nil
        error = nil
        status = L10n.text("Preparing backup…")
        Task {
            let activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: L10n.text("Folder backup"))
            defer {
                ProcessInfo.processInfo.endActivity(activity)
                runningID = nil
                progress = nil
                cancellation = nil
            }
            do {
                let result = try await Task.detached(priority: .utility) { [self] () throws -> (snapshot: BackupSnapshot?, fingerprint: String, sources: [FolderSelection], destination: FolderSelection, cleanup: String?) in
                    let sources = try plan.sources.map { try $0.resolve() }
                    let destination = try plan.destination.resolve()
                    let refreshedSources = try zip(plan.sources, sources).map { selection, url in
                        var refreshed = try FolderSelection(url: url)
                        refreshed.id = selection.id
                        return refreshed
                    }
                    var refreshedDestination = try FolderSelection(url: destination)
                    refreshedDestination.id = plan.destination.id
                    let fingerprint = plan.schedule.frequency == .continuous
                        ? try Self.fingerprint(sources: sources, exclusions: plan.exclusions, cancelled: { token.isCancelled }) : ""
                    if token.isCancelled { throw CancellationError() }
                    let engine = BackupEngine()
                    if skipUnchanged, fingerprint == plan.lastFingerprint,
                       let baselineID = plan.history.first(where: { $0.outcome == .success })?.snapshotID,
                       try engine.snapshots(destination: destination, planID: plan.id).contains(where: { $0.id == baselineID }) {
                        return (nil, fingerprint, refreshedSources, refreshedDestination, nil)
                    }
                    let snapshot = try engine.backup(sources: sources, destination: destination, planID: plan.id, exclusions: plan.exclusions, progress: { update in
                        guard token.shouldPublish(update) else { return }
                        Task { @MainActor in
                            guard self.cancellation === token, !token.isCancelled else { return }
                            self.progress = update
                            self.status = update.total == 0 ? L10n.text("Scanning source folders…") : L10n.text("Backing up · %@/%@ · Reused: %@ · Saved: %@", update.completed, update.total, update.resumedFiles, update.copiedFiles)
                        }
                    }, cancelled: { token.isCancelled })
                    var cleanup: String?
                    if let limit = plan.retention?.limit {
                        do {
                            let count = try engine.prune(destination: destination, planID: plan.id, keeping: limit)
                            if count > 0 { cleanup = L10n.text("Older backups moved to the Trash: %@", count) }
                        } catch { cleanup = L10n.text("Backup completed, but older versions could not be cleaned up: %@", error.localizedDescription) }
                    }
                    return (snapshot, fingerprint, refreshedSources, refreshedDestination, cleanup)
                }.value
                guard let index = plans.firstIndex(where: { $0.id == plan.id }) else { return }
                var updated = plans
                updated[index].nextRun = updated[index].schedule.next(after: Date())
                updated[index].sources = result.sources
                updated[index].destination = result.destination
                updated[index].lastError = nil
                if let snapshot = result.snapshot {
                    updated[index].lastAttempt = started
                    updated[index].lastSuccess = Date()
                    updated[index].lastFingerprint = result.fingerprint
                    let skipped = snapshot.skippedItems ?? []
                    let notice = skipped.isEmpty ? nil : L10n.text("Runtime or removed source items skipped: %@", skipped.count.formatted(.number.locale(L10n.locale)))
                    let summary = [notice, result.cleanup].compactMap { $0 }.joined(separator: " · ")
                    let record = summary + (skipped.isEmpty ? "" : "\n" + skipped.joined(separator: "\n"))
                    updated[index].history.insert(BackupRun(startedAt: started, finishedAt: Date(), outcome: .success, snapshotID: snapshot.id, message: record.isEmpty ? nil : record), at: 0)
                    status = L10n.text("Backup complete · Saved: %@ · Reused: %@", snapshot.copiedFiles ?? 0, snapshot.resumedFiles ?? 0) + (notice.map { " · " + $0 } ?? "")
                } else { status = L10n.text("No files have changed.") }
                try persist(updated)
                plans = updated
            } catch {
                let cancelled = token.isCancelled || error is CancellationError
                let message = cancelled ? L10n.text("Backup stopped by the user.") : Self.failureSummary(error)
                let details: String
                if case BackupError.incomplete(let paths) = error { details = paths.joined(separator: "\n") }
                else { details = error.localizedDescription }
                status = cancelled ? L10n.text("Stopped · Copied files will be reused when resumed.") : L10n.text("Backup incomplete · Copied files are safe.")
                if !cancelled { self.error = message }
                if let index = plans.firstIndex(where: { $0.id == plan.id }) {
                    var updated = plans
                    updated[index].lastAttempt = started
                    updated[index].lastError = cancelled ? nil : message
                    let record = cancelled || details == message ? message : message + "\n" + details
                    updated[index].history.insert(BackupRun(startedAt: started, finishedAt: Date(), outcome: cancelled ? .cancelled : .failure, message: record), at: 0)
                    updated[index].nextRun = updated[index].schedule.next(after: Date())
                    do { try persist(updated); plans = updated }
                    catch { self.error = L10n.text("Could not save the run history: %@", error.localizedDescription) }
                }
            }
        }
    }

    static func failureSummary(_ error: Error) -> String {
        if let error = error as? BackupError { return error.localizedDescription }
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain && error.code == ENOSPC
            || error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError {
            return L10n.text("Backup stopped because storage is full. Copied files are safe. Free up space, then resume the backup.")
        }
        if error.domain == NSPOSIXErrorDomain && [EACCES, EPERM].contains(Int32(error.code))
            || error.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(error.code) {
            return L10n.text("Backup could not access a file or destination. Check the details and allow access to the affected folder.")
        }
        return L10n.text("Backup could not finish. Copied files are safe. Check the details for the cause.")
    }

    private func persist(_ plans: [BackupPlan]) throws {
        guard canSave else { throw RuntimeError.message(L10n.text("Unreadable settings will not be overwritten.")) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(plans)
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: storageURL, options: .atomic)
    }

    nonisolated private static func fingerprint(sources: [URL], exclusions: [String], cancelled: () -> Bool) throws -> String {
        let manager = FileManager.default
        let sources = sources.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        var hasher = SHA256()
        let counts = Dictionary(grouping: sources, by: { $0.lastPathComponent }).mapValues(\.count)
        func metadata(_ url: URL, path: String) throws -> String {
            var attributes = stat()
            guard lstat(url.path, &attributes) == 0 else {
                if errno == ENOENT { return "" }
                throw RuntimeError.message(L10n.text("Cannot read this folder’s contents: %@", url.path))
            }
            return "\(path)|\(attributes.st_mode)|\(attributes.st_size)|\(attributes.st_ino)|\(attributes.st_mtimespec.tv_sec).\(attributes.st_mtimespec.tv_nsec)|\(attributes.st_ctimespec.tv_sec).\(attributes.st_ctimespec.tv_nsec)"
        }
        for source in sources.sorted(by: { $0.path < $1.path }) {
            var label = source.lastPathComponent
            if counts[label, default: 0] > 1 { label += "-" + String(SHA256.hash(data: Data(source.path.utf8)).description.suffix(8)) }
            if BackupEngine.isExcluded(label, patterns: exclusions) { continue }
            var entries = [try metadata(source, path: label)]
            var enumerationError: Error?
            guard let enumerator = manager.enumerator(at: source, includingPropertiesForKeys: nil, options: [], errorHandler: { _, error in
                let value = error as NSError
                if value.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(value.code) { return true }
                enumerationError = error; return false
            }) else {
                throw RuntimeError.message(L10n.text("Cannot read this folder: %@", source.path))
            }
            for case let url as URL in enumerator {
                if cancelled() { throw CancellationError() }
                let path = label + String(url.path.dropFirst(source.path.count))
                if BackupEngine.isExcluded(path, patterns: exclusions) { enumerator.skipDescendants(); continue }
                entries.append(try metadata(url, path: path))
            }
            if let enumerationError { throw enumerationError }
            hasher.update(data: Data(source.path.utf8))
            for entry in entries.sorted() { hasher.update(data: Data((entry + "\n").utf8)) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
