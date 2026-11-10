import SwiftUI
import UniformTypeIdentifiers

/// Edits one connection. Changes are kept in a draft until the user saves.
struct ProfileEditorView: View {
    @Environment(AppModel.self) private var model

    @State private var draft: ConnectionProfile
    @State private var password = ""
    @State private var passphrase = ""
    @State private var hasStoredKey = false
    @State private var isImportingKey = false
    @State private var testResult: TestResult?
    @State private var isTesting = false

    private enum TestResult {
        case success(String)
        case failure(String)
    }

    init(profile: ConnectionProfile) {
        _draft = State(initialValue: profile)
    }

    private var isMounted: Bool { model.mountedIDs.contains(draft.id) }

    var body: some View {
        Form {
            Section("Server") {
                TextField("Name", text: $draft.name, prompt: Text("My Server"))
                TextField("Host", text: $draft.host, prompt: Text("example.com"))
                TextField("Port", value: $draft.port, format: .number.grouping(.never))
                TextField("Username", text: $draft.username)
                TextField("Remote Folder", text: $draft.remotePath, prompt: Text("Home directory"))
            }

            Section("Authentication") {
                Picker("Method", selection: $draft.authMethod) {
                    ForEach(AuthMethod.allCases, id: \.self) { method in
                        Text(method.title).tag(method)
                    }
                }

                switch draft.authMethod {
                case .password:
                    SecureField("Password", text: $password)
                case .privateKey:
                    LabeledContent("Private Key") {
                        HStack {
                            if hasStoredKey {
                                Text(draft.privateKeyName ?? "Imported key")
                                    .foregroundStyle(.secondary)
                            } else if let hint = draft.privateKeyName {
                                Text("Import \(hint)")
                                    .foregroundStyle(.orange)
                            }
                            Button(hasStoredKey ? "Replace…" : "Choose…") { isImportingKey = true }
                        }
                    }
                    SecureField("Passphrase", text: $passphrase, prompt: Text("Only if the key is encrypted"))
                    Text("Ed25519 and RSA keys in OpenSSH format are supported. The key is copied into your Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Finder") {
                Toggle("Keep all files downloaded", isOn: $draft.keepAllDownloaded)
                Text("Downloads every file in this connection and keeps it on this Mac. You can still pin or release a single item from Finder's menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Advanced") {
                Stepper("Parallel Transfers: \(draft.maxConnections)", value: $draft.maxConnections, in: 1...8)
                Picker("Check for Remote Changes", selection: $draft.refreshInterval) {
                    Text("Every 15 seconds").tag(TimeInterval(15))
                    Text("Every minute").tag(TimeInterval(60))
                    Text("Every 5 minutes").tag(TimeInterval(300))
                    Text("Every 15 minutes").tag(TimeInterval(900))
                }
                Toggle("Show Hidden Files", isOn: $draft.showHiddenFiles)
            }

            if let testResult {
                Section {
                    switch testResult {
                    case .success(let message):
                        Label(message, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .failure(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(draft.displayName)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Test Connection", action: test)
                    .disabled(!draft.isValid || isTesting)
                Button(isMounted ? "Save" : "Save and Connect", action: saveAndConnect)
                    .keyboardShortcut("s")
                    .buttonStyle(.borderedProminent)
                    .disabled(!draft.isValid)
            }
        }
        .fileImporter(isPresented: $isImportingKey, allowedContentTypes: [.item]) { result in
            importKey(result)
        }
        .fileDialogMessage("Choose a private key, such as ~/.ssh/id_ed25519. Press ⇧⌘. to show hidden folders.")
        .onAppear(perform: loadSecrets)
    }

    // MARK: - Actions

    private func loadSecrets() {
        password = SecretStore.string(for: draft.id, kind: .password) ?? ""
        passphrase = SecretStore.string(for: draft.id, kind: .passphrase) ?? ""
        hasStoredKey = SecretStore.data(for: draft.id, kind: .privateKey) != nil
    }

    private func storeSecrets() -> Bool {
        do {
            try SecretStore.setString(draft.authMethod == .password ? password : nil, for: draft.id, kind: .password)
            try SecretStore.setString(draft.authMethod == .privateKey ? passphrase : nil, for: draft.id, kind: .passphrase)
            return true
        } catch {
            testResult = .failure(error.localizedDescription)
            return false
        }
    }

    private func test() {
        guard storeSecrets() else { return }
        isTesting = true
        testResult = nil
        let profile = draft
        Task {
            defer { isTesting = false }
            do {
                let root = try await model.verify(profile)
                testResult = .success("Connected. Remote folder: \(root)")
            } catch is CancellationError {
                testResult = nil
            } catch {
                testResult = .failure(error.localizedDescription)
            }
        }
    }

    private func saveAndConnect() {
        guard storeSecrets() else { return }
        model.save(draft)
        if !isMounted {
            let profile = draft
            Task { await model.connect(profile) }
        }
    }

    private func importKey(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let text = try String(contentsOf: url, encoding: .utf8)
            guard text.contains("PRIVATE KEY") else {
                testResult = .failure("\(url.lastPathComponent) doesn't look like a private key. Choose the file without the .pub extension.")
                return
            }
            try SecretStore.setString(text, for: draft.id, kind: .privateKey)
            draft.privateKeyName = url.lastPathComponent
            hasStoredKey = true
            testResult = nil
        } catch {
            testResult = .failure(error.localizedDescription)
        }
    }
}
