import AppKit
import ServiceManagement
import SwiftUI

/// The main Settings window for Saddle.
struct SettingsView: View {
    static let windowID = "settings"

    @Environment(AppModel.self) private var model

    private enum Tab: Hashable {
        case general
        case defaults
        case knownHosts
        case advanced
    }

    @State private var selectedTab: Tab = .general

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsTab()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag(Tab.general)

            ConnectionDefaultsTab()
                .tabItem {
                    Label("Defaults", systemImage: "server.rack")
                }
                .tag(Tab.defaults)

            KnownHostsTab()
                .tabItem {
                    Label("Known Hosts", systemImage: "lock.shield")
                }
                .tag(Tab.knownHosts)

            AdvancedSettingsTab()
                .tabItem {
                    Label("Advanced", systemImage: "slider.horizontal.3")
                }
                .tag(Tab.advanced)
        }
        .frame(minWidth: 540, idealWidth: 560, minHeight: 400, idealHeight: 440)
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            model.settings.refreshLaunchAtLoginStatus()
        }
        .onDisappear {
            let otherOpenWindows = NSApp.windows.filter { $0.isVisible && $0.canBecomeKey }
            if otherOpenWindows.count <= 1 {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

// MARK: - General Tab

private struct GeneralSettingsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings

        Form {
            Section("Startup") {
                Toggle("Launch Saddle at login", isOn: Binding(
                    get: { settings.isLaunchAtLoginEnabled },
                    set: { settings.setLaunchAtLogin($0) }
                ))

                if settings.launchAtLoginStatus == .requiresApproval {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Approval Required")
                                .font(.subheadline.weight(.medium))
                            Text("Saddle was previously disabled from starting automatically. You can enable it in macOS System Settings > General > Login Items.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.1)))
                }

                Text("Automatically launches Saddle in your menu bar when you log into your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Finder Integration") {
                Toggle("Open in Finder after mounting", isOn: $settings.openInFinderOnMount)
                Text("When connecting to an SFTP server, immediately reveal its mounted folder in Finder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Notifications") {
                Toggle("Notify when connection fails", isOn: $settings.notifyOnConnectionError)
                Toggle("Notify when volume is mounted", isOn: $settings.notifyOnMount)
                Toggle("Notify when volume is disconnected", isOn: $settings.notifyOnDisconnect)
                Text("Notifications are posted through macOS Notification Center.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Defaults Tab

private struct ConnectionDefaultsTab: View {
    @Environment(AppModel.self) private var model
    @State private var showingResetAlert = false

    var body: some View {
        @Bindable var settings = model.settings

        Form {
            Section("New Connection Defaults") {
                TextField("Default Port", value: $settings.defaultPort, format: .number.grouping(.never))

                TextField("Default Username", text: $settings.defaultUsername, prompt: Text(NSUserName()))

                TextField("Default Remote Folder", text: $settings.defaultRemotePath, prompt: Text("Home directory"))

                Stepper("Parallel SFTP Channels: \(settings.defaultParallelTransfers)", value: $settings.defaultParallelTransfers, in: 1...8)

                Picker("Check for Remote Changes", selection: $settings.defaultRefreshInterval) {
                    Text("Every 15 seconds").tag(TimeInterval(15))
                    Text("Every minute").tag(TimeInterval(60))
                    Text("Every 5 minutes").tag(TimeInterval(300))
                    Text("Every 15 minutes").tag(TimeInterval(900))
                }

                Toggle("Show Hidden Files", isOn: $settings.defaultShowHiddenFiles)
                Toggle("Keep all files downloaded", isOn: $settings.defaultKeepAllDownloaded)
                Text("New connections download every file and keep it on this Mac, so Finder doesn't show the cloud badge.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("These values pre-populate fields when you click 'Add Connection' in the Connections manager.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Reset Defaults to Factory Values") {
                    showingResetAlert = true
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .confirmationDialog(
            "Reset Defaults?",
            isPresented: $showingResetAlert,
            titleVisibility: .visible
        ) {
            Button("Reset to Defaults", role: .destructive) {
                model.settings.resetToDefaults()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will restore initial default values for new connections. Your existing saved servers will not be modified.")
        }
    }
}

// MARK: - Known Hosts Tab

private struct KnownHostsTab: View {
    @State private var entries: [KnownHosts.HostEntry] = []
    @State private var searchText = ""
    @State private var entryToForget: KnownHosts.HostEntry?
    @State private var showingForgetAllAlert = false
    @State private var copiedFingerprint: String?

    private var filteredEntries: [KnownHosts.HostEntry] {
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return entries
        }
        let term = searchText.lowercased()
        return entries.filter {
            $0.host.lowercased().contains(term)
                || "\($0.port)".contains(term)
                || $0.fingerprint.lowercased().contains(term)
                || $0.keyType.lowercased().contains(term)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header / Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter by host or fingerprint…", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button(action: loadEntries) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reload known hosts")
                .buttonStyle(.borderless)
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            if entries.isEmpty {
                ContentUnavailableView {
                    Label("No Known Hosts", systemImage: "lock.shield")
                } description: {
                    Text("Trusted SSH host keys are saved here when you connect to an SFTP server.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredEntries.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredEntries) { entry in
                    KnownHostRow(
                        entry: entry,
                        isCopied: copiedFingerprint == entry.fingerprint,
                        onCopy: { copyFingerprint(entry.fingerprint) },
                        onForget: { entryToForget = entry }
                    )
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }

            Divider()

            // Footer
            HStack {
                Text("\(entries.count) trusted host key\(entries.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Forget All…", role: .destructive) {
                    showingForgetAllAlert = true
                }
                .disabled(entries.isEmpty)
                .controlSize(.small)
            }
            .padding(10)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .onAppear(perform: loadEntries)
        .confirmationDialog(
            "Forget Host Key?",
            isPresented: Binding(
                get: { entryToForget != nil },
                set: { if !$0 { entryToForget = nil } }
            ),
            titleVisibility: .visible,
            presenting: entryToForget
        ) { entry in
            Button("Forget Key for \(entry.host):\(entry.port)", role: .destructive) {
                KnownHosts.forget(host: entry.host, port: entry.port)
                loadEntries()
                entryToForget = nil
            }
            Button("Cancel", role: .cancel) {
                entryToForget = nil
            }
        } message: { entry in
            Text("If you connect to \(entry.host):\(entry.port) again, Saddle will ask you to verify and trust its host key anew.")
        }
        .confirmationDialog(
            "Forget All Known Hosts?",
            isPresented: $showingForgetAllAlert,
            titleVisibility: .visible
        ) {
            Button("Forget All Keys", role: .destructive) {
                KnownHosts.forgetAll()
                loadEntries()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("All trusted SSH server keys will be removed. You will be prompted to verify host keys the next time you connect to any server.")
        }
    }

    private func loadEntries() {
        entries = KnownHosts.allEntries()
    }

    private func copyFingerprint(_ fingerprint: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fingerprint, forType: .string)
        copiedFingerprint = fingerprint
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copiedFingerprint == fingerprint {
                copiedFingerprint = nil
            }
        }
    }
}

private struct KnownHostRow: View {
    let entry: KnownHosts.HostEntry
    let isCopied: Bool
    let onCopy: () -> Void
    let onForget: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "key.horizontal")
                .foregroundStyle(.secondary)
                .font(.body)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.host)
                        .font(.body.weight(.semibold))

                    if entry.port != 22 {
                        Text(":\(entry.port)")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                    Text(entry.keyType)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    Text(entry.fingerprint)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Button(action: onCopy) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.caption2)
                            .foregroundStyle(isCopied ? .green : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Copy fingerprint to clipboard")
                }
            }

            Spacer()

            Button(role: .destructive, action: onForget) {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Forget this host key")
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Advanced Tab

private struct AdvancedSettingsTab: View {
    @Environment(AppModel.self) private var model
    @State private var showingClearLogsAlert = false

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    var body: some View {
        @Bindable var settings = model.settings

        Form {
            Section("Shared Storage") {
                LabeledContent("App Group Identifier") {
                    Text(AppGroup.identifier)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Container Path") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(AppGroup.containerURL.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)

                        Button("Reveal in Finder", systemImage: "folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([AppGroup.containerURL])
                        }
                        .controlSize(.small)
                    }
                }
            }

            Section("Download Ahead") {
                Toggle("Download files ahead", isOn: $settings.prefetchEnabled)
                Stepper("Up to \(settings.prefetchMaxFileMB) MB per file", value: $settings.prefetchMaxFileMB, in: 1...64)
                Stepper("Up to \(settings.prefetchMaxFolderMB) MB per folder", value: $settings.prefetchMaxFolderMB, in: 5...500)
                Text("When you open a folder, Saddle fetches small files in the background so a later copy doesn't start from nothing. Hidden files, partial uploads, and links outside the mount are skipped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Activity Log") {
                LabeledContent("Logged Events") {
                    HStack {
                        Text("\(model.activity.count) recent entries")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear Activity Log", role: .destructive) {
                            showingClearLogsAlert = true
                        }
                        .controlSize(.small)
                        .disabled(model.activity.isEmpty)
                    }
                }
            }

            Section("About Saddle") {
                LabeledContent("Version") {
                    Text(appVersion)
                        .foregroundStyle(.secondary)
                }

                Text("Saddle mounts SFTP servers as Finder volumes using the macOS File Provider framework. Each connection maintains independent parallel channels and synchronizes files on-demand.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .confirmationDialog(
            "Clear Activity Log?",
            isPresented: $showingClearLogsAlert,
            titleVisibility: .visible
        ) {
            Button("Clear Log", role: .destructive) {
                model.clearActivity()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This deletes recorded transfer and mount events. Your saved connections and active mounts are unaffected.")
        }
    }
}
