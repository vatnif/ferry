import SwiftUI
import FerryCore

/// The Ferry Help window (Help ▸ Ferry Help, M16 checkpoint C, ADR-028): a
/// minimal in-app user guide — the prose topics (incl. the .ferrypart/resume
/// explainer) and a keyboard-shortcut reference. Content comes from the pure
/// `HelpContent` model in FerryCore; this view only renders it. A standalone
/// `Window` so it is XCUITest-drivable (ADR-025) and reachable from the Help
/// menu.
struct HelpGuideWindowView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                ForEach(HelpContent.topics) { topic in
                    HelpTopicSection(topic: topic)
                }
                shortcutsSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 540, minHeight: 460)
        .accessibilityIdentifier("help.window")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ferry Help")
                .font(.title2.bold())
                .accessibilityIdentifier("help.title")
            Text("A quick guide to getting around Ferry.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Keyboard shortcuts")
                .font(.title3.bold())
            VStack(spacing: 0) {
                ForEach(Array(HelpContent.shortcuts.enumerated()), id: \.element.id) { index, shortcut in
                    HStack(alignment: .firstTextBaseline) {
                        Text(shortcut.keys)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 150, alignment: .leading)
                        Text(shortcut.action)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 7)
                    .padding(.horizontal, 12)
                    .background(index.isMultiple(of: 2) ? Color(nsColor: .controlBackgroundColor) : Color.clear)
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.15)))
        }
        .accessibilityIdentifier("help.shortcuts")
    }
}

/// One prose topic: heading + body paragraphs.
private struct HelpTopicSection: View {
    let topic: HelpTopic

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(topic.title)
                .font(.title3.bold())
            Text(topic.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
