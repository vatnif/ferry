import SwiftUI
import FerryCore

/// The connection tab strip above the detail column (DESIGN.md screen 1
/// `.wintabs`, M16 checkpoint B / ADR-027): one chip per open connection with a
/// green (connected) / grey (disconnected) dot, the active chip highlighted, a
/// per-tab ✕, and a trailing ＋ for a new tab. The sidebar is shared across all
/// tabs; only the detail area follows the selected tab.
struct TabStripView: View {
    @Environment(ConnectionManagerModel.self) private var model

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(model.tabs.tabs.enumerated()), id: \.element.id) { index, tab in
                    TabChip(tab: tab, index: index, isActive: tab.id == model.tabs.selectedID)
                }
                Button(action: { model.newTab() }) {
                    Image(systemName: "plus")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("New Tab")
                .accessibilityIdentifier("tabStrip.newTab")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// One tab chip. Clicking selects; the ✕ (shown on the active or hovered chip)
/// closes it, warning first when transfers are running (ADR-027).
private struct TabChip: View {
    @Environment(ConnectionManagerModel.self) private var model
    let tab: ConnectionTab
    let index: Int
    let isActive: Bool
    @State private var hovering = false

    var body: some View {
        // Two side-by-side buttons (select + close) sharing one chip background,
        // rather than an overlay — overlapping buttons get merged in
        // accessibility and the ✕ then can't be found by XCUITest.
        HStack(spacing: 4) {
            Button(action: { model.selectTab(tab.id) }) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 7, height: 7)
                    Text(model.title(for: tab))
                        .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tabStrip.tab.\(index)")

            if isActive || hovering {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close Tab")
                .accessibilityIdentifier("tabStrip.close.\(index)")
            } else {
                // Reserve the ✕'s width so the title doesn't shift.
                Color.clear.frame(width: 14, height: 14)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: 200)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color(nsColor: .controlBackgroundColor) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isActive ? Color.secondary.opacity(0.3) : .clear)
        )
        .onHover { hovering = $0 }
    }

    private var dotColor: Color {
        switch tab.phase {
        case .connected: return .green
        case .connecting: return .yellow
        case .idle: return Color.secondary.opacity(0.5)
        }
    }

    private func close() {
        if model.tabHasActiveTransfers(tab) {
            model.pendingTabClose = tab.id
        } else {
            model.closeTab(tab.id)
        }
    }
}
