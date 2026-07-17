import XCTest
@testable import FerryCore

/// M12 integration tests: explicit FTPS (AUTH TLS) against the TLS-enabled
/// Docker server (delfer/alpine-ftp-server on :2990, self-signed cert —
/// docs/TESTING.md). Certificate verification is off because the test cert is
/// self-signed (ADR-019); the point is that the TLS-wrapped control AND data
/// channels carry FTP correctly.
final class FTPSTests: XCTestCase {
    private static let helloContents =
        "Hello from Ferry's test fixtures.\n" +
        "This file is seeded read-only into both test servers at fixtures/hello.txt.\n"

    private var source: FTPSource!

    override func setUp() async throws {
        _ = try TestServers.requireGreeting(port: TestServers.ftpsPort, serverName: "FTPS")
        source = try await TestServers.connectFTPS()
    }

    override func tearDown() async throws {
        await source?.disconnect()
        source = nil
    }

    func testConnectAndHomeDirectoryOverTLS() async throws {
        let home = try await source.homeDirectory()
        XCTAssertEqual(home, TestServers.ftpHome)
    }

    func testListOverTLS() async throws {
        let entries = try await source.list(directory: "\(TestServers.ftpHome)/fixtures",
                                            includeHidden: false)
        let hello = try XCTUnwrap(entries.first { $0.name == "hello.txt" })
        XCTAssertEqual(hello.size, Int64(Self.helloContents.utf8.count))
    }

    func testDownloadOverTLSByteExact() async throws {
        // A multi-chunk file over the encrypted data channel, byte-exact.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("testinfra/fixtures/seed/medium-1mb.bin")
        guard let local = try? Data(contentsOf: url) else {
            throw XCTSkip("medium-1mb.bin not generated yet — run testinfra/start.sh")
        }
        var remote = Data()
        for try await chunk in try await source.openRead(
            at: "\(TestServers.ftpHome)/fixtures/medium-1mb.bin", offset: 0) {
            remote += chunk
        }
        XCTAssertEqual(remote.count, local.count)
        XCTAssertEqual(remote, local)
    }

    func testUploadDownloadRoundTripOverTLS() async throws {
        let dir = "\(TestServers.ftpHome)/ftps-\(UUID().uuidString.prefix(8))"
        try await source.createDirectory(at: dir)
        defer { let s = source!; Task { try? await s.delete(at: dir) } }

        let payload = Data((0..<200_000).map { UInt8($0 & 0xff) })
        let path = "\(dir)/tls.bin"
        let handle = try await source.openWrite(at: path, offset: 0)
        try await handle.write(payload)
        try await handle.close()

        var roundTrip = Data()
        for try await chunk in try await source.openRead(at: path, offset: 0) { roundTrip += chunk }
        XCTAssertEqual(roundTrip, payload)
    }

    func testWrongPasswordOverTLSFailsAsAuthentication() async throws {
        await XCTAssertThrowsErrorAsync(
            try await FTPSource.connect(host: TestServers.host, port: Int(TestServers.ftpsPort),
                                        username: TestServers.username, password: "definitely-wrong",
                                        security: .explicit, allowInvalidCertificate: true)) {
            XCTAssertEqual($0 as? RemoteSourceError, .authenticationFailed)
        }
    }
}
