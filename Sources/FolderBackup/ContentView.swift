import SwiftUI
import AppKit
import BackupCore

struct ContentView: View {
    @ObservedObject var store: BackupStore
    @State private var editing: BackupPlan?
    @State private var showEditor = false
    @State private var historyPlan: BackupPlan?
    @State private var historyStartsWithLog = false
    @State private var historySnapshotID: String?
    @State private var remove: BackupPlan?
    @State private var showHelp = false
    @State private var archive: ArchiveLocation?
    @State private var showSettings = false

    private var selected: BackupPlan? {
        store.plans.first { $0.id == store.selectedID } ?? store.plans.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 14) {
                    driveCard
                    if store.plans.isEmpty { emptyState }
                    else {
                        ForEach(store.plans) { plan in
                            VStack(spacing: 12) {
                                planCard(plan)
                                BackupCartridgesView(store: store, plan: plan) { id in
                                    store.selectedID = plan.id
                                    historyStartsWithLog = false
                                    historySnapshotID = id
                                    historyPlan = plan
                                }
                            }
                        }
                    }
                }.padding(18)
            }
            HStack(spacing: 8) {
                Image(systemName: store.runningID != nil ? "arrow.triangle.2.circlepath" : selected?.lastError != nil ? "exclamationmark.triangle" : "checkmark.circle")
                Text(L10n.message(store.status)).lineLimit(1)
                Spacer()
                Text(L10n.text("Folder backup")).foregroundStyle(.secondary)
            }
            .font(.system(size: 12)).padding(.horizontal, 22).padding(.vertical, 13)
            .background(.white.opacity(0.65))
        }
        .foregroundStyle(BackupTheme.ink)
        .background(BackupTheme.background)
        .tint(BackupTheme.accent)
        .frame(minWidth: 650, minHeight: 620)
        .sheet(isPresented: $showEditor) { PlanEditor(store: store, existing: editing) }
        .sheet(isPresented: $showSettings) { AppSettings(store: store, showClose: true) }
        .sheet(item: $historyPlan) { HistoryView(store: store, plan: $0, showLogInitially: historyStartsWithLog, initialSnapshotID: historySnapshotID) }
        .sheet(item: $archive) { ArchiveBrowser(store: store, destination: $0.url) }
        .alert(L10n.text("Please Check"), isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button(L10n.text("OK")) { store.error = nil }
        } message: { Text(L10n.message(store.error ?? "")) }
        .alert(L10n.text("Delete this backup plan?"), isPresented: Binding(get: { remove != nil }, set: { if !$0 { remove = nil } })) {
            Button(L10n.text("Cancel"), role: .cancel) { remove = nil }
            Button(L10n.text("Delete Plan"), role: .destructive) {
                if let remove { store.removePlan(id: remove.id) }
                remove = nil
            }
        } message: { Text(L10n.text("Only the plan and its schedule are removed. Saved backups stay and can be opened again with Open Existing Backup.")) }
        .sheet(isPresented: $showHelp) { help }
    }

    private var header: some View {
        HStack(spacing: 12) {
            BackupMark().frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text("Folder Backup").font(.system(size: 22, weight: .semibold))
                Text(L10n.text("Your folders. Simply backed up.")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { newPlan() } label: { Label(L10n.text("New Backup"), systemImage: "plus") }
                .buttonStyle(BackupButton()).disabled(store.maintenance)
            Button { showSettings = true } label: { Image(systemName: "gearshape").font(.system(size: 19)).frame(width: 30, height: 32) }
                .buttonStyle(.plain).accessibilityLabel(L10n.text("Open Backup Settings"))
            Button { showHelp = true } label: { Image(systemName: "questionmark.circle").font(.system(size: 20)).frame(width: 30, height: 32) }
                .buttonStyle(.plain).accessibilityLabel(L10n.text("Help"))
            Menu {
                Button(L10n.text("Open Existing Backup…")) { importArchive() }
                SettingsLink { Text(L10n.text("Settings…")) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 19, weight: .semibold)).frame(width: 24, height: 30)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel(L10n.text("App Menu"))
        }
        .foregroundStyle(BackupTheme.ink).padding(.horizontal, 24).frame(height: 88)
        .background(.white)
        .overlay(alignment: .bottom) { Rectangle().fill(BackupTheme.border).frame(height: 1) }
    }

    private var driveCard: some View {
        BackupCard {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.text("Backup Location")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Text(driveName).font(.system(size: 23, weight: .semibold))
                    Text(selected == nil ? L10n.text("Choose a folder to get started") : (selected?.destination.path ?? ""))
                        .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                    if let capacity = capacity {
                        Text(L10n.text("%@ free of %@", byteString(capacity.free), byteString(capacity.total)))
                            .font(.system(size: 15, weight: .medium)).foregroundStyle(BackupTheme.ink).padding(.top, 6)
                        ProgressView(value: Double(capacity.total - capacity.free), total: Double(max(1, capacity.total)))
                            .tint(BackupTheme.accent).frame(maxWidth: 440)
                    } else {
                        Text(selected == nil ? L10n.text("No backup location selected") : L10n.text("Check the destination connection"))
                            .font(.system(size: 15)).foregroundStyle(.secondary).padding(.top, 12)
                    }
                }
                Spacer(minLength: 24)
                Image(systemName: "externaldrive.fill").font(.system(size: 40, weight: .regular))
                    .foregroundStyle(BackupTheme.accent.opacity(0.7)).frame(width: 76, height: 76)
                    .background(BackupTheme.background).clipShape(RoundedRectangle(cornerRadius: 18)).accessibilityHidden(true)
            }
        }
    }

    private var emptyState: some View {
        BackupCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 18) {
                    Image(systemName: "folder.badge.plus").font(.system(size: 43, weight: .light)).foregroundStyle(BackupTheme.accent)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(L10n.text("Backup")).font(.system(size: 22, weight: .semibold))
                        Text(L10n.text("Keep your folders and earlier versions safe")).foregroundStyle(.secondary)
                    }
                }
                Text(L10n.text("Choose the folders you want to back up. Files you delete from the source remain in older backups."))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                HStack {
                    Button(L10n.text("Backup Settings")) { newPlan() }.buttonStyle(BackupButton())
                    Button(L10n.text("Open Existing Backup…")) { importArchive() }.buttonStyle(BackupButton(secondary: true))
                }
            }.padding(.vertical, 8)
        }
    }

    private func planCard(_ plan: BackupPlan) -> some View {
        BackupCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: "folder.fill").font(.system(size: 27)).foregroundStyle(BackupTheme.accent)
                        .frame(width: 48, height: 48).background(BackupTheme.background).clipShape(RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(plan.name).font(.system(size: 20, weight: .semibold))
                        Text(L10n.text("Folders: %@ · %@%@", plan.sources.count, plan.schedule.frequency.title, plan.paused ? L10n.text(" · Paused") : ""))
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { store.selectedID = plan.id; showSettings = true } label: {
                        Label(L10n.text("Schedule"), systemImage: "calendar")
                    }.buttonStyle(BackupButton(secondary: true)).accessibilityIdentifier("schedule-settings")
                    Menu {
                        Button(L10n.text("Schedule & Retention…")) { store.selectedID = plan.id; showSettings = true }
                        Button(L10n.text("Change Folders & Destination…")) { editing = plan; showEditor = true }.disabled(store.runningID == plan.id || store.maintenance)
                        Button(plan.paused ? L10n.text("Resume Schedule") : L10n.text("Pause Schedule")) { store.togglePause(plan) }
                        Button(L10n.text("Show Backup Location")) { reveal(plan) }
                        Button(L10n.text("Delete Plan…"), role: .destructive) { remove = plan }.disabled(store.runningID == plan.id || store.maintenance)
                    } label: { Image(systemName: "ellipsis").font(.system(size: 20)) }
                        .menuStyle(.borderlessButton).fixedSize()
                        .accessibilityLabel(L10n.text("Manage %@", plan.name))
                }
                ForEach(plan.sources, id: \.path) { folder in
                    Label(folder.path, systemImage: "folder").font(.system(size: 12)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(folder.path)
                }
                Text((plan.retention ?? BackupRetention()).title + L10n.text(" · Resume supported"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Divider()
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(plan.lastSuccess.map { L10n.text("Last backup  ") + L10n.date($0) } ?? L10n.text("No completed backup yet"))
                        if plan.paused { Text(L10n.text("Schedule is paused")) }
                        else if let next = store.nextRun(for: plan) {
                            Text(L10n.text("Next backup  ") + L10n.date(next))
                        } else { Text(L10n.text("Choose Back Up Now whenever you need it")) }
                    }.font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.text("Restore & History")) { historyStartsWithLog = false; historySnapshotID = nil; historyPlan = plan }.buttonStyle(BackupButton(secondary: true))
                        .disabled(store.runningID == plan.id || store.maintenance)
                    if store.runningID == plan.id {
                        Button(L10n.text("Stop")) { store.cancel() }.buttonStyle(BackupButton(secondary: true))
                    } else {
                        Button(plan.history.first?.outcome == .cancelled || plan.history.first?.outcome == .failure ? L10n.text("Resume Backup") : L10n.text("Back Up Now")) { store.run(plan) }
                            .buttonStyle(BackupButton()).disabled(store.runningID != nil || store.maintenance)
                    }
                }
                if store.runningID == plan.id {
                    if let progress = store.progress, progress.total > 0 {
                        ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total)))
                        Text(L10n.text("Items: %@ / %@ · Reused: %@ · Saved: %@ (%@) · Skipped: %@ · Retries: %@", progress.completed.formatted(.number.locale(L10n.locale)), progress.total.formatted(.number.locale(L10n.locale)), progress.resumedFiles.formatted(.number.locale(L10n.locale)), progress.copiedFiles.formatted(.number.locale(L10n.locale)), byteString(progress.copiedBytes), progress.skippedFiles.formatted(.number.locale(L10n.locale)), progress.retries.formatted(.number.locale(L10n.locale))))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    } else { ProgressView().controlSize(.small) }
                    Text(store.progress?.path ?? L10n.text("Scanning source folders…")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                if let note = plan.lastError ?? (plan.history.first?.outcome == .success ? plan.history.first?.message : nil), store.runningID != plan.id {
                    HStack(alignment: .top) {
                        Label(L10n.message(String(note.split(separator: "\n", maxSplits: 1).first ?? "")), systemImage: plan.lastError == nil ? "info.circle" : "exclamationmark.triangle")
                            .font(.system(size: 12)).foregroundStyle(plan.lastError == nil ? BackupTheme.ink.opacity(0.6) : .red).lineLimit(2)
                        Spacer()
                        Button(L10n.text("View Details")) { historyStartsWithLog = true; historySnapshotID = nil; historyPlan = plan }
                            .font(.system(size: 12)).buttonStyle(.plain).foregroundStyle(BackupTheme.accent)
                    }
                }
            }
        }.onTapGesture { store.selectedID = plan.id }
    }

    private var help: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.text("Using Folder Backup")).font(.title2.bold())
            Text(L10n.text("1. Choose your source folders and destination in Backup Settings.\n2. Set a schedule and run your first backup.\n3. In Restore & History, choose a date and the files to restore."))
            Text(L10n.text("Keep all versions, just the latest, or a set number of recent versions. Older backups move to the Trash only after a new backup succeeds. Resume checks files already copied. Restores always go into a new folder."))
            Text(L10n.text("Closing the window or quitting from the Dock keeps the app in the menu bar. Backups pause while the app is fully closed or your Mac is asleep. For access errors, check Files and Folders or Full Disk Access in System Settings > Privacy & Security."))
            HStack { Spacer(); Button(L10n.text("OK")) { showHelp = false }.buttonStyle(BackupButton()) }
        }.padding(30).frame(width: 540)
    }

    private var driveName: String {
        guard let plan = selected else { return L10n.text("Folder backup") }
        guard let url = try? plan.destination.resolve(), let values = try? url.resourceValues(forKeys: [.volumeNameKey]) else { return URL(fileURLWithPath: plan.destination.path).lastPathComponent }
        return values.volumeName ?? url.lastPathComponent
    }

    private var capacity: (free: Int64, total: Int64)? {
        guard let plan = selected, let url = try? plan.destination.resolve(),
              let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey]),
              let free = values.volumeAvailableCapacity, let total = values.volumeTotalCapacity else { return nil }
        return (Int64(free), Int64(total))
    }

    private func newPlan() { editing = nil; showEditor = true }
    private func reveal(_ plan: BackupPlan) {
        do { NSWorkspace.shared.open(try plan.destination.resolve()) }
        catch { store.error = error.localizedDescription }
    }

    private func importArchive() {
        guard let url = pickFolders(title: L10n.text("Choose the folder containing an existing backup")).first else { return }
        historyPlan = nil
        editing = nil
        archive = ArchiveLocation(url: url)
    }
}

private struct ArchiveLocation: Identifiable {
    let id = UUID()
    let url: URL
}
