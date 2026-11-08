import FileProvider
import UniformTypeIdentifiers
import Citadel

/// Replicated File Provider for one SFTP connection (one domain per saved profile).
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    private let domain: NSFileProviderDomain
    private let profile: ConnectionProfile?
    private let session: SFTPSession?
    private let state: DomainState?
    private let status: StatusReporter?

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        let profile = ProfileStore.profile(for: domain.identifier)
        self.profile = profile
        session = profile.map(SFTPSession.init(profile:))
        state = profile.map { DomainState(profileID: $0.id) }
        status = profile.map { StatusReporter(profileID: $0.id) }
        super.init()
    }

    func invalidate() {
        let session = session, state = state, status = status
        Task {
            await session?.close()
            await state?.flush()
            await status?.set(.idle)
        }
    }

    // MARK: - Bridging

    /// Runs async work for a completion-handler based File Provider call and wires up cancellation.
    private func run<T>(_ progress: Progress, _ work: @escaping () async throws -> T,
                        completion: @escaping (Result<T, Error>) -> Void) -> Progress {
        let task = Task {
            do {
                completion(.success(try await work()))
            } catch {
                completion(.failure(Self.fileProviderError(error)))
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    private struct Context {
        let session: SFTPSession
        let state: DomainState
        let status: StatusReporter
        let root: String
    }

    /// Connects if necessary and returns everything an operation needs.
    private func context() async throws -> Context {
        guard let session, let state, let status else { throw SaddleError.profileNotFound }
        do {
            let root = try await session.connect()
            await status.set(.connected)
            return Context(session: session, state: state, status: status, root: root)
        } catch {
            await status.set(.error, message: error.localizedDescription)
            throw error
        }
    }

    // MARK: - Paths

    private static func join(_ parent: String, _ name: String) -> String {
        parent.isEmpty ? name : parent + "/" + name
    }

    private static func parent(of relativePath: String) -> String {
        guard let slash = relativePath.lastIndex(of: "/") else { return "" }
        return String(relativePath[..<slash])
    }

    private func absolute(_ relativePath: String, in context: Context) -> String {
        relativePath.isEmpty ? context.root : RemotePath.join(context.root, relativePath)
    }

    private func relativePath(for identifier: NSFileProviderItemIdentifier, in context: Context) async throws -> String {
        guard let path = await context.state.relativePath(for: identifier) else {
            throw NSFileProviderError(.noSuchItem)
        }
        return path
    }

    private func makeItem(_ entry: RemoteEntry, relativePath: String, in context: Context) async -> FileProviderItem {
        let identifier = await context.state.identifier(for: relativePath)
        if relativePath.isEmpty {
            return FileProviderItem(entry: entry, identifier: .rootContainer, parent: .rootContainer,
                                    filename: profile?.displayName ?? entry.name)
        }
        let parent = await context.state.identifier(for: Self.parent(of: relativePath))
        return FileProviderItem(entry: entry, identifier: identifier, parent: parent)
    }

    /// Picks `name 2.ext`, `name 3.ext`, … so a remote file is never silently overwritten.
    private func uniqueRelativePath(in parent: String, preferredName name: String, context: Context) async throws -> String {
        let candidate = Self.join(parent, name)
        guard try await context.session.exists(absolute(candidate, in: context)) else { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for index in 2...999 {
            let next = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let path = Self.join(parent, next)
            if try await !context.session.exists(absolute(path, in: context)) { return path }
        }
        throw NSFileProviderError(.filenameCollision)
    }

    // MARK: - Enumeration support

    func listItems(in container: NSFileProviderItemIdentifier) async throws -> [FileProviderItem] {
        let context = try await context()
        guard container != .trashContainer else { throw NSFileProviderError(.noSuchItem) }
        let directory = try await relativePath(for: container, in: context)
        let entries = try await context.session.list(absolute(directory, in: context))

        var items: [FileProviderItem] = []
        var snapshot: [String: String] = [:]
        for entry in entries {
            let item = await makeItem(entry, relativePath: Self.join(directory, entry.name), in: context)
            snapshot[item.itemIdentifier.rawValue] = entry.metadataVersion
            items.append(item)
        }
        await context.state.setSnapshot(snapshot, of: container)
        return items
    }

    /// Re-lists every directory that has been enumerated and reports what changed remotely.
    func pollRemoteChanges() async throws -> (updated: [FileProviderItem], deleted: [NSFileProviderItemIdentifier]) {
        let context = try await context()
        var updated: [FileProviderItem] = []
        var deleted: [NSFileProviderItemIdentifier] = []

        for directoryID in await context.state.snapshotDirectories {
            try Task.checkCancellation()
            guard let directory = await context.state.relativePath(for: directoryID),
                  let previous = await context.state.snapshot(of: directoryID) else {
                await context.state.dropSnapshot(of: directoryID)
                continue
            }

            let entries: [RemoteEntry]
            do {
                entries = try await context.session.list(absolute(directory, in: context))
            } catch let status as SFTPMessage.Status where status.errorCode == .noSuchFile {
                if directoryID != .rootContainer {
                    deleted.append(directoryID)
                    await context.state.remove(directory)
                }
                continue
            }

            var current: [String: String] = [:]
            for entry in entries {
                let item = await makeItem(entry, relativePath: Self.join(directory, entry.name), in: context)
                current[item.itemIdentifier.rawValue] = entry.metadataVersion
                if previous[item.itemIdentifier.rawValue] != entry.metadataVersion {
                    updated.append(item)
                }
            }
            for (childID, _) in previous where current[childID] == nil {
                let identifier = NSFileProviderItemIdentifier(childID)
                deleted.append(identifier)
                if let path = await context.state.relativePath(for: identifier) {
                    await context.state.remove(path)
                }
            }
            await context.state.setSnapshot(current, of: directoryID)
        }
        return (updated, deleted)
    }

    // MARK: - NSFileProviderReplicatedExtension

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        run(Progress(), { [self] in
            guard identifier != .trashContainer, identifier != .workingSet else { throw NSFileProviderError(.noSuchItem) }
            let context = try await context()
            let path = try await relativePath(for: identifier, in: context)
            let entry = try await context.session.stat(absolute(path, in: context))
            return await makeItem(entry, relativePath: path, in: context)
        }) { result in
            switch result {
            case .success(let item): completionHandler(item, nil)
            case .failure(let error): completionHandler(nil, error)
            }
        }
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 0)
        return run(progress, { [self] in
            let context = try await context()
            let path = try await relativePath(for: itemIdentifier, in: context)
            let remotePath = absolute(path, in: context)
            let entry = try await context.session.stat(remotePath)
            guard !entry.isDirectory else { throw NSFileProviderError(.noSuchItem) }

            guard let manager = NSFileProviderManager(for: domain) else { throw NSFileProviderError(.providerNotFound) }
            let destination = try manager.temporaryDirectoryURL().appending(path: UUID().uuidString)
            progress.totalUnitCount = Int64(entry.size)

            let transfer = await context.status.beginTransfer(name: entry.name, isUpload: false, totalBytes: Int64(entry.size))
            do {
                let status = context.status
                try await context.session.download(remotePath, to: destination) { bytes in
                    progress.completedUnitCount = bytes
                    Task { await status.updateTransfer(transfer, completedBytes: bytes) }
                }
                await context.status.endTransfer(transfer, error: nil)
            } catch {
                await context.status.endTransfer(transfer, error: error)
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
            // Re-stat so the returned version matches the bytes we actually downloaded.
            let latest = (try? await context.session.stat(remotePath)) ?? entry
            return (destination, await makeItem(latest, relativePath: path, in: context))
        }) { result in
            switch result {
            case .success(let (url, item)): completionHandler(url, item, nil)
            case .failure(let error): completionHandler(nil, nil, error)
            }
        }
    }

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 0)
        return run(progress, { [self] in
            let context = try await context()
            let contentType = itemTemplate.contentType ?? .data
            if contentType.conforms(to: .symbolicLink) {
                throw NSFileProviderError(.cannotSynchronize)
            }
            let isFolder = contentType.conforms(to: .folder) || contentType.conforms(to: .directory)

            let parent = try await relativePath(for: itemTemplate.parentItemIdentifier, in: context)
            var path = Self.join(parent, itemTemplate.filename)

            // During re-imports the item may already be on the server; adopt it as-is.
            if options.contains(.mayAlreadyExist), let existing = try? await context.session.stat(absolute(path, in: context)),
               existing.isDirectory == isFolder {
                return await makeItem(existing, relativePath: path, in: context)
            }

            path = try await uniqueRelativePath(in: parent, preferredName: itemTemplate.filename, context: context)
            let remotePath = absolute(path, in: context)

            if isFolder {
                try await context.session.createDirectory(remotePath)
            } else {
                try await upload(url, to: remotePath, name: itemTemplate.filename, progress: progress, context: context)
                if fields.contains(.contentModificationDate), let date = itemTemplate.contentModificationDate ?? nil {
                    try? await context.session.setModificationDate(date, for: remotePath)
                }
                if itemTemplate.fileSystemFlags?.contains(.userExecutable) == true {
                    try? await context.session.setPermissions(0o755, for: remotePath)
                }
            }

            let entry = try await context.session.stat(remotePath)
            let item = await makeItem(entry, relativePath: path, in: context)
            await context.state.updateChild(item.itemIdentifier, version: entry.metadataVersion, in: item.parentItemIdentifier)
            return item
        }) { result in
            switch result {
            case .success(let item): completionHandler(item, [], false, nil)
            case .failure(let error): completionHandler(nil, [], false, error)
            }
        }
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields,
                    contents newContents: URL?, options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 0)
        return run(progress, { [self] in
            let context = try await context()
            var path = try await relativePath(for: item.itemIdentifier, in: context)
            let oldParentID = await context.state.identifier(for: Self.parent(of: path))
            var current = try await context.session.stat(absolute(path, in: context))

            // Rename and/or move.
            if !path.isEmpty, changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
                let newParent = try await relativePath(for: item.parentItemIdentifier, in: context)
                if Self.join(newParent, item.filename) != path {
                    let target = try await uniqueRelativePath(in: newParent, preferredName: item.filename, context: context)
                    try await context.session.rename(absolute(path, in: context), to: absolute(target, in: context))
                    await context.state.move(from: path, to: target)
                    await context.state.updateChild(item.itemIdentifier, version: nil, in: oldParentID)
                    path = target
                }
            }
            let remotePath = absolute(path, in: context)

            // New file contents.
            if changedFields.contains(.contents), !current.isDirectory {
                if Data(current.contentVersion.utf8) != version.contentVersion {
                    // The server copy changed since the Mac last saw it. Keep both: upload the
                    // local edit as a conflict copy, and let Finder pick up the server version.
                    try await uploadConflictCopy(newContents, of: path, progress: progress, context: context)
                } else {
                    try await upload(newContents, to: remotePath, name: item.filename, progress: progress, context: context)
                    if let date = item.contentModificationDate ?? nil {
                        try? await context.session.setModificationDate(date, for: remotePath)
                    }
                }
            } else if changedFields.contains(.contentModificationDate), let date = item.contentModificationDate ?? nil {
                try? await context.session.setModificationDate(date, for: remotePath)
            }

            // Toggle the execute bits (chmod +x / -x) from Finder.
            if changedFields.contains(.fileSystemFlags), !current.isDirectory, let flags = item.fileSystemFlags {
                current = try await context.session.stat(remotePath)
                let readBits = current.permissions & 0o444
                let permissions = flags.contains(.userExecutable)
                    ? current.permissions | (readBits >> 2)
                    : current.permissions & ~0o111
                if permissions != current.permissions {
                    try? await context.session.setPermissions(permissions, for: remotePath)
                }
            }

            let entry = try await context.session.stat(remotePath)
            let updated = await makeItem(entry, relativePath: path, in: context)
            await context.state.updateChild(updated.itemIdentifier, version: entry.metadataVersion, in: updated.parentItemIdentifier)
            return updated
        }) { result in
            switch result {
            case .success(let item): completionHandler(item, [], false, nil)
            case .failure(let error): completionHandler(nil, [], false, error)
            }
        }
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        run(Progress(), { [self] in
            guard identifier != .rootContainer else { throw NSFileProviderError(.deletionRejected) }
            let context = try await context()
            let path = try await relativePath(for: identifier, in: context)
            let remotePath = absolute(path, in: context)
            let parentID = await context.state.identifier(for: Self.parent(of: path))

            // Already gone on the server: nothing to do.
            if let entry = try? await context.session.stat(remotePath) {
                if entry.isDirectory {
                    let recursive = options.contains(.recursive)
                    do {
                        try await context.session.removeDirectory(remotePath, recursive: recursive)
                    } catch let status as SFTPMessage.Status where !recursive && status.errorCode == .failure {
                        throw NSFileProviderError(.directoryNotEmpty)
                    }
                } else {
                    try await context.session.removeFile(remotePath)
                }
                await context.status.log("Deleted \(entry.name)")
            }
            await context.state.remove(path)
            await context.state.updateChild(identifier, version: nil, in: parentID)
        }) { result in
            switch result {
            case .success: completionHandler(nil)
            case .failure(let error): completionHandler(error)
            }
        }
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        guard profile != nil else { throw NSFileProviderError(.notAuthenticated) }
        guard containerItemIdentifier != .trashContainer else { throw NSFileProviderError(.noSuchItem) }
        return FileProviderEnumerator(container: containerItemIdentifier, provider: self)
    }

    // MARK: - Uploads

    private func upload(_ localURL: URL?, to remotePath: String, name: String, progress: Progress, context: Context) async throws {
        let size = localURL.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? 0
        progress.totalUnitCount = Int64(size)
        let transfer = await context.status.beginTransfer(name: name, isUpload: true, totalBytes: Int64(size))
        do {
            let status = context.status
            try await context.session.upload(from: localURL, to: remotePath) { bytes in
                progress.completedUnitCount = bytes
                Task { await status.updateTransfer(transfer, completedBytes: bytes) }
            }
            await context.status.endTransfer(transfer, error: nil)
        } catch {
            await context.status.endTransfer(transfer, error: error)
            throw error
        }
    }

    private func uploadConflictCopy(_ localURL: URL?, of path: String, progress: Progress, context: Context) async throws {
        let name = RemotePath.name(of: path)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        let stamp = Date().formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits)",
                                               timeZone: .current, calendar: .current))
        let host = Host.current().localizedName ?? "Mac"
        let conflictName = "\(base) (conflict from \(host) \(stamp))" + (ext.isEmpty ? "" : ".\(ext)")

        let conflictPath = try await uniqueRelativePath(in: Self.parent(of: path), preferredName: conflictName, context: context)
        try await upload(localURL, to: absolute(conflictPath, in: context), name: conflictName, progress: progress, context: context)
        await context.status.log("Conflict on \(name): saved your version as \(RemotePath.name(of: conflictPath))")

        // Surface the new conflict copy (and the server's version of the original) in Finder.
        try? await NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet)
    }

    // MARK: - Errors

    /// Translates SFTP and connection errors into File Provider errors the system understands.
    static func fileProviderError(_ error: Error) -> Error {
        let nsError = error as NSError
        if nsError.domain == NSFileProviderErrorDomain || error is CocoaError { return error }
        if error is CancellationError { return CocoaError(.userCancelled) }

        var status: SFTPMessage.Status?
        if let direct = error as? SFTPMessage.Status { status = direct }
        if let sftpError = error as? SFTPError, case .errorStatus(let wrapped) = sftpError { status = wrapped }
        if let status {
            let info = [NSLocalizedDescriptionKey: status.message]
            switch status.errorCode {
            case .noSuchFile: return NSFileProviderError(.noSuchItem, userInfo: info)
            case .permissionDenied: return CocoaError(.fileWriteNoPermission, userInfo: info)
            case .noConnection, .connectionLost: return NSFileProviderError(.serverUnreachable, userInfo: info)
            default: return CocoaError(.fileWriteUnknown, userInfo: info)
            }
        }

        if let saddleError = error as? SaddleError {
            let info = [NSLocalizedDescriptionKey: saddleError.localizedDescription]
            switch saddleError {
            case .connectionFailed: return NSFileProviderError(.serverUnreachable, userInfo: info)
            case .notADirectory: return NSFileProviderError(.noSuchItem, userInfo: info)
            default: return NSFileProviderError(.notAuthenticated, userInfo: info)
            }
        }
        return NSFileProviderError(.serverUnreachable, userInfo: [NSLocalizedDescriptionKey: error.localizedDescription])
    }
}
