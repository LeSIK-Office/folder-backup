import SwiftUI
import AppKit
import BackupCore

@main
struct FolderBackupApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
    @StateObject private var store = BackupStore()

    init() { L10n.prepareNativeLanguage() }

    var body: some Scene {
        Window("Folder Backup", id: "main") {
            ContentView(store: store)
                .environment(\.locale, L10n.locale)
                .preferredColorScheme(.light)
        }
        .defaultSize(width: 820, height: 740)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .appTermination) {
                Button(L10n.text("Keep in Menu Bar")) { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
        }
        MenuBarExtra("Folder Backup", systemImage: "folder") {
            MenuContent(store: store, lifecycle: lifecycle).environment(\.locale, L10n.locale)
        }
        Settings { AppSettings(store: store).environment(\.locale, L10n.locale) }
    }
}

private struct MenuContent: View {
    @ObservedObject var store: BackupStore
    let lifecycle: AppLifecycle
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(L10n.message(store.status))
        Button(L10n.text("Open Folder Backup")) {
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        ForEach(store.plans) { plan in
            Button(L10n.text("Back Up %@ Now", plan.name)) { store.run(plan) }
                .disabled(store.runningID != nil || store.maintenance)
        }
        SettingsLink { Text(L10n.text("Settings…")) }
        Divider()
        Button(L10n.text("Quit Completely…")) {
            let alert = NSAlert()
            alert.messageText = L10n.text("Quit Folder Backup?")
            alert.informativeText = L10n.text("Quitting completely stops active and scheduled backups. Closing the window or quitting from the Dock keeps the app running in the menu bar.")
            alert.addButton(withTitle: L10n.text("Quit Completely"))
            alert.addButton(withTitle: L10n.text("Cancel"))
            if alert.runModal() == .alertFirstButtonReturn {
                store.cancel()
                lifecycle.allowTermination = true
                NSApp.terminate(nil)
            }
        }
    }
}
