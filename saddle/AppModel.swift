import AppKit
import FileProvider
import Network
import Observation
import UserNotifications

/// What the menu shows for a connection.
enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case syncing
    case error(String)
}

/// Owns saved connections and drives File Provider domains (one per mounted connection).
@Observable
final class AppModel {
    private(set) var profiles: [ConnectionProfile] = ProfileStore.load()
    private(set) var mountedIDs: Set<UUID> = []
    private(set) var statuses: [UUID: DomainStatus] = [:]
    private(set) var activity: [ActivityLog.Entry] = []
    private var busyIDs: Set<UUID> = []
    private var localErrors: [UUID: String] = [:]

    @ObservationIgnored private var lastRefresh: [UUID: Date] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var networkWasDown = false

    init() {
        Task { await reloadDomains() }
        startPolling()
        startNetworkMonitor()
    }

    // MARK: - State

    func state(for profile: ConnectionProfile) -> ConnectionState {
        if busyIDs.contains(profile.id) { return .connecting }
        guard mountedIDs.contains(profile.id) else {
            return localErrors[profile.id].map(ConnectionState.error) ?? .disconnected
        }
        if let message = localErrors[profile.id] { return .error(message) }
        guard let status = statuses[profile.id] else { return .connected }
        switch status.state {
        case .error: return .error(status.message ?? "Connection error")
        case .connecting: return .connecting
        case .idle, .connected: return status.transfers.isEmpty ? .connected : .syncing
        }
    }

    var activeTransfers: [(profile: ConnectionProfile, transfer: DomainStatus.Transfer)] {
        profiles.flatMap { profile in
            (statuses[profile.id]?.transfers ?? []).map { (profile, $0) }
        }
    }

    var isSyncing: Bool { !activeTransfers.isEmpty }

    func profile(withID id: UUID) -> ConnectionProfile? {
        profiles.first { $0.id == id }
    }

    // MARK: - Profiles

    func save(_ profile: ConnectionProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        persist()

        // Re-adding an existing domain updates its Finder sidebar name.
        if mountedIDs.contains(profile.id) {
            Task { try? await NSFileProviderManager.add(domain(for: profile)) }
        }
    }

    func delete(_ profile: ConnectionProfile) async {
        if mountedIDs.contains(profile.id) { await disconnect(profile) }
        SecretStore.removeAll(for: profile.id)
        try? FileManager.default.removeItem(at: AppGroup.domainDirectory(for: profile.id))
        profiles.removeAll { $0.id == profile.id }
        persist()
    }

    func importProfiles(_ imported: [ConnectionProfile]) -> Int {
        let existing = Set(profiles.map { "\($0.username)@\($0.host):\($0.port)" })
        let new = imported.filter { !existing.contains("\($0.username)@\($0.host):\($0.port)") }
        profiles.append(contentsOf: new)
        persist()
        return new.count
    }

    private func persist() {
        do {
            try ProfileStore.save(profiles)
        } catch {
            showAlert(title: "Couldn't save connections", message: error.localizedDescription)
        }
    }

    // MARK: - Connecting

    /// Verifies the connection (prompting to trust new host keys), then mounts it in Finder.
    func connect(_ profile: ConnectionProfile) async {
        busyIDs.insert(profile.id)
        localErrors[profile.id] = nil
        defer { busyIDs.remove(profile.id) }

        do {
            _ = try await verify(profile)
            try await NSFileProviderManager.add(domain(for: profile))
            mountedIDs.insert(profile.id)
            ActivityLog.append("Mounted \(profile.displayName)", profileID: profile.id)
            await openInFinder(profile)
        } catch {
            fail(profile, error)
        }
    }

    func disconnect(_ profile: ConnectionProfile) async {
        do {
            // Keep any edits that haven't been uploaded yet instead of discarding them.
            if let preserved = try await NSFileProviderManager.remove(domain(for: profile), mode: .preserveDirtyUserData) {
                showAlert(title: "Unsynced changes were preserved",
                          message: "Files from \(profile.displayName) that hadn't finished uploading were moved to \(preserved.path).")
                NSWorkspace.shared.activateFileViewerSelecting([preserved])
            }
            mountedIDs.remove(profile.id)
            statuses[profile.id] = nil
            localErrors[profile.id] = nil
            ActivityLog.append("Ejected \(profile.displayName)", profileID: profile.id)
        } catch {
            fail(profile, error)
        }
    }

    /// Connects once outside the extension. Returns the resolved remote root path.
    @discardableResult
    func verify(_ profile: ConnectionProfile) async throws -> String {
        let session = SFTPSession(profile: profile)
        defer { Task { await session.close() } }
        do {
            return try await session.connect()
        } catch SaddleError.unknownHostKey(let host, let port, let fingerprint, let key) {
            guard await confirmTrust(host: host, fingerprint: fingerprint, previousFingerprint: nil) else { throw CancellationError() }
            try KnownHosts.trust(host: host, port: port, openSSHKey: key)
            return try await verify(profile)
        } catch SaddleError.hostKeyChanged(let host, let port, let fingerprint, let previous, let key) {
            guard await confirmTrust(host: host, fingerprint: fingerprint, previousFingerprint: previous) else { throw CancellationError() }
            try KnownHosts.trust(host: host, port: port, openSSHKey: key)
            return try await verify(profile)
        }
    }

