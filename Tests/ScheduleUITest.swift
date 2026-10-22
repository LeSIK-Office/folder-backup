import SwiftUI
import AppKit

@main
struct ScheduleUITest: App {
    @StateObject private var store: BackupStore
    init() {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/schedule-ui-fixture")
        let source = root.appendingPathComponent("Source")
        let destination = root.appendingPathComponent("Destination")
        try! FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let store = BackupStore(storageURL: root.appendingPathComponent("plans.json"), startScheduler: false)
        if store.plans.isEmpty {
            store.savePlan(BackupPlan(name: "예약 클릭 검증", sources: [try! FolderSelection(url: source)], destination: try! FolderSelection(url: destination), paused: true))
        }
        store.runningID = store.plans[0].id
        store.status = "테스트 · 백업 진행 상태에서 예약 설정 검증"
        _store = StateObject(wrappedValue: store)
    }
    var body: some Scene {
        Window("예약 설정 검증", id: "test") {
            ContentView(store: store).preferredColorScheme(.light)
        }.defaultSize(width: 820, height: 740)
    }
}
