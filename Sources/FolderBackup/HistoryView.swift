import SwiftUI
import AppKit
import BackupCore

struct HistoryView: View {
    @ObservedObject var store: BackupStore
    let plan: BackupPlan
    var showLogInitially = false
    var initialSnapshotID: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var snapshots: [BackupSnapshot] = []
    @State private var selected: String?
    @State private var files: [BackupFileEntry] = []
    @State private var selection: Set<String> = []
    @State private var query = ""
    @State private var busy = false
    @State private var loadingFiles = false
    @State private var message = ""
    @State private var error: String?
    @State private var trash: BackupSnapshot?
    @State private var showLog = false

    private var snapshot: BackupSnapshot? { snapshots.first { $0.id == selected } }
    private var visible: [BackupFileEntry] { files.filter { query.isEmpty || $0.path.localizedCaseInsensitiveContains(query) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text("Restore & History")).font(.system(size: 21, weight: .semibold))
                    Text(plan.name).font(.system(size: 12)).opacity(0.8)
                }
                Spacer()
                Button(showLog ? L10n.text("Backup Files") : L10n.text("Run History")) { showLog.toggle() }.buttonStyle(.plain)
                Button { dismiss() } label: { Image(systemName: "xmark").padding(8) }.buttonStyle(.plain).accessibilityLabel(L10n.text("Close"))
            }.foregroundStyle(.white).padding(22).background(BackupTheme.accent)
            if showLog { runLog }
            else {
                HSplitView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(L10n.text("Backup Date")).font(.system(size: 13, weight: .semibold)).padding(16)
                        List(snapshots, selection: $selected) { item in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(L10n.date(item.createdAt)).font(.system(size: 12, weight: .medium))
                                Text(L10n.text("Files: %@ · Total: %@", item.files, byteString(item.bytes))).font(.system(size: 11)).foregroundStyle(.secondary)
                                if let added = item.copiedBytes { Text(L10n.text("New contents: %@", byteString(added))).font(.system(size: 11)).foregroundStyle(.secondary) }
                                HStack {
                                    Button(L10n.text("Verify Version")) { store.verifyVersions(planID: plan.id, snapshotID: item.id) }
                                        .buttonStyle(.borderless).disabled(store.runningID != nil || store.maintenance)
                                        .accessibilityIdentifier("verify-version-" + item.id)
                                    Spacer()
                                }
                                VerificationStatusView(result: store.plans.first(where: { $0.id == plan.id })?.verificationResults?[item.id])
                            }.padding(.vertical, 7).tag(item.id)
                        }.listStyle(.sidebar)
                        Text(L10n.text("Versions: %@ · %@", snapshots.count, (plan.retention ?? BackupRetention()).title)).font(.system(size: 11)).foregroundStyle(.secondary).padding(15)
                    }.frame(minWidth: 210, idealWidth: 230, maxWidth: 270)
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField(L10n.text("Search Backup Files"), text: $query).textFieldStyle(.plain)
                        }.padding(9).background(.white).clipShape(RoundedRectangle(cornerRadius: 4))
                        if snapshots.isEmpty && !busy {
                            ContentUnavailableView(L10n.text("No completed backups"), systemImage: "clock.arrow.circlepath", description: Text(L10n.text("After your first backup, you can browse its files and earlier versions here.")))
                        } else if loadingFiles {
                            VStack(spacing: 12) {
                                ProgressView()
                                Text(L10n.text("Loading backup files…")).font(.system(size: 12)).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            Table(visible, selection: $selection) {
                                TableColumn(L10n.text("Files & Folders")) { file in
                                    Label(file.path, systemImage: file.kind == .directory ? "folder" : file.kind == .symbolicLink ? "link" : "doc")
                                        .font(.system(size: 12)).lineLimit(1).help(file.path)
                                }.width(min: 220)
                                TableColumn(L10n.text("Size")) { file in Text(file.kind == .file ? byteString(file.bytes) : "—").font(.system(size: 11)) }.width(70)
                            }
                        }
                        Text(selection.isEmpty ? L10n.text("Leave everything unselected to restore this entire backup.") : L10n.text("Selected: %@ · ⌘-click to select multiple items", selection.count))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }.padding(16).frame(minWidth: 400)
                }
            }
            Divider()
            VerificationProgressView(store: store, planID: plan.id).padding(.horizontal, 18)
            HStack {
                if busy || loadingFiles { ProgressView().controlSize(.small) }
                Text(L10n.message(message)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if !showLog {
                    Menu {
                        Button(L10n.text("Verify Version")) { if let selected { store.verifyVersions(planID: plan.id, snapshotID: selected) } }
                        Button(L10n.text("Show Backup Folder")) { reveal() }
                        Button(L10n.text("Move This Version to Trash…"), role: .destructive) { trash = snapshot }
                    } label: { Image(systemName: "ellipsis.circle").font(.system(size: 20)) }.menuStyle(.borderlessButton).fixedSize()
                        .disabled(snapshot == nil || busy || loadingFiles || store.runningID != nil || store.maintenance)
                    Menu {
                        Button(L10n.text("Restore to Another Location…")) { restore(besideOriginal: false) }
                        Button(L10n.text("Restore Beside Original (Keep Existing Files)")) { restore(besideOriginal: true) }
                    } label: {
                        Text(selection.isEmpty ? L10n.text("Restore All") : L10n.text("Restore Selected"))
                            .padding(.horizontal, 16).padding(.vertical, 10).foregroundStyle(.white).background(BackupTheme.accent).clipShape(RoundedRectangle(cornerRadius: 4))
                    }.menuStyle(.borderlessButton).fixedSize().disabled(snapshot == nil || busy || loadingFiles || store.runningID != nil || store.maintenance)
                }
            }.padding(18)
        }
        .frame(width: 830, height: 620).background(BackupTheme.background).tint(BackupTheme.accent)
        .interactiveDismissDisabled(busy)
        .task { showLog = showLogInitially; await load() }
        .task(id: showLog ? nil : selected) { if !showLog { await loadFiles() } }
        .disabled(busy)
        .alert(L10n.text("Please Check"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(L10n.text("OK")) { error = nil }
        } message: { Text(L10n.message(error ?? "")) }
        .alert(L10n.text("Move this backup version to the Trash?"), isPresented: Binding(get: { trash != nil }, set: { if !$0 { trash = nil } })) {
            Button(L10n.text("Cancel"), role: .cancel) { trash = nil }
            Button(L10n.text("Move to Trash"), role: .destructive) {
                if let trash { trashVersion(trash) }
                trash = nil
            }
        } message: {
            Text(L10n.text("Only this version is moved. Source files and other backup dates are kept. If the drive does not support the Trash, nothing is deleted and an error is shown."))
        }
    }

    private var runLog: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if plan.history.isEmpty { Text(L10n.text("No run history")).foregroundStyle(.secondary) }
                ForEach(plan.history) { run in
                    BackupCard {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Image(systemName: run.outcome == .success ? "checkmark.circle" : run.outcome == .cancelled ? "pause.circle" : "exclamationmark.triangle")
                                Text(run.outcome == .success ? L10n.text("Backup Complete") : run.outcome == .cancelled ? L10n.text("Backup Stopped") : L10n.text("Backup Failed")).fontWeight(.semibold)
                                Spacer()
                                Text(L10n.date(run.startedAt)).font(.caption)
                            }
                            if let message = run.message {
                                let parts = message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                                Text(L10n.message(String(parts.first ?? ""))).font(.callout).textSelection(.enabled)
                                if parts.count > 1 {
                                    DisclosureGroup(L10n.text("Show File Details")) {
                                        ScrollView {
                                            Text(L10n.message(String(parts[1]))).font(.system(size: 11, design: .monospaced))
                                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                        }.frame(height: 220)
                                    }.font(.callout)
                                }
                            }
                        }
                    }
                }
            }.padding(20)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @MainActor private func load() async {
        do {
            let destination = try plan.destination.resolve()
            let id = plan.id
            snapshots = try await Task.detached { try BackupEngine().snapshots(destination: destination, planID: id) }.value
            if let initialSnapshotID {
                selected = snapshots.first(where: { $0.id == initialSnapshotID })?.id
                if selected == nil { error = L10n.text("This saved backup could not be found. Refresh the list on the main screen.") }
            } else { selected = snapshots.first?.id }
            message = snapshots.isEmpty ? "" : L10n.text("Choose a backup date and files to restore.")
        } catch { self.error = error.localizedDescription }
    }

    @MainActor private func loadFiles() async {
        selection = []; files = []
        loadingFiles = false
        guard let id = selected else { return }
        loadingFiles = true
        defer { if !Task.isCancelled && selected == id { loadingFiles = false } }
        do {
            let destination = try plan.destination.resolve()
            let planID = plan.id
            let task = Task.detached {
                try BackupEngine().snapshotFiles(snapshotID: id, destination: destination, planID: planID, cancelled: { Task.isCancelled })
            }
            let result = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            if !Task.isCancelled && selected == id { files = result }
        } catch { if !Task.isCancelled && selected == id { self.error = error.localizedDescription } }
    }

    private func restore(besideOriginal: Bool) {
        guard let selected, !busy, store.runningID == nil else { return }
        let parent: URL?
        if besideOriginal { parent = nil }
        else {
            parent = pickFolders(title: L10n.text("Choose a restore location — files go into a new folder")).first
            guard parent != nil else { return }
        }
        operation(L10n.text("Verifying and restoring files…")) { destination in
            let engine = BackupEngine()
            if besideOriginal {
                return try engine.restoreBesideOriginal(snapshotID: selected, destination: destination, planID: plan.id, relativePaths: Array(selection))
            }
            return [try engine.restore(snapshotID: selected, destination: destination, planID: plan.id, to: parent!, relativePaths: Array(selection))]
        }
    }

    private func reveal() {
        guard let selected else { return }
        do { NSWorkspace.shared.open(try BackupEngine().snapshotURL(snapshotID: selected, destination: plan.destination.resolve(), planID: plan.id)) }
        catch { self.error = error.localizedDescription }
    }

    private func trashVersion(_ snapshot: BackupSnapshot) {
        guard store.runningID == nil else { return }
        operation(L10n.text("Moving backup version to the Trash…"), reload: true) { destination in
            try BackupEngine().trashSnapshot(snapshotID: snapshot.id, destination: destination, planID: plan.id)
            return []
        }
    }

    private func operation(_ label: String, reload: Bool = false, work: @escaping @Sendable (URL) throws -> [URL]) {
        guard !busy, store.runningID == nil, !store.maintenance else { return }
        busy = true; store.maintenance = true; message = label
        Task { @MainActor in
            defer { busy = false; store.maintenance = false }
            do {
                let destination = try plan.destination.resolve()
                let result = try await Task.detached { try work(destination) }.value
                message = result.isEmpty ? L10n.text("Done.") : L10n.text("Restore complete · Existing files were kept.")
                if !result.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(result) }
                if reload { await load() }
            } catch { self.error = error.localizedDescription; message = L10n.text("The operation could not finish.") }
        }
    }
}

