import Foundation

/// Cuts a buffered directory listing into Finder pages.
///
/// Citadel 0.12's `listDirectory` reads every SFTP `readdir` response before it
/// returns, so a directory cannot be streamed. The page token is still real:
/// the next call resumes at `offset` instead of starting over.
nonisolated enum DirectoryPage {
    static let fallbackSize = 100
    static let maximumSize = 200
    private static let marker: UInt8 = 0x53

    static func size(suggested: Int?) -> Int {
        min(maximumSize, max(1, suggested ?? fallbackSize))
    }

    /// `nil` and the system's initial pages are not tokens we wrote, so they start at 0.
    static func offset(from token: Data?) -> Int {
        guard let token, token.count == 5, token[token.startIndex] == marker else { return 0 }
        let bytes = Array(token.dropFirst())
        let value = bytes.reduce(0) { ($0 << 8) | Int($1) }
        return max(0, value)
    }

    static func token(forOffset offset: Int) -> Data {
        let value = UInt32(max(0, offset))
        return Data([
            marker,
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ])
    }

    /// The half-open range of items for this page, and the offset of the next page.
    static func bounds(itemCount: Int, offset: Int, pageSize: Int) -> (start: Int, end: Int, nextOffset: Int?) {
        let count = max(0, itemCount)
        let start = min(max(0, offset), count)
        let end = min(count, start + max(1, pageSize))
        return (start, end, end < count ? end : nil)
    }
}

/// A listing attribute set is enough to build a file item. Symlinks still need a lookup,
/// because the name list describes the link itself, not the target inside the mount.
nonisolated enum RemoteListing {
    static func needsExtraRequest(hasSize: Bool, hasModified: Bool, hasPermissions: Bool, isSymlink: Bool) -> Bool {
        if isSymlink { return true }
        return !hasSize || !hasModified || !hasPermissions
    }
}

/// Short-lived metadata remembered from a listing so the next stat can skip the network.
nonisolated struct MetadataCache<Value> {
    var ttl: TimeInterval
    private var stored: [String: (value: Value, at: Date)] = [:]

    init(ttl: TimeInterval) {
        self.ttl = ttl
    }

    mutating func insert(_ value: Value, for key: String, at date: Date) {
        stored[key] = (value, date)
    }

    mutating func lookup(_ key: String, at date: Date) -> Value? {
        guard let entry = stored[key] else { return nil }
        if date.timeIntervalSince(entry.at) > ttl {
            stored[key] = nil
            return nil
        }
        return entry.value
    }

    mutating func remove(_ key: String) {
        stored[key] = nil
    }

    mutating func remove(prefix: String) {
        stored = stored.filter { key, _ in key != prefix && !key.hasPrefix(prefix.hasSuffix("/") ? prefix : prefix + "/") }
    }

    mutating func removeAll() {
        stored.removeAll()
    }
}

/// Which items Finder should keep on disk. Stored in the shared app-group container.
nonisolated struct DownloadPins: Codable, Equatable, Sendable {
    var pinned: Set<String> = []
    /// Explicit "Remove Download" choices. These win over a pin on an ancestor and over
    /// the connection-wide "keep all files downloaded" setting.
    var released: Set<String> = []

    func keeps(_ path: String, keepAll: Bool) -> Bool {
        var current = path
        while true {
            if released.contains(current) { return false }
            if pinned.contains(current) { return true }
            if current.isEmpty { break }
            let parent = Self.parent(of: current)
            if parent == current { break }
            current = parent
        }
        return keepAll
    }

    mutating func pin(_ path: String) {
        pinned = pinned.filter { $0 == path || !Self.isDescendant($0, of: path) }
        released = released.filter { $0 != path && !Self.isDescendant($0, of: path) }
        pinned.insert(path)
    }

    mutating func release(_ path: String) {
        pinned = pinned.filter { $0 != path && !Self.isDescendant($0, of: path) }
        released = released.filter { $0 != path && !Self.isDescendant($0, of: path) }
        released.insert(path)
    }

    static func fileURL(profileID: UUID) -> URL {
        AppGroup.domainDirectory(for: profileID).appending(path: "pins.json")
    }

    static func load(from url: URL) -> DownloadPins {
        JSONFile.read(DownloadPins.self, from: url) ?? DownloadPins()
    }

    func save(to url: URL) throws {
        try JSONFile.write(self, to: url)
    }

    private static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    private static func isDescendant(_ path: String, of ancestor: String) -> Bool {
        !ancestor.isEmpty && path.hasPrefix(ancestor + "/")
    }
}

/// Global prefetch limits, written where the File Provider extension can read them.
nonisolated struct FinderTuning: Codable, Equatable, Sendable {
    var prefetchEnabled: Bool
    var maxFileBytes: Int64
    var maxFolderBytes: Int64

    static let `default` = FinderTuning(
        prefetchEnabled: true,
        maxFileBytes: 5 * 1024 * 1024,
        maxFolderBytes: 50 * 1024 * 1024)

    static var url: URL { AppGroup.containerURL.appending(path: "finder-tuning.json") }

    static func load() -> FinderTuning {
        JSONFile.read(FinderTuning.self, from: url) ?? .default
    }

    static func save(_ tuning: FinderTuning) {
        try? JSONFile.write(tuning, to: url)
    }
}

nonisolated struct PrefetchCandidate: Equatable, Sendable {
    var name: String
    var size: UInt64
    var isDirectory: Bool = false
    var isHidden: Bool = false
    var isPartial: Bool = false
    var isSymlink: Bool = false
    var symlinkEscapesMount: Bool = false
}

/// Picks the small files to download when a folder is opened.
nonisolated enum PrefetchPlanner {
    struct Limits: Equatable, Sendable {
        var enabled: Bool
        var maxFileBytes: UInt64
        var maxFolderBytes: UInt64
    }

    static func select(_ files: [PrefetchCandidate], limits: Limits) -> [PrefetchCandidate] {
        guard limits.enabled, limits.maxFileBytes > 0, limits.maxFolderBytes > 0 else { return [] }
        var chosen: [PrefetchCandidate] = []
        var used: UInt64 = 0
        for file in files {
            if file.isDirectory || file.isHidden || file.isPartial { continue }
            if file.isSymlink && file.symlinkEscapesMount { continue }
            if file.size > limits.maxFileBytes { continue }
            if file.size > limits.maxFolderBytes - used { continue }
            chosen.append(file)
            used += file.size
        }
        return chosen
    }
}
