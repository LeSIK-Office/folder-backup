import SwiftUI
import AppKit
import BackupCore
import ServiceManagement

struct AppSettings: View {
    @ObservedObject var store: BackupStore
    var showClose = false
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?
    @State private var section = 0
    @State private var schedule = BackupSchedule()
    @State private var retention = BackupRetention()
    @State private var exclusions = ""
    @State private var paused = false
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var message = ""
    @State private var error: String?
    @State private var editing: BackupPlan?
    @State private var incomplete = 0
    @State private var confirmCleanup = false
    @State private var cleaning = false
    private var plan: BackupPlan? { store.plans.first { $0.id == selectedID } }
    private var scheduleLocked: Bool { cleaning || store.maintenance }
    private var locked: Bool { scheduleLocked || (selectedID != nil && store.runningID == selectedID) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.text("Backup Settings")).font(.system(size: 21, weight: .semibold))
                Spacer()
                if showClose { Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel(L10n.text("Close Settings")) }
            }.foregroundStyle(BackupTheme.ink).padding(22).background(.white)
            if !store.plans.isEmpty {
                HStack {
                    Picker(L10n.text("Backup Plan"), selection: $selectedID) {
                        ForEach(store.plans) { Text($0.name).tag(Optional($0.id)) }
                    }.frame(maxWidth: 400)
                    Spacer()
                    if locked { Label(L10n.text("You can change the schedule during a backup. Stop the backup before changing folders or retention."), systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
                }.padding(.horizontal, 24).padding(.vertical, 16)
            }
            HStack(spacing: 6) {
                ForEach(Array([(L10n.text("Schedule"), "calendar"), (L10n.text("Retention & Resume"), "clock.arrow.circlepath"), (L10n.text("Folders & Exclusions"), "folder"), (L10n.text("App"), "gearshape")].enumerated()), id: \.offset) { index, item in
                    Button { section = index } label: {
                        Label(item.0, systemImage: item.1).font(.system(size: 13, weight: section == index ? .semibold : .regular))
                            .padding(.horizontal, 16).padding(.vertical, 10).frame(maxWidth: .infinity)
                            .background(section == index ? Color.white : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain).accessibilityValue(section == index ? L10n.text("Selected") : "")
                }
            }.padding(.horizontal, 24).padding(.vertical, 8)
            Group {
                if section == 0 {
                settingsPage {
                    if plan != nil {
                        BackupCard {
                            VStack(alignment: .leading, spacing: 20) {
                                Toggle(L10n.text("Scheduled Backups"), isOn: Binding(get: { !paused }, set: { paused = !$0 }))
                                    .accessibilityIdentifier("schedule-enabled")
                                ScheduleControls(schedule: $schedule, enabled: !paused).id(store.language)
                                Text(L10n.text("Turning off the schedule does not stop a running backup. Changes apply to the next scheduled run."))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.disabled(scheduleLocked)
                    } else { noPlan }
                }
                } else if section == 1 {
                settingsPage {
                    if plan != nil {
                        BackupCard { RetentionControls(retention: $retention).id(store.language) }.disabled(locked)
                        BackupCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(L10n.text("Interrupted backups: %@", incomplete)).font(.headline)
                                Text(L10n.text("The next run checks and reuses these copied files. Clean them up only if you no longer need them or are changing folders.")).font(.callout).foregroundStyle(.secondary)
                                Button(L10n.text("Clean Up Interrupted Backups…")) { confirmCleanup = true }
                                    .disabled(incomplete == 0 || store.runningID != nil || store.maintenance || cleaning)
                            }
                        }
                    } else { noPlan }
                }
                } else if section == 2 {
                settingsPage {
                    if let plan {
                        BackupCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(L10n.text("Source Folders")).font(.headline)
                                ForEach(plan.sources) { Label($0.path, systemImage: "folder").font(.callout).textSelection(.enabled) }
                                Divider()
                                Text(L10n.text("Backup Location")).font(.headline)
                                Label(plan.destination.path, systemImage: "externaldrive").font(.callout).textSelection(.enabled)
                                Button(L10n.text("Change Folders & Destination…")) { editing = plan }.disabled(locked)
                            }
                        }
                        BackupCard {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text(L10n.text("Excluded Files & Folders")).font(.headline)
                                    Spacer()
                                    Button(L10n.text("Add Development Caches")) { addDevelopmentExclusions() }
                                }
                                Text(L10n.text("Enter one name or pattern per line. Leave this empty to include everything. Development caches: .DS_Store, node_modules, .build, .next, .turbo"))
                                    .font(.caption).foregroundStyle(.secondary)
                                TextEditor(text: $exclusions).font(.system(size: 12, design: .monospaced)).frame(height: 90)
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(BackupTheme.border))
                            }
                        }.disabled(locked)
                    } else { noPlan }
                }
                } else {
                settingsPage {
                    BackupCard {
                        VStack(alignment: .leading, spacing: 18) {
                            Picker(L10n.text("Language"), selection: $store.language) {
                                ForEach(AppLanguage.allCases, id: \.self) { Text($0.name).tag($0) }
                            }.id(store.language).frame(maxWidth: 410).accessibilityIdentifier("app-language")
                            Text(L10n.text("System Language follows your Mac’s primary language and uses English for unsupported languages. Interface text changes immediately; reopen the app to update macOS menus and dialogs."))
                                .font(.callout).foregroundStyle(.secondary)
                            Divider()
                            Toggle(L10n.text("Open Folder Backup at Login"), isOn: $login)
                                .onChange(of: login) { _, value in
                                    do {
                                        if value { try SMAppService.mainApp.register() }
                                        else { try SMAppService.mainApp.unregister() }
                                    } catch {
                                        self.error = error.localizedDescription
                                        login = SMAppService.mainApp.status == .enabled
                                    }
                                }
                            Text(L10n.text("Closing the window or quitting from the Dock keeps backups running in the menu bar. Choose Quit Completely to stop the app and scheduled backups. Manage login items in System Settings > General > Login Items."))
                                .font(.callout).foregroundStyle(.secondary)
                            Text(L10n.text("Source files are only read and copied. Files deleted from the source can still be restored from older backups.")).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                }
            }.padding(.horizontal, 20).padding(.bottom, 8)
            Divider()
            HStack {
                Text(L10n.message(message)).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("Save Changes")) { save() }.buttonStyle(BackupButton()).disabled(plan == nil || (section == 0 ? scheduleLocked : locked))
            }.padding(20)
        }
        .frame(width: 780, height: 650).background(BackupTheme.background).tint(BackupTheme.accent)
        .foregroundStyle(BackupTheme.ink).preferredColorScheme(.light)
        .onAppear { selectedID = store.selectedID ?? store.plans.first?.id; reload() }
        .onChange(of: selectedID) { _, _ in reload() }
        .sheet(item: $editing, onDismiss: { reload() }) { PlanEditor(store: store, existing: $0) }
        .task(id: selectedID) { await loadIncomplete() }
        .alert(L10n.text("Check Settings"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(L10n.text("OK")) { error = nil }
        } message: { Text(L10n.message(error ?? "")) }
        .alert(L10n.text("Clean up interrupted backups?"), isPresented: $confirmCleanup) {
            Button(L10n.text("Cancel"), role: .cancel) { }
            Button(L10n.text("Move to Trash"), role: .destructive) { cleanup() }
        } message: { Text(L10n.text("This moves interrupted backups for this plan to the Trash (%@). Completed backups and source files stay safe. These copies will no longer be available to resume.", incomplete)) }
    }

    private func settingsPage<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView { VStack(spacing: 14) { content() }.padding(16).frame(maxWidth: .infinity, alignment: .leading) }
    }
    private var noPlan: some View {
        ContentUnavailableView(L10n.text("Create a backup plan first"), systemImage: "folder.badge.plus", description: Text(L10n.text("Choose your folders and destination in Backup Settings on the main screen.")))
    }
    private func reload() {
        guard let plan else { return }
        schedule = plan.schedule; retention = plan.retention ?? BackupRetention()
        exclusions = plan.exclusions.joined(separator: "\n"); paused = plan.paused; message = ""
    }
    private func save() {
        guard var plan else { return }
        plan.schedule = schedule; plan.retention = retention; plan.paused = paused
        plan.exclusions = exclusions.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if section == 0 { store.saveSchedule(id: plan.id, schedule: schedule, paused: paused) }
        else { store.savePlan(plan) }
        if let failure = store.error { error = failure; store.error = nil }
        else if section == 0 { message = paused ? L10n.text("Scheduled backups are off. You can still back up manually.") : L10n.text("Schedule saved. Changes apply to the next scheduled run.") }
        else { message = L10n.text("Saved. Retention changes apply after the next successful backup.") }
    }
    private func addDevelopmentExclusions() {
        var values = exclusions.split(separator: "\n").map(String.init)
        for value in [".DS_Store", "node_modules", ".build", ".next", ".turbo"] where !values.contains(value) { values.append(value) }
        exclusions = values.joined(separator: "\n")
    }
    @MainActor private func loadIncomplete() async {
        guard let plan else { incomplete = 0; return }
        do {
            let destination = try plan.destination.resolve()
            let count = try await Task.detached { try BackupEngine().incompleteBackups(destination: destination, planID: plan.id).count }.value
            if selectedID == plan.id { incomplete = count }
        } catch { message = L10n.text("Checking interrupted backups: ") + error.localizedDescription }
    }
    private func cleanup() {
        guard let plan, store.runningID == nil, !store.maintenance else { return }
        cleaning = true; store.maintenance = true
        Task { @MainActor in
            defer { cleaning = false; store.maintenance = false }
            do {
                let destination = try plan.destination.resolve()
                let count = try await Task.detached { try BackupEngine().trashIncompleteBackups(destination: destination, planID: plan.id) }.value
                message = L10n.text("Moved interrupted backups to the Trash: %@", count)
                await loadIncomplete()
            } catch { self.error = error.localizedDescription }
        }
    }
}
