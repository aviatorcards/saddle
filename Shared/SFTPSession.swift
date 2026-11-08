import Foundation
import CryptoKit
import Citadel
import NIOCore

/// A file or directory on the remote server.
nonisolated struct RemoteEntry: Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        case file
        case directory
    }

    var path: String
    var name: String
    var kind: Kind
    var size: UInt64
    var modified: Date
    var permissions: UInt32
    /// True when the entry was reached through a symbolic link (attributes are the target's).
    var isSymlink = false

    var isDirectory: Bool { kind == .directory }

    /// Changes whenever the content changes. Size + mtime is all SFTP v3 gives us.
    var contentVersion: String { "\(size):\(Int64(modified.timeIntervalSince1970))" }
    var metadataVersion: String { "\(contentVersion):\(permissions & 0o7777)" }
}

/// POSIX path helpers for remote paths (always `/`-separated, independent of the Mac).
nonisolated enum RemotePath {
    static func join(_ base: String, _ component: String) -> String {
        guard !component.isEmpty else { return base }
        if base.isEmpty || base == "/" { return "/" + component }
        return base + "/" + component
    }

    static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        let parent = String(path[..<slash])
        return parent.isEmpty && path.hasPrefix("/") ? "/" : parent
    }

    static func name(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}

/// One SSH connection to a server with a small pool of multiplexed SFTP channels.
///
/// All operations go through `perform(_:)`, which reconnects once and retries if the
/// connection was lost (sleep/wake, Wi-Fi changes, server timeouts).
actor SFTPSession {
    let profile: ConnectionProfile

    private var client: SSHClient?
    private var channels: [SFTPClient] = []
    private var nextChannel = 0
    private var connecting: Task<SSHClient, Error>?
    private var keepAlive: Task<Void, Never>?
    private var lastActivity = Date()

    /// Absolute remote path that maps to the root of the mounted location.
    private(set) var rootPath: String?

    private static let readChunk: UInt32 = 128 * 1024
    private static let writeChunk = 256 * 1024

    init(profile: ConnectionProfile) {
        self.profile = profile
    }

    // MARK: - Connection lifecycle

    /// Connects (if needed) and resolves the root directory.
    @discardableResult
    func connect() async throws -> String {
        if let rootPath, client?.isConnected == true { return rootPath }
        let sftp = try await channel()
        let requested = profile.remotePath.trimmingCharacters(in: .whitespaces)
        let resolved = try await sftp.getRealPath(atPath: requested.isEmpty ? "." : requested)
        let attributes = try await sftp.getAttributes(at: resolved)
        guard Self.kind(of: attributes) == .directory else { throw SaddleError.notADirectory(resolved) }
        rootPath = resolved
        return resolved
    }

    func close() async {
        keepAlive?.cancel()
        keepAlive = nil
        let open = channels
        channels.removeAll()
        for channel in open { try? await channel.close() }
        try? await client?.close()
        client = nil
    }

    private func sshClient() async throws -> SSHClient {
        if let client, client.isConnected { return client }
        if let connecting { return try await connecting.value }

        let settings = try makeSettings()
        let task = Task { try await Self.open(settings: settings.settings, validator: settings.validator) }
        connecting = task
        defer { connecting = nil }

        let newClient = try await task.value
        client = newClient
        channels.removeAll()
        startKeepAlive()
        return newClient
    }

    private static func open(settings: SSHClientSettings, validator: KnownHostValidator) async throws -> SSHClient {
        do {
            return try await SSHClient.connect(to: settings)
        } catch {
            // Host key rejections surface as generic channel errors; report the real cause.
            if let observation = validator.observation {
                switch observation.verdict {
                case .trusted: break
                case .unknown:
                    throw SaddleError.unknownHostKey(
                        host: validator.host, port: validator.port,
                        fingerprint: KnownHosts.fingerprint(ofOpenSSHKey: observation.openSSHKey),
                        openSSHKey: observation.openSSHKey)
                case .changed(let previous):
                    throw SaddleError.hostKeyChanged(
                        host: validator.host, port: validator.port,
                        fingerprint: KnownHosts.fingerprint(ofOpenSSHKey: observation.openSSHKey),
                        previousFingerprint: previous,
                        openSSHKey: observation.openSSHKey)
                }
            }
            if error is SaddleError { throw error }
            if let clientError = error as? SSHClientError, case .allAuthenticationOptionsFailed = clientError {
                throw SaddleError.authenticationFailed
            }
            throw SaddleError.connectionFailed(String(describing: error))
        }
    }

    private func makeSettings() throws -> (settings: SSHClientSettings, validator: KnownHostValidator) {
        let username = profile.username
        let authentication: SSHAuthenticationMethod

        switch profile.authMethod {
        case .password:
            guard let password = SecretStore.string(for: profile.id, kind: .password) else {
                throw SaddleError.missingCredentials("no password saved for \(profile.displayName)")
            }
            authentication = .passwordBased(username: username, password: password)
        case .privateKey:
            guard let keyText = SecretStore.string(for: profile.id, kind: .privateKey) else {
                throw SaddleError.missingCredentials("no private key imported for \(profile.displayName)")
            }
            let passphrase = SecretStore.data(for: profile.id, kind: .passphrase)
            authentication = try Self.keyAuthentication(username: username, keyText: keyText, passphrase: passphrase)
        }

        let validator = KnownHostValidator(host: profile.host, port: profile.port)
        var settings = SSHClientSettings(
            host: profile.host,
            port: profile.port,
            authenticationMethod: { authentication },
            hostKeyValidator: .custom(validator))
        settings.connectTimeout = .seconds(15)
        return (settings, validator)
    }

    /// Parses an OpenSSH private key. Citadel supports Ed25519 and RSA keys.
    static func keyAuthentication(username: String, keyText: String, passphrase: Data?) throws -> SSHAuthenticationMethod {
        let type: SSHKeyType
        do {
            type = try SSHKeyDetection.detectPrivateKeyType(from: keyText)
        } catch {
            throw SaddleError.unsupportedKey("expected an OpenSSH private key (\"-----BEGIN OPENSSH PRIVATE KEY-----\"). Convert PEM keys with `ssh-keygen -p -f <key>`.")
        }
        do {
            switch type {
            case .ed25519:
                let key = try Curve25519.Signing.PrivateKey(sshEd25519: keyText, decryptionKey: passphrase)
                return .ed25519(username: username, privateKey: key)
            case .rsa:
                let key = try Insecure.RSA.PrivateKey(sshRsa: keyText, decryptionKey: passphrase)
                return .rsa(username: username, privateKey: key)
            default:
                throw SaddleError.unsupportedKey("\(type) keys aren't supported yet. Use an Ed25519 or RSA key.")
            }
        } catch let error as SaddleError {
            throw error
        } catch {
            throw SaddleError.unsupportedKey(passphrase == nil
                ? "the key could not be read. If it is encrypted, enter its passphrase."
                : "the key could not be decrypted. Check the passphrase.")
        }
    }

    /// Returns an SFTP channel, opening up to `maxConnections` channels round-robin.
    private func channel() async throws -> SFTPClient {
        let ssh = try await sshClient()
        channels.removeAll { !$0.isActive }
        lastActivity = Date()

        if channels.count < max(1, profile.maxConnections) {
            let opened = try await ssh.openSFTP()
            channels.append(opened)
            return opened
        }
        nextChannel = (nextChannel + 1) % channels.count
        return channels[nextChannel]
    }

    /// Runs `operation`, reconnecting and retrying once if the connection dropped.
    private func perform<T>(_ operation: (SFTPClient) async throws -> T) async throws -> T {
        do {
            return try await operation(try await channel())
        } catch {
            guard Self.isConnectionError(error) else { throw error }
            await close()
            return try await operation(try await channel())
        }
    }

    private static func isConnectionError(_ error: Error) -> Bool {
        if error is SFTPMessage.Status || error is SaddleError || error is CancellationError { return false }
        if let sftpError = error as? SFTPError, case .errorStatus = sftpError { return false }
        return true
    }

    /// Sends a cheap SFTP request every 30s while idle so NATs and servers keep the session open.
    private func startKeepAlive() {
        keepAlive?.cancel()
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await self?.pingIfIdle()
            }
        }
    }

    private func pingIfIdle() async {
        guard Date().timeIntervalSince(lastActivity) >= 25, let channel = channels.first(where: \.isActive) else { return }
        _ = try? await channel.getRealPath(atPath: ".")
    }

    // MARK: - Metadata

    func list(_ path: String) async throws -> [RemoteEntry] {
        try await perform { sftp in
            let names = try await sftp.listDirectory(atPath: path)
            var entries: [RemoteEntry] = []
            for component in names.flatMap(\.components) {
                let name = component.filename
                guard name != ".", name != ".." else { continue }
                if !profile.showHiddenFiles, name.hasPrefix(".") { continue }
                // In-flight uploads from `upload(from:to:progress:)`.
                if name.hasPrefix(".saddle-"), name.hasSuffix(".part") { continue }
                let childPath = RemotePath.join(path, name)

                if Self.isSymlink(component.attributes, longname: component.longname) {
                    // Follow the link so Finder sees the target's type and size. Skip dangling links.
                    guard let target = try? await sftp.getAttributes(at: childPath) else { continue }
                    var entry = Self.entry(path: childPath, attributes: target, longname: "")
                    entry.isSymlink = true
                    entries.append(entry)
                } else {
                    entries.append(Self.entry(path: childPath, attributes: component.attributes, longname: component.longname))
                }
            }
            return entries
        }
    }

    func stat(_ path: String) async throws -> RemoteEntry {
        try await perform { sftp in
            Self.entry(path: path, attributes: try await sftp.getAttributes(at: path), longname: "")
        }
    }

    func exists(_ path: String) async throws -> Bool {
        do {
            _ = try await stat(path)
            return true
        } catch let status as SFTPMessage.Status where status.errorCode == .noSuchFile {
            return false
        }
    }

    // MARK: - Transfers

    /// Streams a remote file to `localURL` in chunks, reporting cumulative bytes.
    func download(_ path: String, to localURL: URL, progress: @Sendable (Int64) -> Void) async throws {
        try await perform { sftp in
            FileManager.default.createFile(atPath: localURL.path, contents: nil)
            let output = try FileHandle(forWritingTo: localURL)
            defer { try? output.close() }
            try output.truncate(atOffset: 0)

            let file = try await sftp.openFile(filePath: path, flags: .read)
            do {
                var offset: UInt64 = 0
                while true {
                    try Task.checkCancellation()
                    let buffer = try await file.read(from: offset, length: Self.readChunk)
                    guard buffer.readableBytes > 0 else { break }
                    try buffer.withUnsafeReadableBytes { try output.write(contentsOf: $0) }
                    offset += UInt64(buffer.readableBytes)
                    progress(Int64(offset))
                }
                try await file.close()
            } catch {
                try? await file.close()
                throw error
            }
        }
    }

    /// Uploads `localURL` (or an empty file when nil) to `path`.
    ///
    /// Data is written to a temporary sibling first and renamed into place, so an
    /// interrupted upload never leaves a truncated file behind.
    func upload(from localURL: URL?, to path: String, progress: @Sendable (Int64) -> Void) async throws {
        let temporary = RemotePath.join(RemotePath.parent(of: path), ".saddle-\(UUID().uuidString.prefix(8)).part")
        try await perform { sftp in
            let file = try await sftp.openFile(filePath: temporary, flags: [.write, .create, .truncate])
            do {
                if let localURL {
                    let input = try FileHandle(forReadingFrom: localURL)
                    defer { try? input.close() }
                    var offset: UInt64 = 0
                    while let data = try input.read(upToCount: Self.writeChunk), !data.isEmpty {
                        try Task.checkCancellation()
                        try await file.write(ByteBuffer(bytes: data), at: offset)
                        offset += UInt64(data.count)
                        progress(Int64(offset))
                    }
                }
                try await file.close()
            } catch {
                try? await file.close()
                try? await sftp.remove(at: temporary)
                throw error
            }

            // SFTP v3 rename refuses to overwrite, so replace the destination explicitly.
            if (try? await sftp.getAttributes(at: path)) != nil {
                try await sftp.remove(at: path)
            }
            try await sftp.rename(at: temporary, to: path)
        }
    }

    // MARK: - Mutations

    func createDirectory(_ path: String) async throws {
        try await perform { try await $0.createDirectory(atPath: path) }
    }

    func rename(_ path: String, to newPath: String) async throws {
        try await perform { try await $0.rename(at: path, to: newPath) }
    }

    func setModificationDate(_ date: Date, for path: String) async throws {
        try await perform { sftp in
            var attributes = SFTPFileAttributes()
            attributes.accessModificationTime = .init(accessTime: date, modificationTime: date)
            try await sftp.setAttributes(at: path, to: attributes)
        }
    }

    func setPermissions(_ permissions: UInt32, for path: String) async throws {
        try await perform { sftp in
            var attributes = SFTPFileAttributes()
            attributes.permissions = permissions & 0o7777
            try await sftp.setAttributes(at: path, to: attributes)
        }
    }

    func removeFile(_ path: String) async throws {
        try await perform { try await $0.remove(at: path) }
    }

    /// Removes a directory. With `recursive`, deletes its contents first (depth-first).
    func removeDirectory(_ path: String, recursive: Bool) async throws {
        if recursive {
            for child in try await rawChildren(of: path) {
                if child.isDirectory {
                    try await removeDirectory(child.path, recursive: true)
                } else {
                    try await removeFile(child.path)
                }
            }
        }
        try await perform { try await $0.rmdir(at: path) }
    }

    /// Children without following symlinks, so recursive deletes never escape the tree.
    private func rawChildren(of path: String) async throws -> [RemoteEntry] {
        try await perform { sftp in
            try await sftp.listDirectory(atPath: path)
                .flatMap(\.components)
                .filter { $0.filename != "." && $0.filename != ".." }
                .map { component in
                    var entry = Self.entry(path: RemotePath.join(path, component.filename),
                                           attributes: component.attributes, longname: component.longname)
                    if Self.isSymlink(component.attributes, longname: component.longname) { entry.kind = .file }
                    return entry
                }
        }
    }

    // MARK: - Attribute decoding

    private static let typeMask: UInt32 = 0o170000

    private static func kind(of attributes: SFTPFileAttributes, longname: String = "") -> RemoteEntry.Kind {
        if let permissions = attributes.permissions, permissions & typeMask != 0 {
            return permissions & typeMask == 0o040000 ? .directory : .file
        }
        return longname.hasPrefix("d") ? .directory : .file
    }

    private static func isSymlink(_ attributes: SFTPFileAttributes, longname: String) -> Bool {
        if let permissions = attributes.permissions, permissions & typeMask != 0 {
            return permissions & typeMask == 0o120000
        }
        return longname.hasPrefix("l")
    }

    private static func entry(path: String, attributes: SFTPFileAttributes, longname: String) -> RemoteEntry {
        RemoteEntry(
            path: path,
            name: RemotePath.name(of: path),
            kind: kind(of: attributes, longname: longname),
            size: attributes.size ?? 0,
            modified: attributes.accessModificationTime?.modificationTime ?? .distantPast,
            permissions: attributes.permissions ?? 0o644)
    }
}
