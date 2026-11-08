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
