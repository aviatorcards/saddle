import Foundation
import FileProvider

/// Persistent bookkeeping for one mounted connection.
///
/// File Provider item identifiers must stay stable across renames and moves, but SFTP
/// only knows paths. This maps paths (relative to the mount root, `""` for the root)
/// to generated identifiers, and keeps a snapshot of each enumerated directory so remote
/// changes can be detected by re-listing and diffing.
actor DomainState {
    private struct Persisted: Codable {
        var pathsByID: [String: String] = [:]
        /// Directory identifier → (child identifier → metadata version).
        var snapshots: [String: [String: String]] = [:]
        var anchor: UInt64 = 0
        var pendingDeletions: [String] = []
        var symlinkPaths: [String] = []

        init() {}

        init(pathsByID: [String: String], snapshots: [String: [String: String]], anchor: UInt64, pendingDeletions: [String], symlinkPaths: [String]) {
            self.pathsByID = pathsByID
            self.snapshots = snapshots
            self.anchor = anchor
            self.pendingDeletions = pendingDeletions
            self.symlinkPaths = symlinkPaths
        }

        private enum CodingKeys: String, CodingKey {
            case pathsByID, snapshots, anchor, pendingDeletions, symlinkPaths
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            pathsByID = try container.decodeIfPresent([String: String].self, forKey: .pathsByID) ?? [:]
            snapshots = try container.decodeIfPresent([String: [String: String]].self, forKey: .snapshots) ?? [:]
            anchor = try container.decodeIfPresent(UInt64.self, forKey: .anchor) ?? 0
            pendingDeletions = try container.decodeIfPresent([String].self, forKey: .pendingDeletions) ?? []
            symlinkPaths = try container.decodeIfPresent([String].self, forKey: .symlinkPaths) ?? []
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(pathsByID, forKey: .pathsByID)
            try container.encode(snapshots, forKey: .snapshots)
            try container.encode(anchor, forKey: .anchor)
            try container.encode(pendingDeletions, forKey: .pendingDeletions)
            try container.encode(symlinkPaths, forKey: .symlinkPaths)
        }
    }

    private let url: URL
    private var pathByID: [String: String]
    private var idByPath: [String: String]
    private var snapshots: [String: [String: String]]
    private var anchor: UInt64
    private var pendingDeletions: [String]
    private var symlinkPaths: Set<String>
    private var saveTask: Task<Void, Never>?

    init(profileID: UUID) {
        url = AppGroup.domainDirectory(for: profileID).appending(path: "state.json")
        let persisted = JSONFile.read(Persisted.self, from: url) ?? Persisted()
        pathByID = persisted.pathsByID
        snapshots = persisted.snapshots
        anchor = persisted.anchor
        pendingDeletions = persisted.pendingDeletions
        symlinkPaths = Set(persisted.symlinkPaths)
        idByPath = IdentifierMap.index(pathByID: persisted.pathsByID)
    }

    // MARK: Identifiers

    func identifier(for relativePath: String) -> NSFileProviderItemIdentifier {
        if relativePath.isEmpty { return .rootContainer }
        if let existing = idByPath[relativePath] { return NSFileProviderItemIdentifier(existing) }
        let id = UUID().uuidString
        idByPath[relativePath] = id
        pathByID[id] = relativePath
        scheduleSave()
        return NSFileProviderItemIdentifier(id)
    }

    func relativePath(for identifier: NSFileProviderItemIdentifier) -> String? {
        identifier == .rootContainer ? "" : pathByID[identifier.rawValue]
    }

    /// Re-points an item, and everything beneath it, at a new path. Identifiers are kept.
    func move(from oldPath: String, to newPath: String) {
        pathByID = IdentifierMap.relocating(pathByID, from: oldPath, to: newPath)
        idByPath = IdentifierMap.index(pathByID: pathByID)
        symlinkPaths = Set(symlinkPaths.map { path in
            guard path == oldPath || path.hasPrefix(oldPath + "/") else { return path }
            return newPath + path.dropFirst(oldPath.count)
        })
        persistNow()
    }

    /// Forgets an item and its descendants. Returns the identifiers that were removed.
    @discardableResult
    func remove(_ relativePath: String) -> [String] {
        let prefix = relativePath + "/"
        let removed = pathByID.filter { $0.value == relativePath || $0.value.hasPrefix(prefix) }
        for (id, path) in removed {
            pathByID[id] = nil
            idByPath[path] = nil
            snapshots[id] = nil
        }
        symlinkPaths = symlinkPaths.filter { $0 != relativePath && !$0.hasPrefix(prefix) }
        persistNow()
        return Array(removed.keys)
    }

    // MARK: Directory snapshots

    var snapshotDirectories: [NSFileProviderItemIdentifier] {
        snapshots.keys.map { NSFileProviderItemIdentifier($0) }
    }

    func snapshot(of directory: NSFileProviderItemIdentifier) -> [String: String]? {
        snapshots[directory.rawValue]
    }

    func setSnapshot(_ children: [String: String], of directory: NSFileProviderItemIdentifier) {
        snapshots[directory.rawValue] = children
        scheduleSave()
    }

    func dropSnapshot(of directory: NSFileProviderItemIdentifier) {
        snapshots[directory.rawValue] = nil
        scheduleSave()
    }

    /// Keeps a parent's snapshot in sync with changes Saddle made itself, so the next
    /// poll doesn't report them back as remote changes.
    func updateChild(_ child: NSFileProviderItemIdentifier, version: String?, in directory: NSFileProviderItemIdentifier) {
        guard snapshots[directory.rawValue] != nil else { return }
        snapshots[directory.rawValue]?[child.rawValue] = version
        scheduleSave()
    }

    // MARK: Sync anchor and deletions the working set still has to hear about

    func syncAnchorData() -> Data {
        Data(String(anchor).utf8)
    }

    func bumpAnchor() {
        anchor &+= 1
        persistNow()
    }

    func noteDeletions(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        var seen = Set(pendingDeletions)
        for identifier in identifiers where seen.insert(identifier).inserted {
            pendingDeletions.append(identifier)
        }
        persistNow()
    }

    func pendingDeletionIDs() -> [String] {
        pendingDeletions
    }

    /// Replaces the symlink flags for the direct children of `directory`.
    func setSymlinks(_ paths: Set<String>, in directory: String) {
        symlinkPaths = symlinkPaths.filter { Self.parent(of: $0) != directory }
        symlinkPaths.formUnion(paths)
        scheduleSave()
    }

    func isSymlink(_ relativePath: String) -> Bool {
        symlinkPaths.contains(relativePath)
    }

    private static func parent(of relativePath: String) -> String {
        guard let slash = relativePath.lastIndex(of: "/") else { return "" }
        return String(relativePath[..<slash])
    }

    func acknowledgeDeletions(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        let drop = Set(identifiers)
        pendingDeletions.removeAll { drop.contains($0) }
        persistNow()
    }

    // MARK: Persistence

    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self.persistNow()
        }
    }

    /// Writes the current maps immediately. Structural changes call this directly so a
    /// crash in the debounce window cannot resurrect a path that was already renamed.
    func flush() {
        persistNow()
    }

    private func persistNow() {
        saveTask?.cancel()
        saveTask = nil
        try? JSONFile.write(Persisted(
            pathsByID: pathByID,
            snapshots: snapshots,
            anchor: anchor,
            pendingDeletions: pendingDeletions,
            symlinkPaths: Array(symlinkPaths).sorted()
        ), to: url)
    }
}
