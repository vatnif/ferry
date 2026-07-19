import SwiftUI
import FerryCore

/// Settings ▸ Transfers (DESIGN.md screen 5, M16 — ADR-026). Makes the
/// TransferEngine tunables and the conflict/interrupted policies that were
/// hard-coded defaults (M8/M9) user-configurable. Bandwidth limit and checksum
/// verification are v1.x — shown disabled so the layout matches the mockup.
struct TransfersSettingsView: View {
    @AppStorage(AppSettings.Key.simultaneousTransfers)
    private var simultaneous = AppSettings.Default.simultaneousTransfers
    @AppStorage(AppSettings.Key.interruptedTransferPolicy)
    private var interruptedRaw = AppSettings.Default.interruptedPolicy.rawValue
    @AppStorage(AppSettings.Key.fileExistsPolicy)
    private var existsRaw = AppSettings.Default.existsPolicy.rawValue
    @AppStorage(AppSettings.Key.retryCount)
    private var retryCount = AppSettings.Default.retryCount
    @AppStorage(AppSettings.Key.notifyOnQueueFinished)
    private var notifyOnFinished = false
    // v1.x — persisted but the controls ship disabled.
    @AppStorage(AppSettings.Key.bandwidthLimitEnabled)
    private var bandwidthLimit = false
    @AppStorage(AppSettings.Key.verifyChecksums)
    private var verifyChecksums = false

    var body: some View {
        SettingsForm {
            Section {
                Stepper(value: $simultaneous, in: AppSettings.simultaneousTransfersRange) {
                    Text("Simultaneous transfers: \(simultaneous) per connection")
                }
                .accessibilityIdentifier("settings.transfers.simultaneous")

                Picker("When a transfer is interrupted", selection: $interruptedRaw) {
                    Text("Resume automatically").tag(InterruptedTransferPolicy.resume.rawValue)
                    Text("Ask").tag(InterruptedTransferPolicy.ask.rawValue)
                    Text("Restart").tag(InterruptedTransferPolicy.restart.rawValue)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.transfers.interrupted")
                Text("Partial downloads are kept as **name.ferrypart** and continued from the last verified byte.")
                    .font(.caption).foregroundStyle(.secondary)

                Picker("If the file already exists", selection: $existsRaw) {
                    Text("Overwrite").tag(FileExistsPolicy.overwrite.rawValue)
                    Text("Ask").tag(FileExistsPolicy.ask.rawValue)
                    Text("Skip").tag(FileExistsPolicy.skip.rawValue)
                    Text("Rename").tag(FileExistsPolicy.rename.rawValue)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.transfers.exists")

                Stepper(value: $retryCount, in: AppSettings.retryCountRange) {
                    Text("Retry failed transfers: \(retryCount) times, \(AppSettings.Default.retryDelaySeconds) s apart")
                }
                .accessibilityIdentifier("settings.transfers.retry")
            }

            Section {
                Toggle(isOn: $bandwidthLimit) {
                    Text("Limit total throughput")
                    Text("Bandwidth limiting arrives in a later update.")
                }
                .disabled(true)

                Toggle("Show a notification when the queue finishes", isOn: $notifyOnFinished)
                    .accessibilityIdentifier("settings.transfers.notify")

                Toggle(isOn: $verifyChecksums) {
                    Text("Verify transfers with a checksum when the server supports it")
                    Text("Checksum verification arrives in a later update.")
                }
                .disabled(true)
            }

            SettingsFootnote()
        }
    }
}
