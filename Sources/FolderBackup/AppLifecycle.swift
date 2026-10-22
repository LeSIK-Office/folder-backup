import AppKit
import CoreServices

@MainActor
final class AppLifecycle: NSObject, NSApplicationDelegate {
    var allowTermination = false

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        sender.setActivationPolicy(.regular)
        return true
    }

    func shouldTerminate(reason: OSType?) -> Bool {
        allowTermination || [kAEQuitAll, kAEShutDown, kAERestart, kAEReallyLogOut].contains { reason == OSType($0) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let reason = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue
        if shouldTerminate(reason: reason) { return .terminateNow }
        background(sender)
        return .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        background(sender)
        return false
    }

    private func background(_ app: NSApplication) {
        for window in app.windows where window.level != .statusBar { window.orderOut(nil) }
        app.setActivationPolicy(.accessory)
    }
}
