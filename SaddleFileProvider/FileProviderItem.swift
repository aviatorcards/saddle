import FileProvider
import UniformTypeIdentifiers

/// Finder-facing metadata for a remote file or folder.
final class FileProviderItem: NSObject, NSFileProviderItem {
    let entry: RemoteEntry
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    /// True when the user, or the connection's "keep all files downloaded" setting, wants this item on disk.
    let keptDownloaded: Bool

    init(entry: RemoteEntry, identifier: NSFileProviderItemIdentifier, parent: NSFileProviderItemIdentifier, filename: String? = nil, keptDownloaded: Bool = false) {
        self.entry = entry
        self.itemIdentifier = identifier
        self.parentItemIdentifier = parent
        self.filename = filename ?? entry.name
        self.keptDownloaded = keptDownloaded
    }

    var capabilities: NSFileProviderItemCapabilities {
        // Unlink depends on the parent directory, so deletion stays available and the server
        // can still reject it. Content writes follow the remote mode (missing mode defaults to 0644).
        let writable = entry.permissions & 0o222 != 0
        var capabilities: NSFileProviderItemCapabilities = [.allowsReading, .allowsDeleting]
        if writable, !entry.isDirectory {
            capabilities.insert(.allowsWriting)
        }
        if itemIdentifier != .rootContainer {
            capabilities.formUnion([.allowsRenaming, .allowsReparenting])
        }
        if entry.isDirectory {
            capabilities.formUnion([.allowsContentEnumerating])
            if writable { capabilities.formUnion([.allowsAddingSubItems, .allowsWriting]) }
        }
        return capabilities
    }

    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(contentVersion: Data(entry.contentVersion.utf8),
                                  metadataVersion: Data(entry.metadataVersion.utf8))
    }

    var contentType: UTType {
        if entry.isDirectory { return .folder }
        return UTType(filenameExtension: (filename as NSString).pathExtension) ?? .data
    }

    var documentSize: NSNumber? {
        entry.isDirectory ? nil : NSNumber(value: entry.size)
    }

    var contentModificationDate: Date? {
        entry.modified == .distantPast ? nil : entry.modified
    }

    var fileSystemFlags: NSFileProviderFileSystemFlags {
        var flags: NSFileProviderFileSystemFlags = [.userReadable, .userWritable]
        // Directories must be traversable; files keep the remote owner-execute bit.
        if entry.isDirectory || entry.permissions & 0o100 != 0 {
            flags.insert(.userExecutable)
        }
        if filename.hasPrefix(".") {
            flags.insert(.hidden)
        }
        return flags
    }

    /// Pinned items stay on disk and are fetched before they are opened, which clears the
    /// cloud badge. Everything else is downloaded on open and dropped when the remote changes.
    var contentPolicy: NSFileProviderContentPolicy {
        if keptDownloaded { return .downloadEagerlyAndKeepDownloaded }
        return entry.isDirectory ? .inherited : .downloadLazilyAndEvictOnRemoteUpdate
    }
}
