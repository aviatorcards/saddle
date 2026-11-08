import Foundation

/// Publishes connection state and in-flight transfers to the menu bar app via the App Group.
actor StatusReporter {
    private let profileID: UUID
    private var status = DomainStatus()
    private var lastWrite = Date.distantPast

    init(profileID: UUID) {
        self.profileID = profileID
    }

    func set(_ state: DomainStatus.State, message: String? = nil) {
        guard status.state != state || status.message != message else { return }
        if state == .error, let message {
            ActivityLog.append(message, profileID: profileID, isError: true)
        } else if state == .connected, status.state != .connected {
            ActivityLog.append("Connected", profileID: profileID)
        }
        status.state = state
        status.message = message
        write(force: true)
    }

    func beginTransfer(name: String, isUpload: Bool, totalBytes: Int64) -> UUID {
        let id = UUID()
        status.transfers.append(.init(id: id, name: name, isUpload: isUpload, completedBytes: 0, totalBytes: totalBytes))
        write(force: true)
        return id
    }

    func updateTransfer(_ id: UUID, completedBytes: Int64) {
        guard let index = status.transfers.firstIndex(where: { $0.id == id }) else { return }
        status.transfers[index].completedBytes = completedBytes
        write(force: false)
    }

    func endTransfer(_ id: UUID, error: Error?) {
        guard let index = status.transfers.firstIndex(where: { $0.id == id }) else { return }
        let transfer = status.transfers.remove(at: index)
        let verb = transfer.isUpload ? "Uploaded" : "Downloaded"
        if let error {
            ActivityLog.append("\(transfer.isUpload ? "Upload" : "Download") of \(transfer.name) failed: \(error.localizedDescription)",
                               profileID: profileID, isError: true)
        } else {
            ActivityLog.append("\(verb) \(transfer.name)", profileID: profileID)
        }
        write(force: true)
    }

    func log(_ message: String) {
        ActivityLog.append(message, profileID: profileID)
    }

    /// Progress updates are throttled to a few writes per second.
    private func write(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastWrite) > 0.5 else { return }
        lastWrite = now
        status.updated = now
        status.write(for: profileID)
    }
}
