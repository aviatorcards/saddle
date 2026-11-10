import AppKit

/// Saddle is a menu bar app, so it is never the frontmost app when its menu is clicked.
/// `NSApp.activate()` is only a request on current macOS and is declined in that case,
/// which leaves new windows and alerts behind whatever app was in front.
enum WindowActivation {
    /// Puts a window that SwiftUI is opening above other apps' windows. Clicking it then
    /// activates Saddle normally.
    static func bringToFront(windowTitled title: String) {
        NSApp.activate()
        Task {
            // `openWindow` may create the window on a later run loop turn.
            for _ in 0..<20 {
                if let window = NSApp.windows.first(where: { $0.title == title && $0.canBecomeKey }) {
                    window.orderFrontRegardless()
                    window.makeKey()
                    return
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
    }

    /// Brings the Settings window to the front regardless of which application is active.
    static func bringSettingsToFront() {
        NSApp.activate()
        Task {
            for _ in 0..<20 {
                if let window = NSApp.windows.first(where: {
                    ($0.title == "Settings" || $0.title == "Saddle Settings" || $0.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true) && $0.canBecomeKey
                }) {
                    window.orderFrontRegardless()
                    window.makeKey()
                    return
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
    }

    /// Raises a modal alert above other apps before `runModal` shows it.
    static func prepare(_ alert: NSAlert) {
        NSApp.activate()
        alert.window.level = .floating
    }
}
