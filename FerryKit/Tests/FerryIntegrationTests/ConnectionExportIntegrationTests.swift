import XCTest
@testable import FerryCore

/// M20 checkpoint B: proves a Ferry export round-trips into a working profile.
/// Builds a profile pointed at the Docker SFTP server, exports it to bytes,
/// re-imports (decode → flatten), and connects with the imported profile using a
/// separately-supplied password (secrets are never in the file). Skips cleanly
/// when the server is down.
final class ConnectionExportIntegrationTests: XCTestCase {

    func testExportImportRoundTripConnects() async throws {
        _ = try TestServers.requireGreeting(port: TestServers.sftpPort, serverName: "SFTP")

        let original = ConnectionProfile(
            name: "Ferry SFTP",
            scheme: .sftp,
            host: TestServers.host,
            port: Int(TestServers.sftpPort),
            username: TestServers.username)

        // Export a folder subtree, then re-import it.
        let tree: [SidebarItem] = [
            .folder(ProfileFolder(name: "Exported", items: [.profile(original)])),
        ]
        let data = try ConnectionExport.encode(items: tree, generator: "Ferry test")
        let decoded = try ConnectionExport.decode(data)
        let entries = ConnectionExport.flatten(decoded.items)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.folderPath, ["Exported"])

        let profile = entry.profile
        XCTAssertEqual(profile.host, TestServers.host)
        XCTAssertEqual(profile.port, Int(TestServers.sftpPort))
        XCTAssertEqual(profile.username, TestServers.username)

        let source = try await connectSFTP(profile: profile)
        defer { Task { await source.disconnect() } }
        let root = try await source.list(directory: "/", includeHidden: false)
        XCTAssertTrue(root.contains { $0.name == "upload" })
    }

    /// Connects an SFTP source from a profile, trusting the host key on first
    /// contact (shared per-run store keeps repeated connects single-handshake).
    private func connectSFTP(profile: ConnectionProfile) async throws -> SFTPSource {
        let store = TestServers.sharedHostKeyStore
        func attempt() async throws -> SFTPSource {
            do {
                return try await SFTPSource.connect(host: profile.host, port: profile.port,
                                                    username: profile.username,
                                                    credential: .password(TestServers.password),
                                                    hostKeyStore: store)
            } catch RemoteSourceError.hostKeyUnknown(let info) {
                try store.trust(info, host: profile.host, port: profile.port)
                return try await SFTPSource.connect(host: profile.host, port: profile.port,
                                                    username: profile.username,
                                                    credential: .password(TestServers.password),
                                                    hostKeyStore: store)
            }
        }
        var lastError: Error?
        for _ in 0..<10 {
            do { return try await attempt() }
            catch let error as RemoteSourceError {
                if case .connectionFailed = error {
                    lastError = error
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }
                throw error
            }
        }
        throw lastError ?? RemoteSourceError.connectionFailed("exhausted retries")
    }
}
