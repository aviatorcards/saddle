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
        }
        .menuBarExtraStyle(.window)

        Window("Connections", id: ConnectionsView.windowID) {
            ConnectionsView()
                .environment(model)
        }
        .defaultSize(width: 760, height: 520)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environment(model)
        }
        .defaultSize(width: 560, height: 440)
        .windowResizability(.contentSize)
    }
}
