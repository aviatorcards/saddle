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
    }

    private let url: URL
    private var pathByID: [String: String]
    private var idByPath: [String: String]
    private var snapshots: [String: [String: String]]
    private var saveTask: Task<Void, Never>?

    init(profileID: UUID) {
        url = AppGroup.domainDirectory(for: profileID).appending(path: "state.json")
        let persisted = JSONFile.read(Persisted.self, from: url) ?? Persisted()
        pathByID = persisted.pathsByID
        snapshots = persisted.snapshots
        idByPath = Dictionary(persisted.pathsByID.map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
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
        let prefix = oldPath + "/"
        for (id, path) in pathByID where path == oldPath || path.hasPrefix(prefix) {
            let updated = newPath + path.dropFirst(oldPath.count)
            pathByID[id] = updated
            idByPath[path] = nil
            idByPath[updated] = id
        }
        scheduleSave()
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
        scheduleSave()
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

    // MARK: Persistence

    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            self.flush()
        }
    }

    func flush() {
        saveTask?.cancel()
        saveTask = nil
        try? JSONFile.write(Persisted(pathsByID: pathByID, snapshots: snapshots), to: url)
    }
}
