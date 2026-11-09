import Foundation

/// Path ↔ identifier updates for a File Provider domain.
///
/// Item identifiers have to survive renames. Applying the path rewrite in two
/// phases keeps a parent and a child from erasing each other's new path when
/// one path is a prefix of another.
nonisolated enum IdentifierMap {
    static func relocating(_ pathByID: [String: String], from oldPath: String, to newPath: String) -> [String: String] {
        guard oldPath != newPath, !oldPath.isEmpty else { return pathByID }
        let prefix = oldPath + "/"
        var updated = pathByID
        for (id, path) in pathByID where path == oldPath || path.hasPrefix(prefix) {
            updated[id] = newPath + path.dropFirst(oldPath.count)
        }
        return updated
    }

    /// `path → id`, keeping the first id when the persisted map is corrupt.
    static func index(pathByID: [String: String]) -> [String: String] {
        var index: [String: String] = [:]
        for (id, path) in pathByID where index[path] == nil {
            index[path] = id
        }
        return index
    }
}
