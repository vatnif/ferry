import SwiftUI
import FerryCore

/// The Acknowledgements window (Help ▸ Acknowledgements…, M16 checkpoint C,
/// ADR-028). Reproduces the copyright + license notices for every bundled
/// dependency (MIT/Apache-2.0/curl obligations, docs/LICENSING.md). Content
/// comes from the pure `Acknowledgements` model in FerryCore; this view only
/// renders it. A standalone `Window` (not a Settings tab) so it is
/// XCUITest-drivable (ADR-025) and reachable from the Help menu.
struct AcknowledgementsWindowView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                ForEach(Acknowledgements.all) { ack in
                    AcknowledgementRow(ack: ack)
                }
                Divider()
                Text("Ferry © \(Calendar.current.component(.year, from: .now)) George Fragos. All rights reserved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 520, minHeight: 420)
        .accessibilityIdentifier("acknowledgements.window")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Acknowledgements")
                .font(.title2.bold())
                .accessibilityIdentifier("acknowledgements.title")
            Text("Ferry is built with these open-source components. Thank you to their authors.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// One dependency: name + license pill + what Ferry uses it for + the copyright
/// line, with the full license text tucked behind a disclosure.
private struct AcknowledgementRow: View {
    let ack: Acknowledgement
    @State private var showLicense = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(ack.name)
                    .font(.headline)
                LicensePill(license: ack.license)
                Spacer()
            }
            Text(ack.purpose)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(ack.copyright)
                .font(.caption)
                .foregroundStyle(.secondary)
            DisclosureGroup(isExpanded: $showLicense) {
                Text(ack.license.body)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 4)
            } label: {
                Text("License")
                    .font(.caption)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .accessibilityIdentifier("acknowledgements.item.\(ack.name)")
    }
}

/// A small rounded license label (e.g. "MIT", "Apache-2.0"). Uses the accent
/// tint so it adapts in both appearances (DESIGN.md).
private struct LicensePill: View {
    let license: DependencyLicense

    var body: some View {
        Text(license.rawValue)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.15)))
            .foregroundStyle(Color.accentColor)
    }
}
