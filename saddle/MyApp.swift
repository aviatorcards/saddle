import SwiftUI

@main struct MyApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environment(model)
        } label: {
            Image(model.isSyncing ? "MenuBarIconSyncing" : "MenuBarIcon")
                .accessibilityLabel("Saddle")
                .modifier(OpenSettingsOnLaunch())
        }
        .menuBarExtraStyle(.window)

        Window("Connections", id: ConnectionsView.windowID) {
            ConnectionsView()
                .environment(model)
        }
        .defaultSize(width: 760, height: 520)
        .windowResizability(.contentMinSize)

        // The SwiftUI `Settings` scene never opens in this app. Saddle is an
        // LSUIElement accessory, so it has no main menu for that scene to attach
        // to, and `openSettings` from the menu bar extra is a no-op. A normal
        // window, opened the same way as Connections, does not need that menu.
        Window("Settings", id: SettingsView.windowID) {
            SettingsView()
                .environment(model)
        }
        .defaultSize(width: 560, height: 440)
        .defaultPosition(.center)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                SettingsCommand()
            }
        }
    }
}

/// `-SaddleOpenSettingsOnLaunch YES` opens Settings after launch. Normal launches ignore it.
private struct OpenSettingsOnLaunch: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @State private var didOpen = false

    func body(content: Content) -> some View {
        content.onAppear {
            guard !didOpen, Self.requested else { return }
            didOpen = true
            let openWindow = openWindow
            // The status item can appear before the Settings window scene is connected.
            Task { @MainActor in
                WindowActivation.openSettings(using: openWindow)
            }
        }
    }

    private static var requested: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-SaddleOpenSettingsOnLaunch"),
              index + 1 < arguments.count else { return false }
        return ["YES", "yes", "1", "true"].contains(arguments[index + 1])
    }
}

private struct SettingsCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") {
            WindowActivation.openSettings(using: openWindow)
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}
