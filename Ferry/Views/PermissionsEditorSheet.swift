import SwiftUI
import FerryCore

/// chmod editor (DESIGN.md screen 1 → context menu; DOMAIN.md M10). A 3×3
/// rwx grid kept in sync with an editable octal field; applies the result
/// through the pane's FileSystemSource. Works for local and remote files.
struct PermissionsEditorSheet: View {
    let item: FileItem
    /// Called with the chosen permissions when the user taps Apply.
    let onApply: (FilePermissions) -> Void
    @Environment(\.dismiss) private var dismiss

    /// Lower 12 bits of the POSIX mode being edited.
    @State private var mode: UInt16
    @State private var octalText: String

    init(item: FileItem, onApply: @escaping (FilePermissions) -> Void) {
        self.item = item
        self.onApply = onApply
        let initial = item.permissions?.rawMode ?? 0o644
        _mode = State(initialValue: initial)
        _octalText = State(initialValue: String(initial, radix: 8))
    }

    private struct Klass: Identifiable { let id = UUID(); let label: String; let shift: UInt16 }
    private static let classes = [
        Klass(label: "Owner", shift: 6),
        Klass(label: "Group", shift: 3),
        Klass(label: "Others", shift: 0),
    ]
    private static let bits: [(label: String, mask: UInt16)] = [
        ("Read", 0b100), ("Write", 0b010), ("Execute", 0b001),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Permissions").font(.headline)
                Label(item.name, systemImage: item.iconName)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            grid

            HStack(spacing: 8) {
                Text("Octal").foregroundStyle(.secondary)
                TextField("644", text: $octalText)
                    .frame(width: 70)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { applyOctalText() }
                    .onChange(of: octalText) { _, _ in applyOctalText() }
                Spacer()
                Text(FilePermissions(rawMode: mode).symbolic)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    onApply(FilePermissions(rawMode: mode))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                Text("").gridColumnAlignment(.leading)
                ForEach(Self.bits, id: \.label) { bit in
                    Text(bit.label).font(.caption).foregroundStyle(.secondary)
                        .frame(width: 60)
                }
            }
            ForEach(Self.classes) { klass in
                GridRow {
                    Text(klass.label).frame(width: 60, alignment: .leading)
                    ForEach(Self.bits, id: \.label) { bit in
                        Toggle("", isOn: binding(shift: klass.shift, mask: bit.mask))
                            .labelsHidden()
                            .frame(width: 60)
                    }
                }
            }
        }
    }

    private func binding(shift: UInt16, mask: UInt16) -> Binding<Bool> {
        let flag = mask << shift
        return Binding(
            get: { mode & flag != 0 },
            set: { on in
                if on { mode |= flag } else { mode &= ~flag }
                octalText = String(mode, radix: 8)
            })
    }

    private func applyOctalText() {
        guard let parsed = FilePermissions(octalString: octalText) else { return }
        mode = parsed.rawMode
    }
}
