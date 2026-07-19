import XCTest
@testable import FerryCore

/// Unit tests for the settings foundation (M16, DESIGN.md screen 5): the
/// enum raw-value + key-string persistence contract, the shipping defaults,
/// the interrupted-policy → transfer-mode mapping, `LoggingLevel` ordering,
/// and the pure Rename-preset name de-duplication.
final class AppSettingsTests: XCTestCase {

    // MARK: Persistence contract (raw values must never drift silently)

    func testEnumRawValues() {
        XCTAssertEqual(AppearancePreference.system.rawValue, "system")
        XCTAssertEqual(AppearancePreference.light.rawValue, "light")
        XCTAssertEqual(AppearancePreference.dark.rawValue, "dark")

        XCTAssertEqual(InterruptedTransferPolicy.resume.rawValue, "resume")
        XCTAssertEqual(InterruptedTransferPolicy.ask.rawValue, "ask")
        XCTAssertEqual(InterruptedTransferPolicy.restart.rawValue, "restart")

        XCTAssertEqual(FileExistsPolicy.overwrite.rawValue, "overwrite")
        XCTAssertEqual(FileExistsPolicy.ask.rawValue, "ask")
        XCTAssertEqual(FileExistsPolicy.skip.rawValue, "skip")
        XCTAssertEqual(FileExistsPolicy.rename.rawValue, "rename")

        XCTAssertEqual(LoggingLevel.off.rawValue, "off")
        XCTAssertEqual(LoggingLevel.errors.rawValue, "errors")
        XCTAssertEqual(LoggingLevel.verbose.rawValue, "verbose")

        // Unknown strings never coerce to a case.
        XCTAssertNil(FileExistsPolicy(rawValue: "bogus"))
    }

    func testKeyStringsAreStable() {
        // The two terminal keys are the M15 storage contract (ADR-024).
        XCTAssertEqual(AppSettings.Key.terminalPreference, "terminalPreference")
        XCTAssertEqual(AppSettings.Key.terminalCustomCommand, "terminalCustomCommand")
        // New M16 keys.
        XCTAssertEqual(AppSettings.Key.terminalScrollbackLines, "terminalScrollbackLines")
        XCTAssertEqual(AppSettings.Key.simultaneousTransfers, "simultaneousTransfers")
        XCTAssertEqual(AppSettings.Key.fileExistsPolicy, "fileExistsPolicy")
        XCTAssertEqual(AppSettings.Key.appearance, "appearancePreference")
        XCTAssertEqual(AppSettings.Key.loggingLevel, "loggingLevel")
    }

    // MARK: Defaults match the mockup

    func testDefaults() {
        XCTAssertEqual(AppSettings.Default.simultaneousTransfers, 3)
        XCTAssertEqual(AppSettings.Default.retryCount, 3)
        XCTAssertEqual(AppSettings.Default.retryDelaySeconds, 5)
        XCTAssertEqual(AppSettings.Default.terminalFontSize, 12)
        XCTAssertEqual(AppSettings.Default.terminalScrollbackLines, 10_000)
        XCTAssertEqual(AppSettings.Default.appearance, .system)
        XCTAssertEqual(AppSettings.Default.interruptedPolicy, .resume)
        XCTAssertEqual(AppSettings.Default.existsPolicy, .ask)
        XCTAssertEqual(AppSettings.Default.loggingLevel, .errors)
    }

    // MARK: Interrupted policy → transfer mode

    func testInterruptedPolicyMode() {
        XCTAssertEqual(InterruptedTransferPolicy.resume.transferMode, .automatic)
        XCTAssertEqual(InterruptedTransferPolicy.restart.transferMode, .restart)
        // Ask has no non-interactive mode; falls back to automatic.
        XCTAssertEqual(InterruptedTransferPolicy.ask.transferMode, .automatic)
    }

    // MARK: LoggingLevel ordering

    func testLoggingLevelComparable() {
        XCTAssertLessThan(LoggingLevel.off, .errors)
        XCTAssertLessThan(LoggingLevel.errors, .verbose)
        XCTAssertGreaterThanOrEqual(LoggingLevel.verbose, .errors)
    }

    // MARK: Rename preset — pure name de-duplication

    func testDeduplicatedNameNoCollision() {
        XCTAssertEqual(TransferNaming.deduplicatedName(for: "report.txt", existing: []), "report.txt")
        XCTAssertEqual(TransferNaming.deduplicatedName(for: "report.txt", existing: ["other.txt"]), "report.txt")
    }

    func testDeduplicatedNameWithExtension() {
        XCTAssertEqual(
            TransferNaming.deduplicatedName(for: "report.txt", existing: ["report.txt"]),
            "report 2.txt")
        XCTAssertEqual(
            TransferNaming.deduplicatedName(for: "report.txt", existing: ["report.txt", "report 2.txt"]),
            "report 3.txt")
    }

    func testDeduplicatedNameFolderNoExtension() {
        XCTAssertEqual(
            TransferNaming.deduplicatedName(for: "builds", existing: ["builds"]),
            "builds 2")
    }

    func testDeduplicatedNameDotfile() {
        // A leading dot is not an extension separator.
        XCTAssertEqual(
            TransferNaming.deduplicatedName(for: ".bashrc", existing: [".bashrc"]),
            ".bashrc 2")
    }

    func testDeduplicatedNameMultipleDots() {
        // Only the last extension is preserved.
        XCTAssertEqual(
            TransferNaming.deduplicatedName(for: "archive.tar.gz", existing: ["archive.tar.gz"]),
            "archive.tar 2.gz")
    }

    func testSplitExtension() {
        XCTAssertEqual(TransferNaming.splitExtension("a.txt").base, "a")
        XCTAssertEqual(TransferNaming.splitExtension("a.txt").ext, "txt")
        XCTAssertEqual(TransferNaming.splitExtension("noext").ext, "")
        XCTAssertEqual(TransferNaming.splitExtension(".hidden").ext, "")
        XCTAssertEqual(TransferNaming.splitExtension("trailing.").ext, "")
    }
}