    func openInFinder(_ profile: ConnectionProfile) async {
        guard let manager = NSFileProviderManager(for: domain(for: profile)) else { return }
        do {
            let url = try await manager.getUserVisibleURL(for: .rootContainer)
            // The sandbox only lets Saddle hand this folder to Finder while it holds the
            // URL's security scope; without it, Finder reports a permission error.
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            guard let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") else {
                NSWorkspace.shared.activateFileViewerSelecting([url])
                return
            }
            do {
                // Open with Finder explicitly, rather than "whatever opens folders".
                try await NSWorkspace.shared.open([url], withApplicationAt: finder, configuration: configuration)
            } catch {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } catch {
            fail(profile, error)
        }
    }

    func refresh(_ profile: ConnectionProfile) async {
        guard mountedIDs.contains(profile.id), let manager = NSFileProviderManager(for: domain(for: profile)) else { return }
        lastRefresh[profile.id] = Date()
        try? await manager.signalEnumerator(for: .workingSet)
    }

    func refreshAll() async {
        for profile in profiles where mountedIDs.contains(profile.id) {
            await refresh(profile)
        }
    }

    private func domain(for profile: ConnectionProfile) -> NSFileProviderDomain {
        NSFileProviderDomain(identifier: profile.domainIdentifier, displayName: profile.displayName)
    }

    private func reloadDomains() async {
        let domains = (try? await NSFileProviderManager.domains()) ?? []
        mountedIDs = Set(domains.compactMap { UUID(uuidString: $0.identifier.rawValue) })
    }

    private func fail(_ profile: ConnectionProfile, _ error: Error) {
        guard !(error is CancellationError) else { return }
        localErrors[profile.id] = error.localizedDescription
        ActivityLog.append(error.localizedDescription, profileID: profile.id, isError: true)
        notify(title: "\(profile.displayName) failed", body: error.localizedDescription)
    }

    // MARK: - Background polling

    /// Reads extension status every couple of seconds and triggers remote change polls
    /// at each connection's refresh interval.
    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func tick() async {
        for profile in profiles where mountedIDs.contains(profile.id) {
            let previous = statuses[profile.id]
            let current = DomainStatus.read(for: profile.id)
            statuses[profile.id] = current
            if current?.state == .error, previous?.state != .error, let message = current?.message {
                notify(title: "\(profile.displayName) is unavailable", body: message)
            }
            if Date().timeIntervalSince(lastRefresh[profile.id] ?? .distantPast) >= max(15, profile.refreshInterval) {
                await refresh(profile)
            }
        }
        let recent = ActivityLog.recent(limit: 20)
        if recent != activity { activity = recent }
    }

    /// Re-polls every connection as soon as the network comes back (wake from sleep, Wi-Fi change).
    private func startNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let isUp = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                if isUp, self.networkWasDown { await self.refreshAll() }
                self.networkWasDown = !isUp
            }
        }
        pathMonitor.start(queue: .global(qos: .utility))
    }

    // MARK: - User interaction

    /// Presents the alert from a fresh main-queue turn instead of inside the caller's task.
    /// `runModal` still blocks the main thread until the user answers.
    private func confirmTrust(host: String, fingerprint: String, previousFingerprint: String?) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let trusted = MainActor.assumeIsolated {
                    Self.presentTrustAlert(host: host, fingerprint: fingerprint, previousFingerprint: previousFingerprint)
                }
                continuation.resume(returning: trusted)
            }
        }
    }

    private static func presentTrustAlert(host: String, fingerprint: String, previousFingerprint: String?) -> Bool {
        let alert = NSAlert()
        if let previousFingerprint {
            alert.alertStyle = .critical
            alert.messageText = "The host key for \(host) has changed"
            alert.informativeText = """
                Someone could be intercepting your connection, or the server's key was replaced.

                New: \(fingerprint)
                Previously: \(previousFingerprint)

                Only continue if you know the server's key was changed.
                """
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Replace Key and Connect").hasDestructiveAction = true
            WindowActivation.prepare(alert)
            return alert.runModal() == .alertSecondButtonReturn
        } else {
            alert.messageText = "Trust \(host)?"
            alert.informativeText = """
                This is the first time connecting to this server. Check that its fingerprint matches before continuing.

                \(fingerprint)
                """
            alert.addButton(withTitle: "Trust and Connect")
            alert.addButton(withTitle: "Cancel")
            WindowActivation.prepare(alert)
            return alert.runModal() == .alertFirstButtonReturn
        }
    }

    func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        WindowActivation.prepare(alert)
        alert.runModal()
    }

    private func notify(title: String, body: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
