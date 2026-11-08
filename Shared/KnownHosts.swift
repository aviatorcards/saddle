import Foundation
import CryptoKit
import NIOCore
import NIOSSH
import Synchronization

/// Trust-on-first-use host key store, shared between the app and the extension.
///
/// The app asks the user to confirm a new host's fingerprint before connecting; the
/// extension only accepts keys that are already trusted, because it can't show UI.
nonisolated enum KnownHosts {
    private static var url: URL { AppGroup.containerURL.appending(path: "known_hosts.json") }
    private static let lock = Mutex(())

    enum Verdict: Equatable, Sendable {
        case trusted
        case unknown
        case changed(previousFingerprint: String)
    }

    static func key(host: String, port: Int) -> String {
        port == 22 ? host.lowercased() : "[\(host.lowercased())]:\(port)"
    }

    static func verdict(host: String, port: Int, presentedKey: String) -> Verdict {
        let stored = lock.withLock { _ in JSONFile.read([String: String].self, from: url) ?? [:] }
        guard let existing = stored[key(host: host, port: port)] else { return .unknown }
        return normalized(existing) == normalized(presentedKey)
            ? .trusted
            : .changed(previousFingerprint: fingerprint(ofOpenSSHKey: existing))
    }

    static func trust(host: String, port: Int, openSSHKey: String) throws {
        try lock.withLock { _ in
            var stored = JSONFile.read([String: String].self, from: url) ?? [:]
            stored[key(host: host, port: port)] = normalized(openSSHKey)
            try JSONFile.write(stored, to: url)
        }
    }

    static func forget(host: String, port: Int) {
        lock.withLock { _ in
            var stored = JSONFile.read([String: String].self, from: url) ?? [:]
            stored[key(host: host, port: port)] = nil
            try? JSONFile.write(stored, to: url)
        }
    }

    /// `"<type> <base64>"` with any trailing comment removed.
    static func normalized(_ openSSHKey: String) -> String {
        openSSHKey.split(separator: " ").prefix(2).joined(separator: " ")
    }

    /// OpenSSH-style `SHA256:` fingerprint, as shown by `ssh-keygen -lf`.
    static func fingerprint(ofOpenSSHKey openSSHKey: String) -> String {
        let parts = openSSHKey.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return "unknown" }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}

/// Validates the server's host key against `KnownHosts` and remembers what it saw,
/// so callers can surface a precise error when the handshake is rejected.
nonisolated final class KnownHostValidator: NIOSSHClientServerAuthenticationDelegate, Sendable {
    struct Observation: Sendable {
        let openSSHKey: String
        let verdict: KnownHosts.Verdict
    }

    let host: String
    let port: Int
    private let observed = Mutex<Observation?>(nil)

    init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    var observation: Observation? { observed.withLock { $0 } }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let presented = String(openSSHPublicKey: hostKey)
        let verdict = KnownHosts.verdict(host: host, port: port, presentedKey: presented)
        observed.withLock { $0 = Observation(openSSHKey: presented, verdict: verdict) }

        switch verdict {
        case .trusted:
            validationCompletePromise.succeed(())
        case .unknown:
            validationCompletePromise.fail(SaddleError.unknownHostKey(
                host: host, port: port,
                fingerprint: KnownHosts.fingerprint(ofOpenSSHKey: presented),
                openSSHKey: presented))
        case .changed(let previous):
            validationCompletePromise.fail(SaddleError.hostKeyChanged(
                host: host, port: port,
                fingerprint: KnownHosts.fingerprint(ofOpenSSHKey: presented),
                previousFingerprint: previous,
                openSSHKey: presented))
        }
    }
}
