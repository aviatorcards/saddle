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
        if let group = fileManager.containerURL(forSecurityApplicationGroupIdentifier: identifier) {
            try? fileManager.createDirectory(at: group, withIntermediateDirectories: true)
            if fileManager.isWritableFile(atPath: group.path) { return group }
        }
        let fallback = URL.applicationSupportDirectory.appending(path: "Saddle", directoryHint: .isDirectory)
        try? fileManager.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }()

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
