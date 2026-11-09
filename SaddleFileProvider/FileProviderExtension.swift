import FileProvider
import UniformTypeIdentifiers
import Citadel

/// Replicated File Provider for one SFTP connection (one domain per saved profile).
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    struct RemoteChanges {
        var updated: [FileProviderItem]
        var deleted: [NSFileProviderItemIdentifier]
        var anchor: NSFileProviderSyncAnchor
        /// Identifiers included in `deleted` because an earlier delete removed them.
        /// Acknowledged only after the working set observer has been told.
        var reportedDeletionIDs: [String]
    }

    private let domain: NSFileProviderDomain
    /// Profile captured at init. Operations re-read the saved profile so edits apply
    /// without waiting for the extension process to be relaunched.
    private let profile: ConnectionProfile?
    private let session: SFTPSession?
    private let state: DomainState?
    private let status: StatusReporter?
    private let claims = NameClaims()

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

    func currentAnchor() async -> NSFileProviderSyncAnchor {
        guard let state else { return NSFileProviderSyncAnchor(Data()) }
        return NSFileProviderSyncAnchor(await state.syncAnchorData())
    }

    func acknowledgeDeletions(_ identifiers: [String]) async {
        await state?.acknowledgeDeletions(identifiers)
    }

    // MARK: - Bridging

    /// Runs async work for a completion-handler based File Provider call and wires up cancellation.
    private func run<T>(_ progress: Progress, writing: Bool = false, _ work: @escaping () async throws -> T,
                        completion: @escaping (Result<T, Error>) -> Void) -> Progress {
        let task = Task {
            do {
                completion(.success(try await work()))
            } catch {
                completion(.failure(Self.fileProviderError(error, writing: writing)))
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    private struct Context {
        let session: SFTPSession
        let state: DomainState
        let status: StatusReporter
        let profile: ConnectionProfile
        let root: String
    }

    private struct AppliedItem {
        var item: FileProviderItem
        var fetchContent: Bool
    }

    /// Connects if necessary and returns everything an operation needs.
    private func context() async throws -> Context {
        guard let session, let state, let status else { throw SaddleError.profileNotFound }
        let profile = ProfileStore.profile(for: domain.identifier) ?? self.profile
        guard let profile else { throw SaddleError.profileNotFound }
        await session.adopt(profile)
        do {
            let root = try await session.connect()
            await status.set(.connected)
            return Context(session: session, state: state, status: status, profile: profile, root: root)
        } catch {
            await status.set(.error, message: error.localizedDescription)
            throw error
        }
    }

    // MARK: - Paths

    private static func joined(_ parent: String, _ name: String) -> String {
        parent.isEmpty ? name : parent + "/" + name
    }

    private static func childPath(_ parent: String, _ name: String) throws -> String {
        guard RemotePath.isSafeComponent(name) else {
            throw NSFileProviderError(.cannotSynchronize, userInfo: [
                NSLocalizedDescriptionKey: "“\(name)” can't be used as a file name.",
            ])
        }
        return joined(parent, name)
    }

    private static func parent(of relativePath: String) -> String {
        guard let slash = relativePath.lastIndex(of: "/") else { return "" }
        return String(relativePath[..<slash])
    }

    private func absolute(_ relativePath: String, in context: Context) throws -> String {
        guard let resolved = RemotePath.resolved(relativePath, under: context.root) else {
            throw NSFileProviderError(.noSuchItem, userInfo: [
                NSLocalizedDescriptionKey: "That path is outside the mounted folder.",
            ])
        }
        return resolved
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
                                    filename: context.profile.displayName)
        }
        let parent = await context.state.identifier(for: Self.parent(of: relativePath))
        return FileProviderItem(entry: entry, identifier: identifier, parent: parent)
    }

    private func shows(_ name: String, profile: ConnectionProfile) -> Bool {
        if RemotePath.isPartialUpload(name) { return false }
        if !profile.showHiddenFiles, name.hasPrefix(".") { return false }
        return true
    }

    /// Picks `name 2.ext`, `name 3.ext`, … so a remote file is never silently overwritten.
    /// The returned path is reserved until `releaseClaim` so two creates can't choose it at once.
    private func claimUniquePath(in parent: String, preferredName name: String, context: Context) async throws -> String {
        var names = [name]
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for index in 2...999 {
            names.append(ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)")
        }
        for candidate in names {
            let path = try Self.childPath(parent, candidate)
            guard await claims.claim(path) else { continue }
            do {
                if try await !context.session.exists(try absolute(path, in: context)) {
                    return path
                }
            } catch {
                await claims.release(path)
                throw error
            }
            await claims.release(path)
        }
        throw NSFileProviderError(.filenameCollision)
    }

    private func releaseClaim(_ path: String?) async {
        guard let path else { return }
        await claims.release(path)
    }

    // MARK: - Enumeration support

    func listItems(in container: NSFileProviderItemIdentifier) async throws -> [FileProviderItem] {
        let context = try await context()
        guard container != .trashContainer else { throw NSFileProviderError(.noSuchItem) }
        let directory = try await relativePath(for: container, in: context)
        let entries = try await context.session.list(try absolute(directory, in: context))

        var items: [FileProviderItem] = []
        var snapshot: [String: String] = [:]
        var links = Set<String>()
        for entry in entries {
            let relative = Self.joined(directory, entry.name)
            if entry.isSymlink { links.insert(relative) }
            guard shows(entry.name, profile: context.profile) else { continue }
            let item = await makeItem(entry, relativePath: relative, in: context)
            snapshot[item.itemIdentifier.rawValue] = entry.metadataVersion
            items.append(item)
        }
        await context.state.setSymlinks(links, in: directory)
        await context.state.setSnapshot(snapshot, of: container)
        await context.state.flush()
        return items
    }

    /// Re-lists every directory that has been enumerated and reports what changed remotely.
    func pollRemoteChanges() async throws -> RemoteChanges {
        let context = try await context()
        var updated: [FileProviderItem] = []
        var deleted: [NSFileProviderItemIdentifier] = []
        var seenDeletes = Set<String>()

        func recordDelete(_ identifier: NSFileProviderItemIdentifier) {
            let raw = identifier.rawValue
            guard seenDeletes.insert(raw).inserted else { return }
            deleted.append(identifier)
        }

        let pending = await context.state.pendingDeletionIDs()
        var reportedDeletionIDs = pending
        for raw in pending {
            recordDelete(NSFileProviderItemIdentifier(raw))
        }

        for directoryID in await context.state.snapshotDirectories {
            try Task.checkCancellation()
            guard let directory = await context.state.relativePath(for: directoryID),
                  let previous = await context.state.snapshot(of: directoryID) else {
                await context.state.dropSnapshot(of: directoryID)
                continue
            }

            let remoteDirectory: String
            do {
                remoteDirectory = try absolute(directory, in: context)
            } catch {
                await context.state.dropSnapshot(of: directoryID)
                continue
            }

            let entries: [RemoteEntry]
            do {
                entries = try await context.session.list(remoteDirectory)
            } catch {
                if SFTPSession.isMissing(error) {
                    if directoryID != .rootContainer {
                        let removed = await context.state.remove(directory)
                        await context.state.noteDeletions(removed)
                        reportedDeletionIDs.append(contentsOf: removed)
                        for raw in removed { recordDelete(NSFileProviderItemIdentifier(raw)) }
                    }
                    continue
                }
                throw error
            }

            var current: [String: String] = [:]
            var links = Set<String>()
            let visibleNames = Set(entries.map(\.name))
            for entry in entries {
                let relative = Self.joined(directory, entry.name)
                if entry.isSymlink { links.insert(relative) }
                guard shows(entry.name, profile: context.profile) else { continue }
                let item = await makeItem(entry, relativePath: relative, in: context)
                current[item.itemIdentifier.rawValue] = entry.metadataVersion
                if previous[item.itemIdentifier.rawValue] != entry.metadataVersion {
                    updated.append(item)
                }
            }
            await context.state.setSymlinks(links, in: directory)
            for (childID, _) in previous where current[childID] == nil {
                let identifier = NSFileProviderItemIdentifier(childID)
                if let path = await context.state.relativePath(for: identifier) {
                    let name = RemotePath.name(of: path)
                    if visibleNames.contains(name), !shows(name, profile: context.profile) {
                        // Still on the server, only hidden by the current filter. Tell Finder
                        // to drop it, but keep the identifier so showing hidden files brings
                        // the same item back.
                        recordDelete(identifier)
                        continue
                    }
                    let removed = await context.state.remove(path)
                    await context.state.noteDeletions(removed)
                    reportedDeletionIDs.append(contentsOf: removed)
                    for raw in removed { recordDelete(NSFileProviderItemIdentifier(raw)) }
                } else {
                    recordDelete(identifier)
                }
            }
            await context.state.setSnapshot(current, of: directoryID)
        }

        let changed = !updated.isEmpty || !deleted.isEmpty
        if changed { await context.state.bumpAnchor() }
        await context.state.flush()
        return RemoteChanges(
            updated: updated,
            deleted: deleted,
            anchor: NSFileProviderSyncAnchor(await context.state.syncAnchorData()),
            reportedDeletionIDs: reportedDeletionIDs)
    }

    // MARK: - NSFileProviderReplicatedExtension

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        run(Progress(), { [self] in
            guard identifier != .trashContainer, identifier != .workingSet else { throw NSFileProviderError(.noSuchItem) }
            let context = try await context()
            let path = try await relativePath(for: identifier, in: context)
            let entry = try await metadata(for: path, in: context)
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
            let remotePath = try absolute(path, in: context)
            let described = try await metadata(for: path, in: context)
            if described.isSymlink {
                throw NSFileProviderError(.cannotSynchronize, userInfo: [
                    NSLocalizedDescriptionKey: "Saddle doesn't open symbolic links. Following one could read outside the mounted folder.",
                ])
            }
            guard let manager = NSFileProviderManager(for: domain) else { throw NSFileProviderError(.providerNotFound) }
            let destination = try manager.temporaryDirectoryURL().appending(path: UUID().uuidString)

            var matched: RemoteEntry?
            for _ in 0..<3 {
                try Task.checkCancellation()
                let entry = try await context.session.stat(remotePath)
                guard !entry.isDirectory else { throw NSFileProviderError(.noSuchItem) }
                progress.totalUnitCount = Int64(exactly: entry.size) ?? 0
                try? FileManager.default.removeItem(at: destination)

                let transfer = await context.status.beginTransfer(name: entry.name, isUpload: false, totalBytes: progress.totalUnitCount)
                let throttle = ProgressThrottle()
                do {
                    let status = context.status
                    try await context.session.download(remotePath, to: destination) { bytes in
                        progress.completedUnitCount = bytes
                        if throttle.shouldPublish() {
                            Task { await status.updateTransfer(transfer, completedBytes: bytes) }
                        }
                    }
                    await context.status.endTransfer(transfer, error: nil)
                } catch {
                    await context.status.endTransfer(transfer, error: error)
                    try? FileManager.default.removeItem(at: destination)
                    throw error
                }

                let after = try await context.session.stat(remotePath)
                let localSize = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
                if after.contentVersion == entry.contentVersion, localSize == Int64(exactly: entry.size) {
                    matched = entry
                    break
                }
            }
            guard let matched else {
                try? FileManager.default.removeItem(at: destination)
                throw NSFileProviderError(.serverUnreachable, userInfo: [
                    NSLocalizedDescriptionKey: "The file changed while it was downloading. Try again.",
                ])
            }
            // Publish the version that matches the bytes, not a stat taken after a later edit.
            return (destination, await makeItem(matched, relativePath: path, in: context))
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
        return run(progress, writing: true, { [self] in
            let context = try await context()
            let contentType = itemTemplate.contentType ?? .data
            if contentType.conforms(to: .symbolicLink) {
                throw NSFileProviderError(.cannotSynchronize)
            }
            let isFolder = contentType.conforms(to: .folder) || contentType.conforms(to: .directory)
            let parent = try await relativePath(for: itemTemplate.parentItemIdentifier, in: context)

            if options.contains(.mayAlreadyExist) {
                let existingPath = try Self.childPath(parent, itemTemplate.filename)
                if let existing = try await existingItem(at: existingPath, in: context), existing.isDirectory == isFolder {
                    let localSize = url.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.map(Int64.init)
                    let sameSize = localSize == Int64(exactly: existing.size)
                    if isFolder || url == nil || sameSize {
                        // A replay of our own create. Refetch when we didn't just upload these bytes
                        // so Finder doesn't keep a different local copy under the server's version.
                        let item = await makeItem(existing, relativePath: existingPath, in: context)
                        return AppliedItem(item: item, fetchContent: url != nil && !isFolder)
                    }
                }
            }

            let path = try await claimUniquePath(in: parent, preferredName: itemTemplate.filename, context: context)
            do {
                let remotePath = try absolute(path, in: context)
                if isFolder {
                    try await context.session.createDirectory(remotePath)
                } else {
                    try await upload(url, to: remotePath, name: RemotePath.name(of: path), progress: progress, context: context)
                    if fields.contains(.contentModificationDate), let date = itemTemplate.contentModificationDate {
                        try? await context.session.setModificationDate(date, for: remotePath)
                    }
                    if itemTemplate.fileSystemFlags?.contains(.userExecutable) == true {
                        let created = try await context.session.stat(remotePath)
                        try? await context.session.setPermissions(created.permissions | 0o111, for: remotePath)
                    }
                }

                let entry = try await context.session.stat(remotePath)
                let item = await makeItem(entry, relativePath: path, in: context)
                await context.state.updateChild(item.itemIdentifier, version: entry.metadataVersion, in: item.parentItemIdentifier)
                await context.state.flush()
                await releaseClaim(path)
                return AppliedItem(item: item, fetchContent: false)
            } catch {
                await releaseClaim(path)
                throw error
            }
        }) { result in
            switch result {
            case .success(let applied): completionHandler(applied.item, [], applied.fetchContent, nil)
            case .failure(let error): completionHandler(nil, [], false, error)
            }
        }
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields,
                    contents newContents: URL?, options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 0)
        return run(progress, writing: true, { [self] in
            let context = try await context()
            var path = try await relativePath(for: item.itemIdentifier, in: context)
            let oldParentID = await context.state.identifier(for: Self.parent(of: path))
            var current = try await metadata(for: path, in: context)
            var fetchContent = false
            var claimed: String?
            do {
            if !path.isEmpty, changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
                let newParent = try await relativePath(for: item.parentItemIdentifier, in: context)
                let proposed = try Self.childPath(newParent, item.filename)
                if proposed != path {
                    if proposed.hasPrefix(path + "/") {
                        throw NSFileProviderError(.cannotSynchronize, userInfo: [
                            NSLocalizedDescriptionKey: "A folder can't be moved into itself.",
                        ])
                    }
                    let target = try await claimUniquePath(in: newParent, preferredName: item.filename, context: context)
                    claimed = target
                    try await context.session.rename(try absolute(path, in: context), to: try absolute(target, in: context))
                    await context.state.move(from: path, to: target)
                    await context.state.updateChild(item.itemIdentifier, version: nil, in: oldParentID)
                    path = target
                }
            }
            let remotePath = try absolute(path, in: context)

            if current.isSymlink, changedFields.contains(.contents) {
                throw NSFileProviderError(.cannotSynchronize, userInfo: [
                    NSLocalizedDescriptionKey: "Saddle doesn't write through symbolic links.",
                ])
            }
            if changedFields.contains(.contents), !current.isDirectory {
                guard newContents != nil else {
                    throw NSFileProviderError(.cannotSynchronize, userInfo: [
                        NSLocalizedDescriptionKey: "The new file contents were missing, so nothing was uploaded.",
                    ])
                }
                if !Self.contentMatches(current, version) {
                    if options.contains(.failOnConflict) {
                        throw NSFileProviderError(.cannotSynchronize, userInfo: [
                            NSLocalizedDescriptionKey: "The file changed on the server.",
                        ])
                    }
                    // Keep the server bytes as the item Finder is editing, and upload the local
                    // edit beside them. fetchContent makes Finder replace the stale local bytes.
                    try await uploadConflictCopy(newContents, of: path, progress: progress, context: context)
                    fetchContent = true
                } else {
                    try await upload(newContents, to: remotePath, name: item.filename, progress: progress, context: context)
                    if let date = item.contentModificationDate {
                        try? await context.session.setModificationDate(date, for: remotePath)
                    }
                }
            } else if changedFields.contains(.contentModificationDate), let date = item.contentModificationDate {
                try? await context.session.setModificationDate(date, for: remotePath)
            }

            if changedFields.contains(.fileSystemFlags), !current.isDirectory, !current.isSymlink, let flags = item.fileSystemFlags {
                current = try await context.session.stat(remotePath)
                let readBits = current.permissions & 0o444
                let permissions = flags.contains(.userExecutable)
                    ? current.permissions | (readBits >> 2)
                    : current.permissions & ~0o111
                if permissions != current.permissions {
                    try? await context.session.setPermissions(permissions, for: remotePath)
                }
            }

            let entry = current.isSymlink
                ? try await metadata(for: path, in: context)
                : try await context.session.stat(remotePath)
            let updated = await makeItem(entry, relativePath: path, in: context)
            await context.state.updateChild(updated.itemIdentifier, version: entry.metadataVersion, in: updated.parentItemIdentifier)
            await context.state.flush()
            await releaseClaim(claimed)
            return AppliedItem(item: updated, fetchContent: fetchContent)
            } catch {
                await releaseClaim(claimed)
                throw error
            }
        }) { result in
            switch result {
            case .success(let applied): completionHandler(applied.item, [], applied.fetchContent, nil)
            case .failure(let error): completionHandler(nil, [], false, error)
            }
        }
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        run(Progress(), writing: true, { [self] in
            guard identifier != .rootContainer else { throw NSFileProviderError(.deletionRejected) }
            let context = try await context()
            let path = try await relativePath(for: identifier, in: context)
            let remotePath = try absolute(path, in: context)
            let parentID = await context.state.identifier(for: Self.parent(of: path))

            let entry: RemoteEntry?
            do {
                entry = try await metadata(for: path, in: context)
            } catch {
                if SFTPSession.isMissing(error) {
                    entry = nil
                } else {
                    throw error
                }
            }

            if let entry {
                if !entry.isSymlink, !entry.isDirectory, !Self.contentMatches(entry, version) {
                    throw NSFileProviderError(.deletionRejected, userInfo: [
                        NSLocalizedDescriptionKey: "The file changed on the server, so it was not deleted.",
                    ])
                }
                if entry.isDirectory {
                    let recursive = options.contains(.recursive)
                    do {
                        try await context.session.removeDirectory(remotePath, recursive: recursive)
                    } catch {
                        if !recursive, SFTPSession.statusCode(error) == .failure {
                            throw NSFileProviderError(.directoryNotEmpty)
                        }
                        throw error
                    }
                } else {
                    try await context.session.removeFile(remotePath)
                }
                await context.status.log("Deleted \(entry.name)")
            }
            let removed = await context.state.remove(path)
            await context.state.noteDeletions(removed)
            await context.state.updateChild(identifier, version: nil, in: parentID)
            await context.state.flush()
            if removed.count > 1 {
                try? await NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet)
            }
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

    /// Metadata for an item. Symlinks recorded while listing are not followed, so a link to a
    /// directory is not treated as that directory (which would let a delete walk out of the mount).
    private func metadata(for relativePath: String, in context: Context) async throws -> RemoteEntry {
        let remote = try absolute(relativePath, in: context)
        if !relativePath.isEmpty, await context.state.isSymlink(relativePath) {
            return RemoteEntry(path: remote, name: RemotePath.name(of: relativePath), kind: .file,
                               size: 0, modified: .distantPast, permissions: 0o777, isSymlink: true)
        }
        return try await context.session.stat(remote)
    }

    private func existingItem(at relativePath: String, in context: Context) async throws -> RemoteEntry? {
        do {
            return try await context.session.stat(try absolute(relativePath, in: context))
        } catch {
            if SFTPSession.isMissing(error) { return nil }
            throw error
        }
    }

    private func upload(_ localURL: URL?, to remotePath: String, name: String, progress: Progress, context: Context) async throws {
        let size = localURL.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? 0
        progress.totalUnitCount = Int64(size)
        let transfer = await context.status.beginTransfer(name: name, isUpload: true, totalBytes: Int64(size))
        let throttle = ProgressThrottle()
        do {
            let status = context.status
            try await context.session.upload(from: localURL, to: remotePath) { bytes in
                progress.completedUnitCount = bytes
                if throttle.shouldPublish() {
                    Task { await status.updateTransfer(transfer, completedBytes: bytes) }
                }
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

        let conflictPath = try await claimUniquePath(in: Self.parent(of: path), preferredName: conflictName, context: context)
        do {
            try await upload(localURL, to: try absolute(conflictPath, in: context), name: conflictName, progress: progress, context: context)
            await releaseClaim(conflictPath)
        } catch {
            await releaseClaim(conflictPath)
            throw error
        }
        await context.status.log("Conflict on \(name): saved your version as \(RemotePath.name(of: conflictPath))")
        try? await NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet)
    }

    /// `beforeFirstSync` means Finder has never had a server version to compare against.
    private static func contentMatches(_ entry: RemoteEntry, _ version: NSFileProviderItemVersion) -> Bool {
        let base = version.contentVersion
        if base.isEmpty || base == NSFileProviderItemVersion.beforeFirstSyncComponent { return true }
        return Data(entry.contentVersion.utf8) == base
    }

    // MARK: - Errors

    /// Translates SFTP and connection errors into File Provider errors the system understands.
    static func fileProviderError(_ error: Error, writing: Bool = false) -> Error {
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
            case .permissionDenied:
                return writing
                    ? CocoaError(.fileWriteNoPermission, userInfo: info)
                    : CocoaError(.fileReadNoPermission, userInfo: info)
            case .noConnection, .connectionLost: return NSFileProviderError(.serverUnreachable, userInfo: info)
            default:
                return NSFileProviderError(.cannotSynchronize, userInfo: info)
            }
        }
        if let sftpError = error as? SFTPError {
            switch sftpError {
            case .connectionClosed, .missingResponse:
                return NSFileProviderError(.serverUnreachable, userInfo: [
                    NSLocalizedDescriptionKey: "The connection to the server was lost.",
                ])
            default:
                break
            }
        }

        if let saddleError = error as? SaddleError {
            let info = [NSLocalizedDescriptionKey: saddleError.localizedDescription]
            switch saddleError {
            case .connectionFailed: return NSFileProviderError(.serverUnreachable, userInfo: info)
            case .notADirectory: return NSFileProviderError(.noSuchItem, userInfo: info)
            case .missingCredentials, .authenticationFailed, .profileNotFound:
                return NSFileProviderError(.notAuthenticated, userInfo: info)
            case .unknownHostKey, .hostKeyChanged, .unsupportedKey:
                return NSFileProviderError(.cannotSynchronize, userInfo: info)
            }
        }
        return NSFileProviderError(.serverUnreachable, userInfo: [
            NSLocalizedDescriptionKey: SFTPSession.publicDescription(of: error),
        ])
    }
}

/// Reserves relative paths so concurrent creates don't pick the same destination.
private actor NameClaims {
    private var paths: Set<String> = []

    func claim(_ path: String) -> Bool {
        paths.insert(path).inserted
    }

    func release(_ path: String) {
        paths.remove(path)
    }
}

/// Coalesces per-chunk progress updates so a large transfer doesn't enqueue a task per write.
private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast

    func shouldPublish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(last) >= 0.25 else { return false }
        last = now
        return true
    }
}
