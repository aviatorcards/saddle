import Foundation
import CryptoKit
import FileProvider
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
    /// True when the entry is a symbolic link. Links that resolve inside the mount carry
    /// their target's attributes, so a link to a folder is browsable like that folder.
    var isSymlink = false

    var isDirectory: Bool { kind == .directory }

    /// Changes whenever the content changes. Size + mtime is all SFTP v3 gives us.
    /// Mtime is whole seconds, so two edits in the same second with the same size compare equal.
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

    /// A single path component Finder or the server is allowed to introduce.
    static func isSafeComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\0")
    }

    /// Lexically join `relative` onto `root` and reject `..` that would leave `root`.
    ///
    /// This does not defeat a symlink the server resolves itself. It does stop a
    /// listing name or a stored path of `../` from being concatenated out of the mount.
    static func resolved(_ relative: String, under root: String) -> String? {
        let rootParts = parts(of: root)
        var combined = rootParts
        for component in parts(of: relative) {
            if component == "." { continue }
            if component.contains("\0") { return nil }
            if component == ".." {
                guard combined.count > rootParts.count else { return nil }
                combined.removeLast()
                continue
            }
            combined.append(component)
        }
        if combined.isEmpty { return "/" }
        return "/" + combined.joined(separator: "/")
    }

    static func isPartialUpload(_ name: String) -> Bool {
        name.hasPrefix(".saddle-") && name.hasSuffix(".part")
    }

    /// Name for the copy an overwrite moves aside. It records the original name, so a
    /// listing can hide a backup while the original exists and show it if it doesn't.
    static func backupName(for original: String) -> String {
        let tag = UUID().uuidString.prefix(8).lowercased()
        let name = ".saddle-\(tag).\(original).bak"
        return name.utf8.count <= 255 ? name : ".saddle-\(UUID().uuidString).bak"
    }

    /// The original file name recorded by `backupName(for:)`, if this is such a backup.
    static func originalName(ofBackup name: String) -> String? {
        guard name.hasPrefix(".saddle-"), name.hasSuffix(".bak") else { return nil }
        let body = name.dropFirst(".saddle-".count).dropLast(".bak".count)
        guard body.count > 9, body[body.index(body.startIndex, offsetBy: 8)] == "." else { return nil }
        let original = String(body.dropFirst(9))
        return isSafeComponent(original) ? original : nil
    }

    /// Whether `path` is `root` or below it. Both must already be canonical (realpath'd).
    static func isInside(_ path: String, root: String) -> Bool {
        root == "/" || path == root || path.hasPrefix(root + "/")
    }

    private static func parts(of path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }
}

