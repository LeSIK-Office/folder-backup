import AppKit
import CoreServices

@main enum AppLifecycleCheck {
    @MainActor static func main() {
        let lifecycle = AppLifecycle()
        let app = NSApplication.shared
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder Backup")
        let statusWindow = statusItem.button!.window!
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.orderFront(nil)
        precondition(statusWindow.isVisible && window.isVisible)
        precondition(lifecycle.applicationShouldTerminate(app) == .terminateCancel)
        precondition(statusWindow.isVisible && !window.isVisible)
        precondition(!lifecycle.applicationShouldTerminateAfterLastWindowClosed(app))
        precondition(statusWindow.isVisible)
        NSStatusBar.system.removeStatusItem(statusItem)
        app.setActivationPolicy(.accessory)
        precondition(lifecycle.applicationShouldHandleReopen(app, hasVisibleWindows: false))
        precondition(app.activationPolicy() == .regular)
        precondition(!lifecycle.shouldTerminate(reason: nil))
        for reason in [kAEQuitAll, kAEShutDown, kAERestart, kAEReallyLogOut] {
            precondition(lifecycle.shouldTerminate(reason: OSType(reason)))
        }
        precondition(!lifecycle.shouldTerminate(reason: OSType(kAEQuitApplication)))
        lifecycle.allowTermination = true
        precondition(lifecycle.shouldTerminate(reason: nil))
        print("App lifecycle check PASS: background preserves the status icon and hides normal windows; reopen restores Dock policy; explicit quit and system shutdown/logout are allowed")
    }
}
