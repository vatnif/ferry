import XCTest
@testable import FerryCore

/// Pure-logic unit tests for SCPSource's shell quoting and error classification
/// (M13). These need no server. Gated to macOS 15 like `SCPSource` itself
/// (Citadel's bidirectional exec is macOS 15+, ADR-020); they run on this
/// machine (macOS 26).
@available(macOS 15.0, *)
final class SCPSourceUnitTests: XCTestCase {

    // MARK: shellQuote — the injection barrier for exec'd commands

    func testShellQuoteWrapsPlainPath() {
        XCTAssertEqual(SCPSource.shellQuote("/home/ferry/file.txt"),
                       "'/home/ferry/file.txt'")
    }

    func testShellQuotePreservesSpaces() {
        XCTAssertEqual(SCPSource.shellQuote("/home/ferry/my file.txt"),
                       "'/home/ferry/my file.txt'")
    }

    func testShellQuoteEscapesSingleQuotes() {
        // A name containing a single quote must not break out of the quoting.
        XCTAssertEqual(SCPSource.shellQuote("a'b"), "'a'\\''b'")
    }

    func testShellQuoteNeutralizesInjectionAttempt() {
        // The classic attack: a path that tries to smuggle a second command.
        let malicious = "/home/ferry/x; rm -rf /"
        let quoted = SCPSource.shellQuote(malicious)
        // Everything stays inside one single-quoted literal — no unquoted ';'.
        XCTAssertTrue(quoted.hasPrefix("'"))
        XCTAssertTrue(quoted.hasSuffix("'"))
        XCTAssertEqual(quoted, "'/home/ferry/x; rm -rf /'")
    }

    func testShellQuoteHandlesBacktickAndDollar() {
        // Single quotes are literal in POSIX shells, so $() and `` stay inert.
        XCTAssertEqual(SCPSource.shellQuote("$(whoami)`id`"), "'$(whoami)`id`'")
    }

    // MARK: mapCommandText — stderr / scp status wording → typed errors

    func testMapNoSuchFileIsNotFound() {
        let error = SCPSource.mapCommandText("ls: /nope: No such file or directory",
                                             exitCode: 1, path: "/nope")
        XCTAssertEqual(error as? FileSystemSourceError, .notFound(path: "/nope"))
    }

    func testMapPermissionDeniedIsPermissionDenied() {
        let error = SCPSource.mapCommandText("scp: /root/secret: Permission denied",
                                             exitCode: 1, path: "/root/secret")
        XCTAssertEqual(error as? FileSystemSourceError, .permissionDenied(path: "/root/secret"))
    }

    func testMapOperationNotPermittedIsPermissionDenied() {
        let error = SCPSource.mapCommandText("mv: cannot move: Operation not permitted",
                                             exitCode: 1, path: "/x")
        XCTAssertEqual(error as? FileSystemSourceError, .permissionDenied(path: "/x"))
    }

    func testMapFileExistsIsAlreadyExists() {
        let error = SCPSource.mapCommandText("mkdir: /home/ferry/d: File exists",
                                             exitCode: 1, path: "/home/ferry/d")
        XCTAssertEqual(error as? FileSystemSourceError, .alreadyExists(path: "/home/ferry/d"))
    }

    func testMapNotADirectoryIsNotADirectory() {
        let error = SCPSource.mapCommandText("ls: /home/ferry/file/x: Not a directory",
                                             exitCode: 1, path: "/home/ferry/file/x")
        XCTAssertEqual(error as? FileSystemSourceError, .notADirectory(path: "/home/ferry/file/x"))
    }

    func testMapUnknownFallsBackToIOWithDetail() {
        let error = SCPSource.mapCommandText("disk quota exceeded", exitCode: 122, path: "/x")
        XCTAssertEqual(error as? FileSystemSourceError, .io("disk quota exceeded"))
    }

    func testMapEmptyTextReportsExitStatus() {
        let error = SCPSource.mapCommandText("   \n", exitCode: 3, path: "/x")
        XCTAssertEqual(error as? FileSystemSourceError, .io("command exited with status 3"))
    }

    // MARK: mapTransferError — path attachment for protocol errors

    func testMapTransferErrorAttachesPathToPathlessProtocolError() {
        // The scp status-message errors are produced without a path; the caller
        // attaches the file path it knows.
        let pathless = FileSystemSourceError.notFound(path: "")
        let mapped = SCPSource.mapTransferError(pathless, path: "/home/ferry/x")
        XCTAssertEqual(mapped as? FileSystemSourceError, .notFound(path: "/home/ferry/x"))
    }

    func testMapTransferErrorKeepsExistingPath() {
        let withPath = FileSystemSourceError.permissionDenied(path: "/already/here")
        let mapped = SCPSource.mapTransferError(withPath, path: "/other")
        XCTAssertEqual(mapped as? FileSystemSourceError, .permissionDenied(path: "/already/here"))
    }
}
