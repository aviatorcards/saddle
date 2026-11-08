import Foundation

nonisolated enum SaddleError: LocalizedError, Sendable {
    case profileNotFound
    case missingCredentials(String)
    case unsupportedKey(String)
    case unknownHostKey(host: String, port: Int, fingerprint: String, openSSHKey: String)
    case hostKeyChanged(host: String, port: Int, fingerprint: String, previousFingerprint: String, openSSHKey: String)
    case authenticationFailed
    case connectionFailed(String)
    case notADirectory(String)

    var errorDescription: String? {
        switch self {
        case .profileNotFound:
            "The connection settings for this location could not be found."
        case .missingCredentials(let detail):
            "Missing credentials: \(detail)"
        case .unsupportedKey(let detail):
            "Unsupported private key: \(detail)"
        case .unknownHostKey(let host, _, let fingerprint, _):
            "The authenticity of \(host) can't be established (\(fingerprint)). Open Saddle to verify and trust this server."
        case .hostKeyChanged(let host, _, let fingerprint, let previous, _):
            "WARNING: The host key for \(host) has changed (now \(fingerprint), previously \(previous)). This could indicate a man-in-the-middle attack."
        case .authenticationFailed:
            "Authentication failed. Check the username and credentials."
        case .connectionFailed(let detail):
            "Could not connect: \(detail)"
        case .notADirectory(let path):
            "\(path) is not a directory."
        }
    }
}
