import Foundation
import FerryCore

/// A point-in-time read of the transfer-related settings (Settings ▸
/// Transfers, M16). Models read this instead of binding to `@AppStorage` so
/// they can consult the *current* values without being views. The engine
/// tunables are read once per connection; the conflict/interrupted policies
/// are read at each staging call, so a change applies to the next transfer
/// immediately ("Changes apply immediately", DESIGN.md screen 5).
struct TransferSettingsSnapshot {
    var simultaneous: Int
    var maxAttempts: Int
    var retryDelay: Duration
    var existsPolicy: FileExistsPolicy
    var interruptedPolicy: InterruptedTransferPolicy
    var notifyOnFinished: Bool

    static var current: TransferSettingsSnapshot {
        let d = UserDefaults.standard

        func int(_ key: String, default def: Int, in range: ClosedRange<Int>) -> Int {
            let value = d.object(forKey: key) == nil ? def : d.integer(forKey: key)
            return min(range.upperBound, max(range.lowerBound, value))
        }

        let retries = int(AppSettings.Key.retryCount,
                          default: AppSettings.Default.retryCount,
                          in: AppSettings.retryCountRange)

        let exists = d.string(forKey: AppSettings.Key.fileExistsPolicy)
            .flatMap(FileExistsPolicy.init(rawValue:)) ?? AppSettings.Default.existsPolicy
        let interrupted = d.string(forKey: AppSettings.Key.interruptedTransferPolicy)
            .flatMap(InterruptedTransferPolicy.init(rawValue:)) ?? AppSettings.Default.interruptedPolicy

        return TransferSettingsSnapshot(
            simultaneous: int(AppSettings.Key.simultaneousTransfers,
                              default: AppSettings.Default.simultaneousTransfers,
                              in: AppSettings.simultaneousTransfersRange),
            // "Retry N times" = N retries on top of the first attempt.
            maxAttempts: retries + 1,
            retryDelay: .seconds(AppSettings.Default.retryDelaySeconds),
            existsPolicy: exists,
            interruptedPolicy: interrupted,
            notifyOnFinished: d.bool(forKey: AppSettings.Key.notifyOnQueueFinished))
    }
}
