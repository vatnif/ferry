import SwiftUI
import FerryCore

/// Transfer queue dock (DESIGN.md screen 1): collapsible, one row per item
/// with progress, meta, badge, pause/resume (M9) and cancel.
struct TransferQueueView: View {
    let queue: TransferQueueModel
    @State private var collapsed = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if !collapsed {
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(queue.rows) { row in
                            QueueRowView(row: row, queue: queue)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 140)
            }
        }
        .background(.bar)
        .accessibilityIdentifier("queue.dock")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Transfers")
                .font(.caption.bold())
            Text("\(queue.activeCount) active · \(queue.queuedCount) queued")
                .font(.caption2.bold())
                .padding(.horizontal, 7)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                .foregroundStyle(Color.accentColor)
                .accessibilityIdentifier("queue.counts")
            Spacer()
            if queue.hasFinishedRows {
                Button("Clear") { queue.clearFinished() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Remove finished transfers from the list")
                    .accessibilityIdentifier("queue.clear")
            }
            Button {
                collapsed.toggle()
            } label: {
                Image(systemName: collapsed ? "chevron.up" : "chevron.down")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(collapsed ? "Show the transfer queue" : "Hide the transfer queue")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture { collapsed.toggle() }
    }
}

private struct QueueRowView: View {
    let row: TransferQueueModel.Row
    let queue: TransferQueueModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: rowIcon)
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).font(.caption.weight(.semibold))
                Text(row.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                ProgressView(value: row.fraction ?? (row.phase == .running ? nil : 0), total: 1)
                    .progressViewStyle(.linear)
                    .frame(width: 220)
                Text(row.metaText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(row.phase.isError ? .red : .secondary)
                    .lineLimit(1)
                    .help(row.metaText)
            }

            badge

            if row.canPause {
                Button {
                    queue.pause(id: row.id)
                } label: {
                    Image(systemName: "pause.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Pause — partial data is kept and can be resumed")
                .accessibilityIdentifier("queue.pause")
            }
            if row.canResume {
                Button {
                    queue.resume(id: row.id)
                } label: {
                    Image(systemName: "play.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help(row.phase == .paused ? "Resume" : "Retry")
                .accessibilityIdentifier("queue.resume")
            }
            if row.canCancel {
                Button {
                    queue.cancel(id: row.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Cancel")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private var rowIcon: String {
        if row.kind == .directory { return "folder" }
        return row.direction == .upload ? "arrow.up.circle" : "arrow.down.circle"
    }

    private var badge: some View {
        Text(row.badgeText)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(badgeColor.opacity(0.15)))
            .foregroundStyle(badgeColor)
    }

    private var badgeColor: Color {
        switch row.phase {
        case .queued: .secondary
        case .running: .accentColor
        case .paused: .orange
        case .completed: .green
        case .failed: .red
        case .cancelled: .orange
        }
    }
}

private extension TransferSnapshot.Phase {
    var isError: Bool {
        if case .failed = self { return true }
        return false
    }
}
