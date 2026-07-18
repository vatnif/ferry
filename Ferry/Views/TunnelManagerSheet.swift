import SwiftUI
import FerryCore

/// Tunnel manager — DESIGN.md screen 4. A per-connection table of saved port
/// forwards: toggle to start/stop live, a live status column, Edit/Add, and the
/// "start automatically on connect" footer switch. Runtime state comes from the
/// session's `TunnelController`; the tunnel list is persisted on the profile via
/// `ConnectionManagerModel`.
struct TunnelManagerSheet: View {
    let profileID: UUID
    let controller: TunnelController

    @Environment(ConnectionManagerModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// Non-nil edits that tunnel; `isAdding` presents a blank editor.
    @State private var editing: TunnelConfiguration?
    @State private var isAdding = false

    private var profile: ConnectionProfile? { model.library.profile(withID: profileID) }
    private var tunnels: [TunnelConfiguration] { profile?.tunnels ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if tunnels.isEmpty {
                emptyState
            } else {
                table
            }
            Divider()
            footer
        }
        .frame(width: 620, height: 380)
        .sheet(isPresented: $isAdding) {
            TunnelEditorSheet(existing: nil) { model.addTunnel($0, toProfileID: profileID) }
        }
        .sheet(item: $editing) { tunnel in
            TunnelEditorSheet(existing: tunnel,
                              onSave: { model.updateTunnel($0, inProfileID: profileID) },
                              onDelete: {
                                  controller.stop(tunnel.id)
                                  model.removeTunnel(tunnel.id, fromProfileID: profileID)
                              })
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Tunnels — \(profile?.name ?? "")").font(.headline)
                Text("Per-connection port forwards. Toggles work live while connected.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private var columnHeaders: some View {
        HStack(spacing: 0) {
            Text("Active").frame(width: 60, alignment: .leading)
            Text("Type").frame(width: 76, alignment: .leading)
            Text("Listen").frame(width: 150, alignment: .leading)
            Text("Destination").frame(width: 150, alignment: .leading)
            Text("Status").frame(maxWidth: .infinity, alignment: .leading)
            Text("").frame(width: 52)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.4))
    }

    private var table: some View {
        VStack(spacing: 0) {
            columnHeaders
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(tunnels) { tunnel in
                        TunnelRow(tunnel: tunnel,
                                  phase: controller.phase(for: tunnel.id),
                                  onToggle: { setActive(tunnel, $0) },
                                  onEdit: { editing = tunnel })
                        Divider()
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text("No tunnels yet").font(.headline)
            Text("Add a local, remote, or SOCKS port forward.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack {
            Button {
                isAdding = true
            } label: {
                Label("Add Tunnel", systemImage: "plus")
            }
            .accessibilityIdentifier("tunnels.add")
            Spacer()
            Toggle(isOn: autoStartBinding) {
                Text("Start active tunnels automatically on connect")
            }
            .toggleStyle(.checkbox)
        }
        .padding(12)
    }

    private var autoStartBinding: Binding<Bool> {
        Binding(get: { profile?.autoStartsTunnels ?? true },
                set: { model.setAutoStartTunnels($0, inProfileID: profileID) })
    }

    /// Toggle in the Active column: persist the enabled flag and start/stop the
    /// tunnel live (DESIGN.md: toggles work while connected).
    private func setActive(_ tunnel: TunnelConfiguration, _ on: Bool) {
        model.setTunnelEnabled(tunnel.id, on, inProfileID: profileID)
        if on { controller.start(tunnel) } else { controller.stop(tunnel.id) }
    }
}

/// One row of the tunnel table.
private struct TunnelRow: View {
    let tunnel: TunnelConfiguration
    let phase: TunnelStatus.Phase
    let onToggle: (Bool) -> Void
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Toggle("", isOn: Binding(get: { isActive }, set: { onToggle($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .frame(width: 60, alignment: .leading)
                .accessibilityIdentifier("tunnel.toggle.\(tunnel.listenPort)")
            TunnelTypePill(kind: tunnel.kind).frame(width: 76, alignment: .leading)
            Text("\(tunnel.listenHost):\(String(tunnel.listenPort))")
                .font(.system(.caption, design: .monospaced))
                .frame(width: 150, alignment: .leading)
            Text(destinationText)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(tunnel.kind == .socks ? .secondary : .primary)
                .frame(width: 150, alignment: .leading)
            statusView.frame(maxWidth: .infinity, alignment: .leading)
            Button("Edit", action: onEdit)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .frame(width: 52)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    /// The toggle reflects the live phase where meaningful, falling back to the
    /// saved enabled flag (so a stopped-but-enabled tunnel still reads active).
    private var isActive: Bool {
        switch phase {
        case .forwarding, .starting: return true
        case .failed: return true // user intent was "on"; status shows the error
        case .stopped: return tunnel.isEnabled
        }
    }

    private var destinationText: String {
        switch tunnel.kind {
        case .socks: return "— (dynamic)"
        default:
            let host = tunnel.destinationHost ?? "?"
            let port = tunnel.destinationPort.map(String.init) ?? "?"
            return "\(host):\(port)"
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch phase {
        case .stopped:
            Text("stopped").font(.caption).foregroundStyle(.secondary)
        case .starting:
            Text("starting…").font(.caption).foregroundStyle(.secondary)
        case .forwarding(let count):
            Label {
                Text(count > 0 ? "forwarding · \(count) conn\(count == 1 ? "" : "s")" : "forwarding")
                    .font(.caption)
            } icon: {
                Circle().fill(.green).frame(width: 7, height: 7)
            }
            .foregroundStyle(.green)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
        }
    }
}

/// LOCAL / REMOTE / SOCKS pill, colours per mockup (accent / orange / purple).
struct TunnelTypePill: View {
    let kind: TunnelConfiguration.Kind

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .bold))
            .tracking(0.5)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        switch kind {
        case .local: "LOCAL"
        case .remote: "REMOTE"
        case .socks: "SOCKS"
        }
    }

    private var color: Color {
        switch kind {
        case .local: .accentColor
        case .remote: .orange
        case .socks: Color(red: 0x7a / 255, green: 0x5f / 255, blue: 0xd0 / 255)
        }
    }
}
