import Foundation
import Security

/// Locates the App Group shared by the menu bar app and the File Provider extension.
///
/// The group identifier is declared in both targets' entitlements as
/// `$(TeamIdentifierPrefix)saddle.shared`. Because the team prefix is only known at
/// signing time, it is read back from the running process's own entitlements.
nonisolated enum AppGroup {
    static let identifier: String = {
        if let task = SecTaskCreateFromSelf(nil),
           let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil),
           let groups = value as? [String],
           let group = groups.first(where: { $0.hasSuffix("saddle.shared") }) {
            return group
        }
        return "saddle.shared"
    }()

    /// Root directory for all shared state. Falls back to the process's own Application
    /// Support folder when the App Group isn't usable (builds signed without a team), in
    /// which case the app and extension can't share state.
    static let containerURL: URL = {
        let fileManager = FileManager.default
        let fallback = URL.applicationSupportDirectory.appending(path: "Saddle", directoryHint: .isDirectory)
        if let group = fileManager.containerURL(forSecurityApplicationGroupIdentifier: identifier), canWrite(in: group) {
            adoptFallbackState(from: fallback, into: group)
            return group
        }
        try? fileManager.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }()

    /// Tries a real write. `isWritableFile` uses access(2), which reports a sandboxed
    /// app's group container as read-only even though writes to it succeed.
    private static func canWrite(in directory: URL) -> Bool {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let probe = directory.appending(path: ".write-probe-\(UUID().uuidString)")
        guard (try? Data().write(to: probe)) != nil else { return false }
        try? FileManager.default.removeItem(at: probe)
        return true
    }

    /// Moves state written to the fallback folder (while the group was unusable) into the
    /// group, so connections saved then are visible to the File Provider extension.
    private static func adoptFallbackState(from fallback: URL, into group: URL) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: fallback.path), !names.isEmpty else { return }
        for name in names {
            let destination = group.appending(path: name)
            // Never overwrite state that is already shared.
            guard !fileManager.fileExists(atPath: destination.path) else { continue }
            try? fileManager.moveItem(at: fallback.appending(path: name), to: destination)
        }
        if (try? fileManager.contentsOfDirectory(atPath: fallback.path))?.isEmpty == true {
            try? fileManager.removeItem(at: fallback)
        }
    }

    /// Per-connection state directory (item identifier map, directory snapshots, status).
    static func domainDirectory(for profileID: UUID) -> URL {
        let url = containerURL.appending(path: "Domains/\(profileID.uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Small helpers for reading and writing Codable values as JSON files.
nonisolated enum JSONFile {
    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
