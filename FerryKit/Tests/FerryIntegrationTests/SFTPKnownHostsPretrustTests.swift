import XCTest
@testable import FerryCore

/// The user's `~/.ssh/known_hosts` as pre-trust against the real Docker sshd
/// (M11 checkpoint B): a host already recorded there connects with no TOFU
/// prompt even though Ferry's own store is empty; a conflicting record still
/// raises the changed-key alarm.
final class SFTPKnownHostsPretrustTests: XCTestCase {
    private let port = Int(TestServers.sftpPort)

    override func setUp() async throws {
        _ = try TestServers.requireGreeting(port: TestServers.sftpPort, serverName: "SFTP")
    }

    private func connect(store: HostKeyStore,
                         systemKnownHosts: KnownHostsFile?) async throws -> SFTPSource {
        try await SFTPSource.connect(host: TestServers.host, port: port,
                                     username: TestServers.username,
                                     credential: .password(TestServers.password),
                                     hostKeyStore: store,
                                     systemKnownHosts: systemKnownHosts)
    }

    /// Capture the server's current host key via a first (unknown) contact.
    private func offeredKey(store: HostKeyStore) async throws -> HostKeyInfo {
        do {
            _ = try await connect(store: store, systemKnownHosts: nil)
            XCTFail("expected hostKeyUnknown on first contact")
        } catch let RemoteSourceError.hostKeyUnknown(info) {
            return info
        }
        throw XCTSkip("no key offered")
    }

    /// Builds a `known_hosts` view holding `info` for the test endpoint.
    private func knownHosts(with info: HostKeyInfo) -> KnownHostsFile {
        let spec = HostKeyStore.hostSpec(host: TestServers.host, port: port)
        return KnownHostsFile(text: "\(spec) \(info.openSSH)\n")
    }

    func testSystemKnownHostPreTrustConnectsWithoutPrompt() async throws {
        let store = TestServers.scratchHostKeyStore()
        let info = try await offeredKey(store: store)

        // Ferry's own store is still empty; pre-trust comes only from the
        // system known_hosts — the connect must now succeed silently.
        let source = try await connect(store: store, systemKnownHosts: knownHosts(with: info))
        await source.disconnect()
        XCTAssertFalse(try store.contains(host: TestServers.host, port: port),
                       "pre-trust must not be written into Ferry's own store")
    }

    func testSystemKnownHostWithWrongKeyIsChangedNotUnknown() async throws {
        let store = TestServers.scratchHostKeyStore()
        // A different key recorded in the "system" file for this endpoint.
        let bogus = try XCTUnwrap(HostKeyInfo(openSSHLine:
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINPThizqWf0Z6Lvo9v8G5cPHYG667J3hD7XRkVP/e4k/"))

        do {
            _ = try await connect(store: store, systemKnownHosts: knownHosts(with: bogus))
            XCTFail("expected hostKeyChanged")
        } catch let RemoteSourceError.hostKeyChanged(stored, offered) {
            XCTAssertEqual(stored, [bogus])
            XCTAssertNotEqual(offered, bogus)
        }
    }
}
