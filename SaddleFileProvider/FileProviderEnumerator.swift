import FileProvider

/// Lists remote directories, and for the working set, reports remote changes.
///
/// On macOS the system only asks the working set for changes, so it acts as the global
/// change feed: each poll re-lists every directory Finder has enumerated and diffs it
/// against the stored snapshot.
final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private let container: NSFileProviderItemIdentifier
    private let provider: FileProviderExtension
    private var tasks: [Task<Void, Never>] = []

    init(container: NSFileProviderItemIdentifier, provider: FileProviderExtension) {
        self.container = container
        self.provider = provider
        super.init()
    }

    func invalidate() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        // Items enter the working set through directory enumeration, so it starts empty.
        guard container != .workingSet else {
            observer.finishEnumerating(upTo: nil)
            return
        }

        let container = container
        let provider = provider
        tasks.append(Task {
            do {
                let items = try await provider.listItems(in: container)
                let pageSize = max(1, observer.suggestedPageSize ?? 200)
                for start in stride(from: 0, to: items.count, by: pageSize) {
                    observer.didEnumerate(Array(items[start..<min(start + pageSize, items.count)]))
                }
                observer.finishEnumerating(upTo: nil)
            } catch {
                observer.finishEnumeratingWithError(FileProviderExtension.fileProviderError(error))
            }
        })
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        guard container == .workingSet else {
            observer.finishEnumeratingChanges(upTo: Self.makeAnchor(), moreComing: false)
            return
        }

        let provider = provider
        tasks.append(Task {
            do {
                let changes = try await provider.pollRemoteChanges()
                if !changes.updated.isEmpty { observer.didUpdate(changes.updated) }
                if !changes.deleted.isEmpty { observer.didDeleteItems(withIdentifiers: changes.deleted) }
                observer.finishEnumeratingChanges(upTo: Self.makeAnchor(), moreComing: false)
            } catch {
                observer.finishEnumeratingWithError(FileProviderExtension.fileProviderError(error))
            }
        })
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(Self.makeAnchor())
    }

    private static func makeAnchor() -> NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(Data(String(Date().timeIntervalSince1970).utf8))
    }
}