/// One SSH connection to a server with a small pool of multiplexed SFTP channels.
///
/// Citadel's `SFTPClient` matches replies to requests by ID on the channel's event loop,
/// so operations can overlap on one channel. Channels are opened up to `maxConnections`
/// and shared round-robin, so a long transfer never blocks a listing.
/// Reads are retried once after a dropped connection. Mutations are not: a delete or
/// rename that succeeded on the server but lost its reply must not be blindly repeated.
actor SFTPSession {
    private(set) var profile: ConnectionProfile

    private var client: SSHClient?
    private var channels: [SFTPClient] = []
    private var nextChannel = 0
    private var openingChannels = 0
    private var connecting: Task<SSHClient, Error>?
    private var keepAlive: Task<Void, Never>?
    private var lastActivity = Date()

    /// Absolute remote path that maps to the root of the mounted location.
    private(set) var rootPath: String?

    /// Listing attributes are reused for a short time so a stat that follows a listing
    /// does not open another request for the same path.
    private var metadata = MetadataCache<RemoteEntry>(ttl: 30)
    /// Name lists Citadel already buffered, plus the entries resolved for pages Finder asked for.
    private var directories: [String: OpenDirectory] = [:]
    private let directoryTTL: TimeInterval = 120

    private struct OpenDirectory {
        var children: [RawChild]
        var resolved: [Int: RemoteEntry] = [:]
        var at: Date
    }

    private struct RawChild: Sendable {
        var index: Int
        var name: String
        var path: String
        var attributes: SFTPFileAttributes
        var longname: String
        var isSymlink: Bool
        var needsRequest: Bool
        var ready: RemoteEntry?
    }

    private static let readChunk: UInt32 = 128 * 1024
    private static let writeChunk = 256 * 1024

    init(profile: ConnectionProfile) {
        self.profile = profile
    }

    /// Applies a profile edited while the domain is mounted.
    /// Connection-defining changes drop the session so the next call reconnects.
    func adopt(_ profile: ConnectionProfile) async {
        let reconnect = profile.host != self.profile.host
            || profile.port != self.profile.port
            || profile.username != self.profile.username
            || profile.remotePath != self.profile.remotePath
            || profile.authMethod != self.profile.authMethod
            || profile.privateKeyName != self.profile.privateKeyName
        self.profile = profile
        if reconnect {
            await close()
        }
    }

    // MARK: - Connection lifecycle

    /// Connects (if needed) and resolves the root directory.
    @discardableResult
    func connect() async throws -> String {
        if let rootPath, client?.isConnected == true { return rootPath }
        let requested = profile.remotePath.trimmingCharacters(in: .whitespaces)
        let resolved = try await withChannel { sftp in
            try await sftp.getRealPath(atPath: requested.isEmpty ? "." : requested)
        }
        let attributes = try await withChannel { try await $0.getAttributes(at: resolved) }
        guard Self.kind(of: attributes) == .directory else { throw SaddleError.notADirectory(resolved) }
        rootPath = resolved
        return resolved
    }

    func close() async {
        keepAlive?.cancel()
        keepAlive = nil
        metadata.removeAll()
        directories.removeAll()
        rootPath = nil
        let open = channels
        channels.removeAll()
        let oldClient = client
        client = nil
        connecting?.cancel()
        connecting = nil
        for channel in open { try? await channel.close() }
        try? await oldClient?.close()
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
            // macOS Local Network privacy blocks connections as EHOSTUNREACH ("No route to host").
            let description = String(describing: error)
            if description.contains("No route to host") || description.contains("errno: 65") {
                throw SaddleError.connectionFailed(
                    "no route to \(settings.host). If it's on your local network, allow Saddle in System Settings › Privacy & Security › Local Network.")
            }
            throw SaddleError.connectionFailed(publicDescription(of: error))
        }
    }

    /// Avoid writing passwords, passphrases, or key material into the activity log.
    static func publicDescription(of error: Error) -> String {
        let text = String(describing: error).replacingOccurrences(of: "\n", with: " ")
        let lower = text.lowercased()
        if lower.contains("private key") || lower.contains("passphrase") || lower.contains("password") {
            return "the secure connection could not be established"
        }
        return String(text.prefix(300))
    }

    private func makeSettings() throws -> (settings: SSHClientSettings, validator: KnownHostValidator) {
        let username = profile.username
        let authentication: SSHAuthenticationMethod
        let shared = SecretStore.sharesWithExtension

        switch profile.authMethod {
        case .password:
            guard let password = SecretStore.string(for: profile.id, kind: .password) else {
                throw SaddleError.missingCredentials(shared
                    ? "no password saved for \(profile.displayName)"
                    : "no password is available to the file provider for \(profile.displayName). Sign Saddle with a development team so the shared Keychain works.")
            }
            authentication = .passwordBased(username: username, password: password)
        case .privateKey:
            guard let keyText = SecretStore.string(for: profile.id, kind: .privateKey) else {
                throw SaddleError.missingCredentials(shared
                    ? "no private key imported for \(profile.displayName)"
                    : "no private key is available to the file provider for \(profile.displayName). Sign Saddle with a development team so the shared Keychain works.")
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

    /// Returns a channel for the next operation. Opens channels up to `maxConnections`,
    /// then shares them round-robin. Requests overlap safely on one channel.
    private func acquire(touchActivity: Bool) async throws -> SFTPClient {
        let limit = max(1, profile.maxConnections)
        while true {
            try Task.checkCancellation()
            channels.removeAll { !$0.isActive }
            if touchActivity { lastActivity = Date() }

            if channels.count + openingChannels < limit {
                // Count this open before the first await. Otherwise two callers both
                // pass the check and both open a channel.
                openingChannels += 1
                defer { openingChannels -= 1 }
                let ssh = try await sshClient()
                let opened = try await ssh.openSFTP()
                channels.append(opened)
                return opened
            }
            if !channels.isEmpty {
                nextChannel = (nextChannel + 1) % channels.count
                return channels[nextChannel]
            }
            // Every allowed channel is still being opened by another caller.
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func withChannel<T>(_ operation: (SFTPClient) async throws -> T, touchActivity: Bool = true) async throws -> T {
        try await operation(try await acquire(touchActivity: touchActivity))
    }

    /// Runs a read, reconnecting and retrying once if the connection dropped.
    /// Do not use this for delete, rename, or upload.
    private func performRead<T>(_ operation: (SFTPClient) async throws -> T) async throws -> T {
        do {
            return try await withChannel(operation)
        } catch {
            guard Self.isConnectionError(error) else { throw error }
            await close()
            return try await withChannel(operation)
        }
    }

    static func statusCode(_ error: Error) -> SFTPStatusCode? {
        if let status = error as? SFTPMessage.Status { return status.errorCode }
        if let sftpError = error as? SFTPError, case .errorStatus(let status) = sftpError {
            return status.errorCode
        }
        return nil
    }

    static func isMissing(_ error: Error) -> Bool {
        statusCode(error) == .noSuchFile
    }

    /// Local I/O and SFTP status codes are not connection losses. Retrying them
    /// closed every channel and repeated deletes and renames.
    static func isConnectionError(_ error: Error) -> Bool {
        if error is CancellationError || error is SaddleError || error is CocoaError { return false }
        if statusCode(error) != nil { return false }
        if let sftpError = error as? SFTPError {
            switch sftpError {
            case .connectionClosed, .missingResponse: return true
            default: return false
            }
        }
        if error is SSHClientError { return true }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain || nsError.domain == NSFileProviderErrorDomain { return false }
        if nsError.domain == NSPOSIXErrorDomain {
            switch POSIXErrorCode(rawValue: Int32(nsError.code)) {
            case .ECONNRESET, .ENOTCONN, .EPIPE, .ETIMEDOUT, .ECONNABORTED, .ENETDOWN, .ENETRESET, .EHOSTUNREACH, .ENETUNREACH:
                return true
            default:
                return false
            }
        }
        let description = String(describing: error).lowercased()
        return description.contains("connection reset")
            || description.contains("broken pipe")
            || description.contains("connection closed")
            || description.contains("not active")
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

    /// `getRealPath` follows links. Refuse a path whose canonical location is outside the mount.
    /// Returns nil when the mount root is not known yet (during connect).
    private func realPathInsideMount(_ path: String, using sftp: SFTPClient) async throws -> String? {
        guard let rootPath else { return nil }
        let real = try await sftp.getRealPath(atPath: path)
        guard RemotePath.isInside(real, root: rootPath) else { throw SaddleError.outsideMount }
        return real
    }

    struct ListedPage: Sendable {
        var entries: [RemoteEntry]
        /// Offset of the next page. Nil means Finder has the last page.
        var nextOffset: Int?
    }

    /// One page of a directory. Offset 0 reads the name list again.
    ///
    /// Citadel 0.12's `listDirectory` buffers every `readdir` response, so the names for
    /// this directory are complete before the first page is returned. Extra stats run
    /// only for this page, and they share the channel pool.
    func listPage(_ path: String, offset: Int, limit: Int) async throws -> ListedPage {
        let limit = max(1, limit)
        if offset == 0 || directories[path] == nil || isStale(directories[path]) {
            try await refreshDirectory(path)
        }
        guard let directory = directories[path] else {
            return ListedPage(entries: [], nextOffset: nil)
        }
        let bounds = DirectoryPage.bounds(itemCount: directory.children.count, offset: offset, pageSize: limit)
        if bounds.start < bounds.end {
            try await resolve(path: path, range: bounds.start..<bounds.end)
        }
        let entries = (bounds.start..<bounds.end).compactMap { directories[path]?.resolved[$0] }
        return ListedPage(entries: entries, nextOffset: bounds.nextOffset)
    }

    /// Every child Finder is allowed to see. Reuses a listing that is already being paged.
    func list(_ path: String) async throws -> [RemoteEntry] {
        if directories[path] == nil || isStale(directories[path]) {
            try await refreshDirectory(path)
        }
        let count = directories[path]?.children.count ?? 0
        if count > 0 {
            try await resolve(path: path, range: 0..<count)
        }
        return (0..<count).compactMap { directories[path]?.resolved[$0] }
    }

    /// Lists several directories at once, up to the channel limit. One failure does not cancel the others.
    func listMany(_ paths: [String]) async -> [Result<[RemoteEntry], Error>] {
        var results = Array(repeating: Result<[RemoteEntry], Error>.success([]), count: paths.count)
        let width = max(1, profile.maxConnections)
        var nextIndex = 0
        await withTaskGroup(of: (Int, Result<[RemoteEntry], Error>).self) { group in
            func schedule() {
                guard nextIndex < paths.count else { return }
                let index = nextIndex
                let path = paths[index]
                nextIndex += 1
                group.addTask {
                    do {
                        return (index, .success(try await self.list(path)))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            for _ in 0..<min(width, paths.count) { schedule() }
            while let finished = await group.next() {
                results[finished.0] = finished.1
                schedule()
            }
        }
        return results
    }

    /// Children of a directory that was just listed, for choosing what to prefetch.
    /// A symlink that has not been resolved is treated as escaping the mount.
    func prefetchSources(at path: String) -> [PrefetchCandidate] {
        guard let directory = directories[path] else { return [] }
        return directory.children.map { child in
            if let entry = directory.resolved[child.index] {
                return PrefetchCandidate(
                    name: entry.name,
                    size: entry.size,
                    isDirectory: entry.isDirectory,
                    isHidden: entry.name.hasPrefix("."),
                    isPartial: RemotePath.isPartialUpload(entry.name),
                    isSymlink: entry.isSymlink,
                    symlinkEscapesMount: false)
            }
            if child.isSymlink {
                return PrefetchCandidate(
                    name: child.name,
                    size: child.attributes.size ?? 0,
                    isHidden: child.name.hasPrefix("."),
                    isSymlink: true,
                    symlinkEscapesMount: true)
            }
            let entry = child.ready
            return PrefetchCandidate(
                name: child.name,
                size: entry?.size ?? child.attributes.size ?? 0,
                isDirectory: entry?.isDirectory ?? (Self.kind(of: child.attributes, longname: child.longname) == .directory),
                isHidden: child.name.hasPrefix("."),
                isPartial: RemotePath.isPartialUpload(child.name))
        }
    }

    private func isStale(_ directory: OpenDirectory?) -> Bool {
        guard let directory else { return true }
        return Date().timeIntervalSince(directory.at) > directoryTTL
    }

    private func refreshDirectory(_ path: String) async throws {
        let children = try await rawListing(path)
        var directory = OpenDirectory(children: children, at: Date())
        for child in children {
            if let ready = child.ready {
                directory.resolved[child.index] = ready
                remember(ready)
            }
        }
        directories[path] = directory
    }

    /// Citadel buffers the whole name list. This does not stat each child.
    private func rawListing(_ path: String) async throws -> [RawChild] {
        try await performRead { sftp in
            do {
                _ = try await realPathInsideMount(path, using: sftp)
            } catch SaddleError.outsideMount {
                return []
            }
            let components = try await sftp.listDirectory(atPath: path).flatMap(\.components)
            let names = Set(components.map(\.filename))
            var children: [RawChild] = []
            for component in components {
                let name = component.filename
                guard RemotePath.isSafeComponent(name) else { continue }
                if RemotePath.isPartialUpload(name) { continue }
                if let original = RemotePath.originalName(ofBackup: name), names.contains(original) { continue }
                let childPath = RemotePath.join(path, name)
                let symlink = Self.isSymlink(component.attributes, longname: component.longname)
                let needsRequest = RemoteListing.needsExtraRequest(
                    hasSize: component.attributes.size != nil,
                    hasModified: component.attributes.accessModificationTime != nil,
                    hasPermissions: component.attributes.permissions != nil,
                    isSymlink: symlink)
                let ready = needsRequest ? nil : Self.entry(path: childPath, attributes: component.attributes, longname: component.longname)
                children.append(RawChild(
                    index: children.count,
                    name: name,
                    path: childPath,
                    attributes: component.attributes,
                    longname: component.longname,
                    isSymlink: symlink,
                    needsRequest: needsRequest,
                    ready: ready))
            }
            return children
        }
    }

    private func resolve(path: String, range: Range<Int>) async throws {
        guard let directory = directories[path] else { return }
        let pending = range.filter { directory.resolved[$0] == nil }
        if pending.isEmpty { return }
        let width = max(1, profile.maxConnections)
        var cursor = 0
        try await withThrowingTaskGroup(of: (Int, RemoteEntry?).self) { group in
            func schedule() {
                guard cursor < pending.count else { return }
                let index = pending[cursor]
                cursor += 1
                let child = directory.children[index]
                group.addTask {
                    let entry = try await self.resolveChild(child)
                    return (index, entry)
                }
            }
            for _ in 0..<min(width, pending.count) { schedule() }
            while let finished = try await group.next() {
                if let entry = finished.1 {
                    directories[path]?.resolved[finished.0] = entry
                    remember(entry)
                }
                schedule()
            }
        }
    }

    private func resolveChild(_ child: RawChild) async throws -> RemoteEntry? {
        if let ready = child.ready { return ready }
        if child.isSymlink {
            return try await performRead { sftp in
                try await followLink(child.path, using: sftp)?.entry
            }
        }
        return try await performRead { sftp in
            do {
                _ = try await realPathInsideMount(child.path, using: sftp)
            } catch SaddleError.outsideMount {
                return nil
            }
            return Self.entry(path: child.path, attributes: try await sftp.getAttributes(at: child.path), longname: child.longname)
        }
    }

    private func remember(_ entry: RemoteEntry) {
        metadata.insert(entry, for: entry.path, at: Date())
    }

    private func forget(path: String) {
        metadata.remove(prefix: path)
        directories[path] = nil
        let parent = RemotePath.parent(of: path)
        if parent != path { directories[parent] = nil }
    }

    /// Metadata for a symbolic link's target, and the target's canonical path.
    /// Nil when the link is dangling or resolves outside the mounted folder.
    func resolveLink(_ path: String) async throws -> (entry: RemoteEntry, target: String)? {
        try await performRead { try await followLink(path, using: $0) }
    }

    private func followLink(_ path: String, using sftp: SFTPClient) async throws -> (entry: RemoteEntry, target: String)? {
        guard let rootPath else { return nil }
        do {
            let target = try await sftp.getRealPath(atPath: path)
            guard RemotePath.isInside(target, root: rootPath) else { return nil }
            var entry = Self.entry(path: path, attributes: try await sftp.getAttributes(at: target), longname: "")
            entry.isSymlink = true
            return (entry, target)
        } catch {
            // Server-side failures (dangling link, no permission) just mean "don't show it".
            if Self.statusCode(error) != nil { return nil }
            throw error
        }
    }

    func stat(_ path: String) async throws -> RemoteEntry {
        if let cached = metadata.lookup(path, at: Date()) { return cached }
        let entry = try await performRead { sftp in
            _ = try await realPathInsideMount(path, using: sftp)
            return Self.entry(path: path, attributes: try await sftp.getAttributes(at: path), longname: "")
        }
        remember(entry)
        return entry
    }

    func exists(_ path: String) async throws -> Bool {
        do {
            _ = try await stat(path)
            return true
        } catch {
            if Self.isMissing(error) { return false }
            throw error
        }
    }

    // MARK: - Transfers

    /// Streams a remote file to `localURL` in chunks, reporting cumulative bytes.
    func download(_ path: String, to localURL: URL, progress: @Sendable (Int64) -> Void) async throws {
        try await performRead { sftp in
            _ = try await realPathInsideMount(path, using: sftp)
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
    /// Bytes land in a temporary sibling first. The destination is renamed aside and
    /// the temporary file renamed into place, then the aside copy is removed. The
    /// previous file is not deleted until the new bytes are complete, and it is put
    /// back if the final rename fails.
    func upload(from localURL: URL?, to path: String, progress: @Sendable (Int64) -> Void) async throws {
        let parent = RemotePath.parent(of: path)
        let temporary = RemotePath.join(parent, ".saddle-\(UUID().uuidString).part")
        let backup = RemotePath.join(parent, RemotePath.backupName(for: RemotePath.name(of: path)))

        try await withChannel { sftp in
            // A missing destination is fine; its parent still has to resolve inside the mount.
            // An existing path that is a link to somewhere else must not be overwritten.
            do {
                _ = try await realPathInsideMount(path, using: sftp)
            } catch {
                guard Self.isMissing(error) else { throw error }
                let parent = RemotePath.parent(of: path)
                if parent != path {
                    _ = try await realPathInsideMount(parent, using: sftp)
                }
            }
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

            let replaced = (try? await sftp.getAttributes(at: path)) != nil
            if replaced {
                do {
                    try await sftp.rename(at: path, to: backup)
                } catch {
                    try? await sftp.remove(at: temporary)
                    throw error
                }
            }
            do {
                try await sftp.rename(at: temporary, to: path)
            } catch {
                if replaced {
                    try? await sftp.rename(at: backup, to: path)
                }
                try? await sftp.remove(at: temporary)
                throw error
            }
            if replaced {
                try? await sftp.remove(at: backup)
            }
        }
        forget(path: path)
    }

    // MARK: - Mutations

    func createDirectory(_ path: String) async throws {
        try await withChannel { try await $0.createDirectory(atPath: path) }
        forget(path: path)
    }

    func rename(_ path: String, to newPath: String) async throws {
        do {
            try await withChannel { try await $0.rename(at: path, to: newPath) }
        } catch {
            guard Self.isConnectionError(error) else { throw error }
            // The reply may have been lost after the server applied the rename.
            await close()
            let sourceExists = (try? await exists(path)) ?? false
            let destinationExists = (try? await exists(newPath)) ?? false
            if !sourceExists && destinationExists { return }
            if sourceExists && !destinationExists {
                try await withChannel { try await $0.rename(at: path, to: newPath) }
                forget(path: path)
                forget(path: newPath)
                return
            }
            throw error
        }
        forget(path: path)
        forget(path: newPath)
    }

    func setModificationDate(_ date: Date, for path: String) async throws {
        try await withChannel { sftp in
            var attributes = SFTPFileAttributes()
            attributes.accessModificationTime = .init(accessTime: date, modificationTime: date)
            try await sftp.setAttributes(at: path, to: attributes)
        }
        forget(path: path)
    }

    func setPermissions(_ permissions: UInt32, for path: String) async throws {
        try await withChannel { sftp in
            var attributes = SFTPFileAttributes()
            attributes.permissions = permissions & 0o7777
            try await sftp.setAttributes(at: path, to: attributes)
        }
        forget(path: path)
    }

    /// Missing files count as success so a lost reply doesn't abort a recursive delete.
    func removeFile(_ path: String) async throws {
        do {
            try await withChannel { try await $0.remove(at: path) }
        } catch {
            if Self.isMissing(error) {
                forget(path: path)
                return
            }
            throw error
        }
        forget(path: path)
    }

    /// Removes a directory. With `recursive`, deletes its contents first (depth-first).
    func removeDirectory(_ path: String, recursive: Bool) async throws {
        // Unlinking a symlink is removeFile, which does not follow the link. Removing a
        // directory must not follow one: rawChildren would then delete the link's target.
        _ = try await withChannel { try await realPathInsideMount(path, using: $0) }
        if recursive {
            for child in try await rawChildren(of: path) {
                if child.isDirectory {
                    try await removeDirectory(child.path, recursive: true)
                } else {
                    try await removeFile(child.path)
                }
            }
        }
        do {
            try await withChannel { try await $0.rmdir(at: path) }
        } catch {
            if Self.isMissing(error) { return }
            throw error
        }
        forget(path: path)
    }

    /// Children without following symlinks, so recursive deletes never escape the tree.
    private func rawChildren(of path: String) async throws -> [RemoteEntry] {
        try await performRead { sftp in
            try await sftp.listDirectory(atPath: path)
                .flatMap(\.components)
                .filter { RemotePath.isSafeComponent($0.filename) }
                .map { component in
                    var entry = Self.entry(path: RemotePath.join(path, component.filename),
                                           attributes: component.attributes, longname: component.longname)
                    if Self.isSymlink(component.attributes, longname: component.longname) {
                        entry.isSymlink = true
                        entry.kind = .file
                    }
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
