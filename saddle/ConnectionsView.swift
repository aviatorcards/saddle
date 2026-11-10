import SwiftUI
import UniformTypeIdentifiers

/// The "Connections" window: saved servers on the left, an editor on the right.
struct ConnectionsView: View {
    static let windowID = "connections"

    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var selection: UUID?
    @State private var isImportingConfig = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(model.profiles) { profile in
                    VStack(alignment: .leading) {
                        Text(profile.displayName)
                        Text("\(profile.username)@\(profile.host)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(profile.id)
                    .contextMenu {
                        Button("Settings…", action: showSettings)
                        Divider()
                        Button("Delete", role: .destructive) {
                            Task { await model.delete(profile) }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .toolbar {
                ToolbarItemGroup {
                    Button("Add Connection", systemImage: "plus", action: addProfile)
                    Menu("More", systemImage: "ellipsis.circle") {
                        Button("Import from SSH Config…") { isImportingConfig = true }
                        Divider()
                        Button("Settings…", action: showSettings)
                            .keyboardShortcut(",", modifiers: .command)
                        Divider()
                        Button("Delete Connection", role: .destructive, action: deleteSelected)
                            .disabled(selection == nil)
                    }
                }
            }
        } detail: {
            if let selection, let profile = model.profile(withID: selection) {
                ProfileEditorView(profile: profile)
                    .id(profile.id)
            } else {
                ContentUnavailableView {
                    Label("No Connection Selected", systemImage: "externaldrive.connected.to.line.below")
                } description: {
                    Text("Add an SFTP server to mount it in Finder.")
                } actions: {
                    Button("Add Connection", action: addProfile)
                }
            }
        }
        .fileImporter(isPresented: $isImportingConfig, allowedContentTypes: [.item]) { result in
            importConfig(result)
        }
        .fileDialogMessage("Choose your SSH config file. Press ⇧⌘. to show hidden folders such as ~/.ssh.")
        .onAppear {
            if selection == nil { selection = model.profiles.first?.id }
            // Saddle lives in the menu bar (LSUIElement). While this window is open, act like
            // a regular app so it appears in the Dock and Command-Tab.
            NSApp.setActivationPolicy(.regular)
        }
        .onDisappear {
            let otherOpenWindows = NSApp.windows.filter { $0.isVisible && $0.canBecomeKey }
            if otherOpenWindows.count <= 1 {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    private func addProfile() {
        var profile = ConnectionProfile()
        profile.name = "New Server"
        profile.port = model.settings.defaultPort
        profile.username = model.settings.defaultUsername.isEmpty ? NSUserName() : model.settings.defaultUsername
        profile.remotePath = model.settings.defaultRemotePath
        profile.maxConnections = model.settings.defaultParallelTransfers
        profile.refreshInterval = model.settings.defaultRefreshInterval
        profile.showHiddenFiles = model.settings.defaultShowHiddenFiles
        model.save(profile)
        selection = profile.id
    }

    private func showSettings() {
        NSApp.setActivationPolicy(.regular)
        openSettings()
        WindowActivation.bringSettingsToFront()
    }

    private func deleteSelected() {
        guard let selection, let profile = model.profile(withID: selection) else { return }
        self.selection = nil
        Task { await model.delete(profile) }
    }

    private func importConfig(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let profiles = SSHConfigImporter.profiles(fromConfig: try String(contentsOf: url, encoding: .utf8))
            let count = model.importProfiles(profiles)
            model.showAlert(title: count == 0 ? "No new hosts found" : "Imported \(count) connection\(count == 1 ? "" : "s")",
                            message: count == 0
                                ? "All concrete Host entries in that file are already saved."
                                : "Hosts that use an IdentityFile still need their private key imported in each connection's settings.")
        } catch {
            model.showAlert(title: "Couldn't import SSH config", message: error.localizedDescription)
        }
    }
}
