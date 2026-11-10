import AppKit
import SwiftUI

/// Saddle is a menu bar app, so it is never the frontmost app when its menu is clicked.
/// `NSApp.activate()` is only a request on current macOS and is declined in that case,
/// which leaves new windows and alerts behind whatever app was in front.
enum WindowActivation {
    /// Opens the Settings window. `openSettings` cannot do this while the app is an
    /// LSUIElement accessory: the `Settings` scene is attached to a main menu that
    /// does not exist, and `showSettingsWindow:` is unsupported on macOS 14 and later.
    static func openSettings(using openWindow: OpenWindowAction) {
        openWindow(id: SettingsView.windowID)
        bringToFront(windowTitled: "Settings")
    }

    /// Puts a window that SwiftUI is opening above other apps' windows. Clicking it then
    /// activates Saddle normally.
    static func bringToFront(windowTitled title: String) {
        NSApp.activate()
        Task {
            // `openWindow` may create the window on a later run loop turn.
            for _ in 0..<20 {
                if let window = NSApp.windows.first(where: { $0.title == title && $0.canBecomeKey }) {
                    moveOnScreenIfNeeded(window)
                    window.orderFrontRegardless()
                    window.makeKey()
                    return
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
    }

    /// A restored window frame can sit off the current display. Leave a window that is
    /// already visible, or still being given its size, where SwiftUI put it.
    private static func moveOnScreenIfNeeded(_ window: NSWindow) {
        let frame = window.frame
        guard frame.width > 50, frame.height > 50 else { return }
        guard let screen = window.screen ?? NSScreen.main else {
            window.center()
            return
        }
        if !screen.visibleFrame.intersects(frame) {
            window.center()
        }
    }

    /// Raises a modal alert above other apps before `runModal` shows it.
    static func prepare(_ alert: NSAlert) {
        NSApp.activate()
        alert.window.level = .floating
    }
}
