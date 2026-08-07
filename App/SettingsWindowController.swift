import AppKit
import SwiftUI

/// Hosts the SwiftUI settings form. The app is normally an accessory (no dock
/// icon); it becomes a regular app only while this window is open so the window
/// can take focus properly.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    convenience init(rootView: some View) {
        let hosting = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Keep Mac Awake Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.delegate = self
    }

    func present() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
