import Darwin
import Foundation

/// Cross-process exclusion for files the app and the extension both update.
///
/// The lock is a stable sibling (`*.lock`), not the data file itself. Atomic
/// replacements swap the data file's inode, which would drop a lock held on it.
nonisolated enum FileLock {
    static func withLock<T>(url: URL, _ body: () throws -> T) throws -> T {
        let lockURL = url.appendingPathExtension("lock")
        let directory = lockURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: lockURL.path) {
            FileManager.default.createFile(atPath: lockURL.path, contents: nil)
        }
        let handle = try FileHandle(forUpdating: lockURL)
        defer { try? handle.close() }
        guard flock(handle.fileDescriptor, LOCK_EX) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = flock(handle.fileDescriptor, LOCK_UN) }
        return try body()
    }
}
