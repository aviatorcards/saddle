import SwiftUI

/// The popover shown from the menu bar icon.
struct MenuContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Saddle")
                    .font(.headline)
                Spacer()
                Button("Refresh All", systemImage: "arrow.clockwise") {
                    Task { await model.refreshAll() }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Check all connected servers for changes")
            }

            if model.profiles.isEmpty {
                VStack(spacing: 8) {
                    Text("No connections yet")
                        .foregroundStyle(.secondary)
                    Button("Add Connection…", action: showConnections)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                VStack(spacing: 2) {
                    ForEach(model.profiles) { profile in
                        ConnectionRow(profile: profile)
                    }
                }
            }

            if !model.activeTransfers.isEmpty {
                Divider()
                Text("Transfers")
                    .font(.subheadline.weight(.semibold))
                ForEach(model.activeTransfers, id: \.transfer.id) { item in
                    TransferRow(transfer: item.transfer)
                }
            }

            if !model.activity.isEmpty {
                Divider()
                Text("Recent Activity")
                    .font(.subheadline.weight(.semibold))
                ForEach(model.activity.prefix(5)) { entry in
                    ActivityRow(entry: entry, profileName: model.profile(withID: entry.profileID)?.displayName)
                }
            }

            Divider()
            HStack {
                Button("Manage Connections…", action: showConnections)
                Spacer()
                Button("Quit Saddle") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .frame(width: 340)
    }

    private func showConnections() {
        openWindow(id: ConnectionsView.windowID)
        NSApp.activate()
    }
}

private struct ConnectionRow: View {
    @Environment(AppModel.self) private var model
    let profile: ConnectionProfile

    var body: some View {
        let state = model.state(for: profile)
        HStack(spacing: 8) {
            StatusDot(state: state)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.displayName)
                    .lineLimit(1)
                Text(subtitle(for: state))
                    .font(.caption)
                    .foregroundStyle(isError(state) ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
            }
            Spacer()

            switch state {
            case .connecting:
                ProgressView()
                    .controlSize(.small)
            case .disconnected:
                Button("Connect") { Task { await model.connect(profile) } }
                    .controlSize(.small)
            case .error where !model.mountedIDs.contains(profile.id):
                Button("Retry") { Task { await model.connect(profile) } }
                    .controlSize(.small)
            default:
                HStack(spacing: 6) {
                    Button("Open in Finder", systemImage: "folder") { Task { await model.openInFinder(profile) } }
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh(profile) } }
                    Button("Eject", systemImage: "eject") { Task { await model.disconnect(profile) } }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }

    private func subtitle(for state: ConnectionState) -> String {
        switch state {
        case .error(let message): message
        case .connecting: "Connecting…"
        case .syncing: "Syncing…"
        default: "\(profile.username)@\(profile.host)"
        }
    }

    private func isError(_ state: ConnectionState) -> Bool {
        if case .error = state { return true }
        return false
    }
}

private struct StatusDot: View {
    let state: ConnectionState

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityLabel(label)
    }

    private var color: Color {
        switch state {
        case .disconnected: .secondary.opacity(0.4)
        case .connecting, .syncing: .blue
        case .connected: .green
        case .error: .red
        }
    }

    private var label: String {
        switch state {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting"
        case .syncing: "Syncing"
        case .connected: "Connected"
        case .error: "Error"
        }
    }
}

private struct TransferRow: View {
    let transfer: DomainStatus.Transfer

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(transfer.name, systemImage: transfer.isUpload ? "arrow.up.circle" : "arrow.down.circle")
                .font(.caption)
                .lineLimit(1)
            ProgressView(value: transfer.fraction)
            Text("\(transfer.completedBytes.formatted(.byteCount(style: .file))) of \(transfer.totalBytes.formatted(.byteCount(style: .file)))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ActivityRow: View {
    let entry: ActivityLog.Entry
    let profileName: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: entry.isError ? "exclamationmark.triangle.fill" : "checkmark.circle")
                .foregroundStyle(entry.isError ? .orange : .secondary)
                .font(.caption)
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.message)
                    .font(.caption)
                    .lineLimit(2)
                Text([profileName, entry.date.formatted(.relative(presentation: .named))].compactMap(\.self).joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
