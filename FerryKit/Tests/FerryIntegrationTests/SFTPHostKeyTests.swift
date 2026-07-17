import XCTest
@testable import FerryCore

/// TOFU host-key verification against the real Docker sshd (M11). Uses a scratch
/// HostKeyStore per test so nothing leaks. The server's key is random per
/// container but stable for its lifetime, so we capture it from the first
/// (unknown) contact rather than pinning a fixed fingerprint.
final class SFTPHostKeyTests: XCTestCase {
    private let port = Int(TestServers.sftpPort)

    override func setUp() async throws {
        _ = try TestServers.requireGreeting(port: TestServers.sftpPort, serverName: "SFTP")
    }

    private func connect(store: HostKeyStore,
                         sessionTrusted: HostKeyInfo? = nil) async throws -> SFTPSource {
        try await SFTPSource.connect(host: TestServers.host, port: port,
                                     username: TestServers.username,
                                     credential: .password(TestServers.password),
                                     hostKeyStore: store,
                                     sessionTrusted: sessionTrusted)
    }

    func testFirstContactThrowsUnknownThenTrustSucceeds() async throws {
        let store = TestServers.scratchHostKeyStore()

        var offered: HostKeyInfo?
        do {
            _ = try await connect(store: store)
            XCTFail("expected hostKeyUnknown on first contact")
        } catch let RemoteSourceError.hostKeyUnknown(info) {
            offered = info
        }
        let info = try XCTUnwrap(offered)
        XCTAssertTrue(info.sha256.hasPrefix("SHA256:"), info.sha256)
        XCTAssertFalse(info.algorithm.isEmpty)

        // Persist the trust and reconnect — now it should go through.
        try store.trust(info, host: TestServers.host, port: port)
        let source = try await connect(store: store)
        await source.disconnect()
    }

    func testSessionOnlyTrustDoesNotPersist() async throws {
        let store = TestServers.scratchHostKeyStore()
        let offered: HostKeyInfo
        do {
            _ = try await connect(store: store)
            XCTFail("expected hostKeyUnknown")
            return
        } catch let RemoteSourceError.hostKeyUnknown(info) {
            offered = info
        }

        // Session-only trust connects without writing to the store.
        let source = try await connect(store: store, sessionTrusted: offered)
        await source.disconnect()
        XCTAssertFalse(try store.contains(host: TestServers.host, port: port),
                       "session-only trust must not be persisted")
    }

    func testChangedKeyIsDetected() async throws {
        let store = TestServers.scratchHostKeyStore()
        // Pre-trust a bogus key for this endpoint so the real one reads as CHANGED.
        let bogus = try XCTUnwrap(HostKeyInfo(openSSHLine:
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINPThizqWf0Z6Lvo9v8G5cPHYG667J3hD7XRkVP/e4k/"))
        try store.trust(bogus, host: TestServers.host, port: port)

        do {
            _ = try await connect(store: store)
            XCTFail("expected hostKeyChanged")
        } catch let RemoteSourceError.hostKeyChanged(stored, offered) {
            XCTAssertEqual(stored, [bogus])
            XCTAssertNotEqual(offered, bogus)
        }
    }
}
