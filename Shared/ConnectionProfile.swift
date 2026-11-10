import Foundation
import FileProvider

/// How a connection authenticates with the SSH server.
nonisolated enum AuthMethod: String, Codable, CaseIterable, Sendable {
    case password
    case privateKey

    var title: String {
        switch self {
        case .password: "Password"
        case .privateKey: "Private Key"
        }
    }
}

/// A saved SFTP server. Secrets (password, key, passphrase) live in the Keychain, not here.
nonisolated struct ConnectionProfile: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name = ""
    var host = ""
    var port = 22
    var username = NSUserName()
    /// Remote directory used as the root of the mount. Empty means the login directory.
    var remotePath = ""
    var authMethod = AuthMethod.password
    /// File name of the imported private key, for display only.
    var privateKeyName: String?
    /// Number of SFTP channels opened in parallel over the single SSH session.
    var maxConnections = 3
    /// Seconds between remote change polls while connected.
    var refreshInterval: TimeInterval = 60
    var showHiddenFiles = true
    /// When set, Finder downloads every file in the mount and keeps it, so folders lose the cloud badge.
    var keepAllDownloaded = false

    var displayName: String {
        name.isEmpty ? "\(username)@\(host)" : name
    }

    var domainIdentifier: NSFileProviderDomainIdentifier {
        NSFileProviderDomainIdentifier(id.uuidString)
    }

    var isValid: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && (1...65535).contains(port)
    }
}

extension ConnectionProfile {
    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, remotePath, authMethod, privateKeyName
        case maxConnections, refreshInterval, showHiddenFiles, keepAllDownloaded
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 22
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? NSUserName()
        remotePath = try container.decodeIfPresent(String.self, forKey: .remotePath) ?? ""
        authMethod = try container.decodeIfPresent(AuthMethod.self, forKey: .authMethod) ?? .password
        privateKeyName = try container.decodeIfPresent(String.self, forKey: .privateKeyName)
        maxConnections = try container.decodeIfPresent(Int.self, forKey: .maxConnections) ?? 3
        refreshInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .refreshInterval) ?? 60
        showHiddenFiles = try container.decodeIfPresent(Bool.self, forKey: .showHiddenFiles) ?? true
        keepAllDownloaded = try container.decodeIfPresent(Bool.self, forKey: .keepAllDownloaded) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(username, forKey: .username)
        try container.encode(remotePath, forKey: .remotePath)
        try container.encode(authMethod, forKey: .authMethod)
        try container.encodeIfPresent(privateKeyName, forKey: .privateKeyName)
        try container.encode(maxConnections, forKey: .maxConnections)
        try container.encode(refreshInterval, forKey: .refreshInterval)
        try container.encode(showHiddenFiles, forKey: .showHiddenFiles)
        try container.encode(keepAllDownloaded, forKey: .keepAllDownloaded)
    }
}

/// Persists connection profiles in the shared App Group container.
nonisolated enum ProfileStore {
    private static var url: URL { AppGroup.containerURL.appending(path: "profiles.json") }

    static func load() -> [ConnectionProfile] {
        JSONFile.read([ConnectionProfile].self, from: url) ?? []
    }

    static func save(_ profiles: [ConnectionProfile]) throws {
        try JSONFile.write(profiles, to: url)
    }

    static func profile(for domainIdentifier: NSFileProviderDomainIdentifier) -> ConnectionProfile? {
        load().first { $0.domainIdentifier == domainIdentifier }
    }
}
