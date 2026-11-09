import Foundation

/// Live state the extension publishes for the menu bar app to display.
nonisolated struct DomainStatus: Codable, Sendable, Equatable {
    enum State: String, Codable, Sendable {
        case idle
        case connecting
        case connected
        case error
    }

    struct Transfer: Codable, Sendable, Hashable, Identifiable {
        var id: UUID
        var name: String
        var isUpload: Bool
        var completedBytes: Int64
        var totalBytes: Int64

        var fraction: Double {
            totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 0
        }
    }

    var state: State = .idle
    var message: String?
    var updated = Date()
    var transfers: [Transfer] = []

    private static func url(for profileID: UUID) -> URL {
        AppGroup.domainDirectory(for: profileID).appending(path: "status.json")
    }

    static func read(for profileID: UUID) -> DomainStatus? {
        JSONFile.read(DomainStatus.self, from: url(for: profileID))
    }

    func write(for profileID: UUID) {
        try? JSONFile.write(self, to: Self.url(for: profileID))
    }
}

/// An append-only activity log shared by all connections (one JSON object per line).
nonisolated enum ActivityLog {
    struct Entry: Codable, Sendable, Hashable, Identifiable {
        var id = UUID()
        var date = Date()
        var profileID: UUID
        var message: String
        var isError = false
    }

    private static var url: URL { AppGroup.containerURL.appending(path: "activity.jsonl") }
    private static let maxEntries = 300

    static func append(_ message: String, profileID: UUID, isError: Bool = false) {
        let entry = Entry(profileID: profileID, message: message, isError: isError)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)

        try? FileLock.withLock(url: url) {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        }
    }

    /// Most recent entries first. Also trims the file when it grows too large.
    static func recent(limit: Int = 50) -> [Entry] {
        let data = (try? FileLock.withLock(url: url) { () -> Data? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            let lines = data.split(separator: 0x0A)
            if lines.count > maxEntries * 2 {
                let kept = lines.suffix(maxEntries).joined(separator: [0x0A]) + [0x0A]
                try? Data(kept).write(to: url, options: .atomic)
            }
            return data
        }) ?? nil
        guard let data else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let lines = data.split(separator: 0x0A)
        return lines.suffix(limit).reversed().compactMap { try? decoder.decode(Entry.self, from: Data($0)) }
    }
}
