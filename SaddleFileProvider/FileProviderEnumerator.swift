import FileProvider
import os

/// Lists remote directories, and for the working set, reports remote changes.
///
/// On macOS the system only asks the working set for changes, so it acts as the global
/// change feed: each poll re-lists every directory Finder has enumerated and diffs it
/// against the stored snapshot. The anchor stays put until that diff actually changes,
/// so the system does not re-list on a tight loop between the app's refresh signals.
final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private let container: NSFileProviderItemIdentifier
    private let provider: FileProviderExtension
    private let tasksLock = NSLock()
    private var tasks: [Task<Void, Never>] = []

    /// Directory enumerators are not the change feed. A constant anchor keeps the system
    /// from calling `enumerateChanges` on them forever.
    private static let directoryAnchor = NSFileProviderSyncAnchor(Data("saddle-directory".utf8))

    init(container: NSFileProviderItemIdentifier, provider: FileProviderExtension) {
        self.container = container
        self.provider = provider
        super.init()
    }

    func invalidate() {
        tasksLock.lock()
        let pending = tasks
        tasks.removeAll()
        tasksLock.unlock()
        pending.forEach { $0.cancel() }
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        // Items enter the working set through directory enumeration, so it starts empty.
        guard container != .workingSet else {
            observer.finishEnumerating(upTo: nil)
            return
        }

        let container = container
        let provider = provider
        track(Task {
            do {
                let items = try await provider.listItems(in: container)
                let pageSize = max(1, observer.suggestedPageSize ?? 200)
                for start in stride(from: 0, to: items.count, by: pageSize) {
                    guard !Task.isCancelled else { return }
                    observer.didEnumerate(Array(items[start..<min(start + pageSize, items.count)]))
                }
                observer.finishEnumerating(upTo: nil)
            } catch {
                FileProviderExtension.log.error("enumerate \(container.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                observer.finishEnumeratingWithError(FileProviderExtension.fileProviderError(error))
            }
        })
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        guard container == .workingSet else {
            observer.finishEnumeratingChanges(upTo: Self.directoryAnchor, moreComing: false)
            return
        }

        let provider = provider
        track(Task {
            do {
                let changes = try await provider.pollRemoteChanges()
                if !changes.updated.isEmpty { observer.didUpdate(changes.updated) }
                if !changes.deleted.isEmpty { observer.didDeleteItems(withIdentifiers: changes.deleted) }
                observer.finishEnumeratingChanges(upTo: changes.anchor, moreComing: false)
                await provider.acknowledgeDeletions(changes.reportedDeletionIDs)
            } catch {
                FileProviderExtension.log.error("working set poll failed: \(String(describing: error), privacy: .public)")
                observer.finishEnumeratingWithError(FileProviderExtension.fileProviderError(error))
            }
        })
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        guard container == .workingSet else {
            completionHandler(Self.directoryAnchor)
            return
        }
        let provider = provider
        track(Task {
            completionHandler(await provider.currentAnchor())
        })
    }

    private func track(_ task: Task<Void, Never>) {
        tasksLock.lock()
        tasks.append(task)
        tasksLock.unlock()
    }
}
