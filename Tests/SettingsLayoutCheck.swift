import AppKit
import SwiftUI
import BackupCore

@main
struct SettingsLayoutCheck {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderToolkit-SettingsLayout-" + UUID().uuidString)
        let source = root.appendingPathComponent("Source")
        let destination = root.appendingPathComponent("Destination")
        for folder in [source, destination] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let store = BackupStore(storageURL: root.appendingPathComponent("settings.json"), startScheduler: false)
        let plan = BackupPlan(name: "화면 검증용 백업", sources: [try FolderSelection(url: source)], destination: try FolderSelection(url: destination), schedule: BackupSchedule(frequency: .weekly, hour: 20, minute: 30, weekday: 2), retention: BackupRetention(mode: .recent, count: 4))
        store.plans = [plan]; store.selectedID = plan.id
        func render<V: View>(_ view: V, name: String, width: CGFloat, height: CGFloat) throws {
            let host = NSHostingView(rootView: view.frame(width: width, height: height).preferredColorScheme(.light))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: width, height: height)
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { preconditionFailure("No view bitmap") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { preconditionFailure("No rendered PNG") }
            try data.write(to: URL(fileURLWithPath: "Evidence/" + name + ".png"))
            precondition(host.bounds.width == width && host.bounds.height == height)
            print("Rendered \(name): \(bitmap.pixelsWide) × \(bitmap.pixelsHigh)")
        }
        try render(AppSettings(store: store, showClose: true), name: "settings-layout", width: 780, height: 650)
        try render(BackupCard { ScheduleControls(schedule: .constant(plan.schedule)) }.padding(20).background(BackupTheme.background), name: "settings-weekly-schedule", width: 680, height: 380)
        try render(BackupCard { RetentionControls(retention: .constant(plan.retention!)) }.padding(20).background(BackupTheme.background), name: "settings-retention", width: 680, height: 450)
        print("Settings layout check PASS: own-process view rendering only; no live-window clicks")
    }
}
