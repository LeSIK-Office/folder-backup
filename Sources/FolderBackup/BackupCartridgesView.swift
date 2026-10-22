import SwiftUI
import AppKit
import Combine
import BackupCore

struct BackupCartridgesView: View {
    @ObservedObject var store: BackupStore
    let plan: BackupPlan
    let openSnapshot: (String) -> Void
    @State private var snapshots: [BackupSnapshot] = []
    @State private var allocatedBytes: Int64?
    @State private var loading = true
    @State private var unavailable = false
    @State private var refreshID = UUID()
    @State private var deleting: BackupSnapshot?
    @State private var deletingNow = false
    @State private var error: String?

    var body: some View {
        BackupCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Text(L10n.text("Saved Backups")).font(.system(size: 16, weight: .semibold))
                    if !loading && !unavailable {
                        Text(L10n.text("Completed: %@", snapshots.count)).font(.system(size: 12, weight: .medium)).foregroundStyle(BackupTheme.accent)
                    }
                    Spacer()
                    Button { refreshID = UUID() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).accessibilityLabel(L10n.text("Refresh Saved Backups")).disabled(loading || store.maintenance)
                }
                if loading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L10n.text("Checking saved backups…")).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                } else if unavailable {
                    Label(L10n.text("Cannot load the backup list. Check the drive connection and access permissions."), systemImage: "externaldrive.badge.exclamationmark")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } else if snapshots.isEmpty {
                    Text(store.runningID == plan.id ? L10n.text("Your first backup is running. It will appear here when complete.") : L10n.text("No completed backups yet. After the first backup, you can see its date and file count here."))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    if let allocatedBytes {
                        Text(L10n.text("Total backup storage used: %@", byteString(allocatedBytes)))
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(BackupTheme.accent)
                    }
                    ForEach(snapshots) { snapshot in
                        HStack(spacing: 14) {
                            Image(systemName: "archivebox.fill").font(.system(size: 27)).foregroundStyle(BackupTheme.accent)
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 8) {
                                    Text(L10n.date(snapshot.createdAt))
                                        .font(.system(size: 14, weight: .semibold))
                                    if snapshot.id == snapshots.first?.id {
                                        Text(L10n.text("Latest")).font(.system(size: 11, weight: .medium)).foregroundStyle(BackupTheme.accent)
                                    }
                                    Label(L10n.text("Complete"), systemImage: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(BackupTheme.accent)
                                }
                                Text(L10n.text("Files: %@ · Restore size: %@", snapshot.files.formatted(.number.locale(L10n.locale)), byteString(snapshot.bytes)))
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                                if let copiedBytes = snapshot.copiedBytes {
                                    Text(L10n.text("New file contents saved in this run: %@", byteString(copiedBytes)))
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 12)
                            Button(L10n.text("Restore")) { openSnapshot(snapshot.id) }.buttonStyle(BackupButton(secondary: true))
                                .disabled(store.runningID != nil || store.maintenance)
                            Button(role: .destructive) { deleting = snapshot } label: {
                                Image(systemName: "trash").font(.system(size: 15)).padding(6)
                            }.buttonStyle(.plain).foregroundStyle(.red)
                                .accessibilityLabel(L10n.text("Delete saved backup: ") + L10n.date(snapshot.createdAt))
                                .help(L10n.text("Move this backup to the Trash"))
                                .disabled(store.runningID != nil || store.maintenance)
                        }.padding(14).background(BackupTheme.background.opacity(0.55)).clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    if deletingNow {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text(L10n.text("Moving the selected backup to the Trash…")).font(.system(size: 12)) }
                    }
                    Text(L10n.text("Restore sizes describe each point in time; do not add them together. Unchanged files are shared. Total storage includes all saved backups and metadata."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .alert(L10n.text("Delete this saved backup?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(L10n.text("Cancel"), role: .cancel) { deleting = nil }
            Button(L10n.text("Move to Trash"), role: .destructive) {
                if let snapshot = deleting { trash(snapshot) }
                deleting = nil
            }
        } message: {
            Text(L10n.text("Only the backup from %@ will move to the Trash. Source files and data shared with other backups are kept. Space is freed when you empty the Trash.", deleting.map { L10n.date($0.createdAt) } ?? ""))
        }
        .alert(L10n.text("Check Backup Deletion"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(L10n.text("OK")) { error = nil }
        } message: { Text(L10n.message(error ?? "")) }
        .task(id: refreshID) { await load() }
        .onChange(of: plan.lastSuccess) { _, _ in refreshID = UUID() }
        .onChange(of: plan.destination) { _, _ in refreshID = UUID() }
        .onChange(of: store.maintenance) { _, active in if !active { refreshID = UUID() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshID = UUID() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in refreshID = UUID() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in refreshID = UUID() }
    }

    @MainActor private func trash(_ snapshot: BackupSnapshot) {
        guard store.runningID == nil, !store.maintenance else { return }
        deletingNow = true
        store.maintenance = true
        store.status = L10n.text("Cleaning up saved backups…")
        Task {
            defer { deletingNow = false; store.maintenance = false; refreshID = UUID() }
            do {
                let destination = try plan.destination.resolve()
                let id = plan.id
                try await Task.detached { try BackupEngine().trashSnapshot(snapshotID: snapshot.id, destination: destination, planID: id) }.value
                store.status = L10n.text("Backup moved to the Trash. Other backups are safe.")
            } catch {
                self.error = L10n.text("Could not finish removing the backup. Check the drive connection and access permissions.")
                store.status = L10n.text("Backup cleanup needs attention.")
            }
        }
    }

    @MainActor private func load() async {
        loading = true
        do {
            let destination = try plan.destination.resolve()
            let id = plan.id
            let result = try await Task.detached {
                let engine = BackupEngine()
                return (snapshots: try engine.snapshots(destination: destination, planID: id),
                        allocated: try? engine.storageBytes(destination: destination, planID: id))
            }.value
            guard !Task.isCancelled else { return }
            snapshots = result.snapshots
            allocatedBytes = result.allocated
            unavailable = false
        } catch {
            guard !Task.isCancelled else { return }
            unavailable = true
        }
        loading = false
    }
}
