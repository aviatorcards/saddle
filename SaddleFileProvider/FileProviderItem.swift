import FileProvider
import UniformTypeIdentifiers

/// Finder-facing metadata for a remote file or folder.
final class FileProviderItem: NSObject, NSFileProviderItem {
    let entry: RemoteEntry
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String

    init(entry: RemoteEntry, identifier: NSFileProviderItemIdentifier, parent: NSFileProviderItemIdentifier, filename: String? = nil) {
        self.entry = entry
        self.itemIdentifier = identifier
        self.parentItemIdentifier = parent
        self.filename = filename ?? entry.name
    }

    var capabilities: NSFileProviderItemCapabilities {
        var capabilities: NSFileProviderItemCapabilities = [.allowsReading, .allowsWriting, .allowsDeleting]
        if itemIdentifier != .rootContainer {
            capabilities.formUnion([.allowsRenaming, .allowsReparenting])
        }
        if entry.isDirectory {
            capabilities.formUnion([.allowsContentEnumerating, .allowsAddingSubItems])
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

    /// Downloaded copies are dropped when the remote file changes, so stale data is never
    /// served and the local cache doesn't grow with superseded versions.
    var contentPolicy: NSFileProviderContentPolicy {
        entry.isDirectory ? .inherited : .downloadLazilyAndEvictOnRemoteUpdate
    }
}
