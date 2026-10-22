import SwiftUI
import BackupCore

struct PlanEditor: View {
    @ObservedObject var store: BackupStore
    let existing: BackupPlan?
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var name = L10n.text("My Folder Backup")
    @State private var sources: [FolderSelection] = []
    @State private var destination: FolderSelection?
    @State private var schedule = BackupSchedule()
    @State private var exclusions = ""
    @State private var retention = BackupRetention()
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(existing == nil ? L10n.text("Backup Settings") : L10n.text("Edit Backup Plan")).font(.system(size: 21, weight: .semibold))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel(L10n.text("Close"))
            }.foregroundStyle(BackupTheme.ink).padding(24).background(.white)
            HStack {
                ForEach(Array([L10n.text("Choose Folders"), L10n.text("Destination"), L10n.text("Schedule"), L10n.text("Retention")].enumerated()), id: \.offset) { index, title in
                    HStack(spacing: 8) {
                        Text("\(index + 1)").font(.system(size: 12, weight: .bold)).frame(width: 24, height: 24)
                            .foregroundStyle(step == index ? .white : BackupTheme.accent)
                            .background(step == index ? BackupTheme.accent : .white).clipShape(Circle())
                        Text(title).font(.system(size: 13, weight: step == index ? .semibold : .regular))
                        if index < 3 { Image(systemName: "chevron.right").foregroundStyle(.tertiary).padding(.horizontal, 10) }
                    }
                }
            }.padding(22)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if step == 0 { sourceStep }
                    else if step == 1 { destinationStep }
                    else if step == 2 { scheduleStep }
                    else { retentionStep }
                    if let error { Label(L10n.message(error), systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout) }
                }.padding(26).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button(L10n.text("Cancel")) { dismiss() }.buttonStyle(BackupButton(secondary: true))
                Spacer()
                if step > 0 { Button(L10n.text("Back")) { step -= 1; error = nil }.buttonStyle(BackupButton(secondary: true)) }
                Button(step == 3 ? (existing == nil ? L10n.text("Save & Start Backup") : L10n.text("Save Changes")) : L10n.text("Next")) { advance() }
                    .buttonStyle(BackupButton()).keyboardShortcut(.defaultAction)
            }.padding(22)
        }
        .foregroundStyle(BackupTheme.ink).background(BackupTheme.background).tint(BackupTheme.accent)
        .frame(width: 680, height: 660)
        .onAppear {
            if let existing {
                name = existing.name; sources = existing.sources; destination = existing.destination
                schedule = existing.schedule; exclusions = existing.exclusions.joined(separator: "\n")
                retention = existing.retention ?? BackupRetention()
            }
        }
    }

    private var sourceStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.text("What would you like to back up?")).font(.system(size: 22, weight: .semibold))
            TextField(L10n.text("Backup Name"), text: $name).textFieldStyle(.roundedBorder)
            Text(L10n.text("Backs up each selected folder and everything inside, including hidden files and empty folders."))
                .font(.callout).foregroundStyle(.secondary)
            BackupCard {
                VStack(alignment: .leading, spacing: 12) {
                    if sources.isEmpty { Text(L10n.text("No folders selected")).foregroundStyle(.secondary) }
                    ForEach(sources) { folder in
                        HStack {
                            Image(systemName: "folder.fill").foregroundStyle(BackupTheme.accent)
                            Text(folder.path).font(.system(size: 12)).lineLimit(2).textSelection(.enabled)
                            Spacer()
                            Button { sources.removeAll { $0.id == folder.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain).accessibilityLabel(L10n.text("Deselect %@", folder.path))
                        }
                    }
                    Button(L10n.text("Add Folder…")) {
                        do {
                            for url in pickFolders(title: L10n.text("Choose Folders to Back Up"), multiple: true) where !sources.contains(where: { $0.path == url.path }) {
                                sources.append(try FolderSelection(url: url))
                            }
                        } catch { self.error = error.localizedDescription }
                    }.buttonStyle(BackupButton(secondary: true))
                }
            }
        }
    }

    private var destinationStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L10n.text("Where should your backups go?")).font(.system(size: 22, weight: .semibold))
            Text(L10n.text("Choose a folder on an external drive. Using a different drive keeps your backup available if the source disk fails."))
                .font(.callout).foregroundStyle(.secondary)
            BackupCard {
                HStack(spacing: 18) {
                    Image(systemName: "externaldrive.fill").font(.system(size: 40)).foregroundStyle(.gray)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(destination.map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? L10n.text("Choose Destination"))
                            .font(.system(size: 17, weight: .semibold))
                        Text(destination?.path ?? L10n.text("Not selected yet")).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                        Button(L10n.text("Choose Backup Folder…")) {
                            guard let url = pickFolders(title: L10n.text("Choose the Backup Destination Folder")).first else { return }
                            do { destination = try FolderSelection(url: url); error = nil }
                            catch { self.error = error.localizedDescription }
                        }.buttonStyle(BackupButton(secondary: true))
                    }
                }
            }
            Text(L10n.text("Dated backups and shared file contents are stored here. The destination cannot be inside a source folder or contain one."))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var scheduleStep: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text(L10n.text("When should backups run?")).font(.system(size: 22, weight: .semibold))
            BackupCard { ScheduleControls(schedule: $schedule).id(store.language) }
            DisclosureGroup(L10n.text("Files or Folders to Exclude (Optional)")) {
                Text(L10n.text("Enter one pattern per line, such as *.tmp, .git, or node_modules. Leave empty to include everything."))
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                TextEditor(text: $exclusions).font(.system(size: 12, design: .monospaced)).frame(height: 65)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(BackupTheme.border))
            }
        }
    }

    private var retentionStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.text("How many versions would you like to keep?")).font(.system(size: 22, weight: .semibold))
            BackupCard { RetentionControls(retention: $retention).id(store.language) }
        }
    }

    private func advance() {
        error = nil
        if step == 0 {
            guard !sources.isEmpty, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = L10n.text("Enter a backup name and choose a folder."); return }
            for (i, a) in sources.enumerated() {
                for b in sources.dropFirst(i + 1) {
                    let first = URL(fileURLWithPath: a.path).resolvingSymlinksInPath().path
                    let second = URL(fileURLWithPath: b.path).resolvingSymlinksInPath().path
                    if first == second || first.hasPrefix(second + "/") || second.hasPrefix(first + "/") {
                        error = L10n.text("Choose only one folder when folders contain one another."); return
                    }
                }
            }
            step = 1
        } else if step == 1 {
            guard let destination else { error = L10n.text("Choose a backup destination."); return }
            do {
                let target = try destination.resolve().resolvingSymlinksInPath().path
                for source in sources {
                    let path = try source.resolve().resolvingSymlinksInPath().path
                    guard path != target, !path.hasPrefix(target + "/"), !target.hasPrefix(path + "/") else {
                        error = L10n.text("Source and destination folders cannot contain one another."); return
                    }
                }
                step = 2
            } catch { self.error = error.localizedDescription }
        } else if step == 2 {
            step = 3
        } else {
            guard let destination else { return }
            var plan = existing ?? BackupPlan(name: name, sources: sources, destination: destination)
            plan.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            plan.sources = sources; plan.destination = destination; plan.schedule = schedule; plan.retention = retention
            plan.exclusions = exclusions.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            store.savePlan(plan)
            guard store.error == nil else { error = store.error; store.error = nil; return }
            if existing == nil { store.run(plan) }
            dismiss()
        }
    }
}
