import AppKit
import SwiftUI

/// Hosts `SettingsView` in a plain NSWindow. A menu-bar-only (LSUIElement) app can't rely on
/// SwiftUI's Settings scene coming to the front, so the window is managed by hand.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "64Voice"
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        // A Dock icon while Settings is open makes it reachable with ⌘Tab, which matters while
        // bouncing to System Settings to grant permissions. Menu-bar apps can't force themselves
        // in front of the active app, so also order the window front regardless.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func windowWillClose(_: Notification) {
        NSApp.setActivationPolicy(.accessory)
        PermissionsManager.shared.refresh()
        AppState.shared.permissionsMayHaveChanged()
    }
}