struct ArchiveBrowser: View {
    @ObservedObject var store: BackupStore
    let destination: URL
    @Environment(\.dismiss) private var dismiss
    @State private var archives: [BackupPlan] = []
    @State private var plan: BackupPlan?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(L10n.text("Open Existing Backup")).font(.title2.bold())
                Spacer(); Button(L10n.text("Close")) { dismiss() }
            }
            Text(destination.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            if archives.isEmpty { Text(L10n.text("No backups found here. Choose the parent folder that contains “Toolkit Backups”.")).foregroundStyle(.secondary) }
            List(archives) { item in
                Button { plan = item } label: {
                    Label(item.name, systemImage: "externaldrive.badge.timemachine").padding(.vertical, 8)
                }.buttonStyle(.plain)
            }
        }.padding(24).frame(width: 580, height: 410)
        .sheet(item: $plan) { HistoryView(store: store, plan: $0) }
        .task {
            do {
                let folder = try FolderSelection(url: destination)
                let base = destination.appendingPathComponent("Toolkit Backups")
                let ids = try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil).compactMap { UUID(uuidString: $0.lastPathComponent) }
                for id in ids {
                    let snapshots = try BackupEngine().snapshots(destination: destination, planID: id)
                    guard let latest = snapshots.first else { continue }
                    let name = store.plans.first { $0.id == id }?.name ?? L10n.text("Backup · ") + L10n.date(latest.createdAt) + " · " + String(id.uuidString.prefix(8))
                    archives.append(store.plans.first { $0.id == id } ?? BackupPlan(id: id, name: name, sources: [], destination: folder))
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}
