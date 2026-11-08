import Foundation
import Security

/// Stores per-connection secrets in the data protection Keychain, shared with the
/// File Provider extension through the App Group access group.
nonisolated enum SecretStore {
    enum Kind: String, Sendable {
        case password
        case privateKey
        case passphrase
    }

    enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
                return "Keychain error: \(message)"
            }
        }
    }

    private static let service = "Saddle"

    /// The shared data protection keychain needs a team-signed build. Without one, fall
    /// back to the process's own login keychain items (not visible to the extension).
    /// False when this process isn't allowed to use the shared data-protection keychain.
    /// Secrets then stay in the login keychain, which the file provider extension cannot read.
    static let sharesWithExtension: Bool = {
        let probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "entitlement-probe",
            kSecAttrAccessGroup as String: AppGroup.identifier,
            kSecUseDataProtectionKeychain as String: true,
        ]
        return SecItemCopyMatching(probe as CFDictionary, nil) != errSecMissingEntitlement
    }()

    private static func baseQuery(profileID: UUID, kind: Kind) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(profileID.uuidString).\(kind.rawValue)",
        ]
        if sharesWithExtension {
            query[kSecAttrAccessGroup as String] = AppGroup.identifier
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    static func set(_ value: Data?, for profileID: UUID, kind: Kind) throws {
        let query = baseQuery(profileID: profileID, kind: kind)
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError.unexpectedStatus(status)
            }
            return
        }

        let attributes: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    static func setString(_ value: String?, for profileID: UUID, kind: Kind) throws {
        try set(value.flatMap { $0.isEmpty ? nil : Data($0.utf8) }, for: profileID, kind: kind)
    }

    static func data(for profileID: UUID, kind: Kind) -> Data? {
        var query = baseQuery(profileID: profileID, kind: kind)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func string(for profileID: UUID, kind: Kind) -> String? {
        data(for: profileID, kind: kind).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func removeAll(for profileID: UUID) {
        for kind in [Kind.password, .privateKey, .passphrase] {
            try? set(nil, for: profileID, kind: kind)
        }
    }
}
