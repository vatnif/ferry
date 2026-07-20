import XCTest
@testable import FerryCore

/// M20 checkpoint A: proves the FileZilla / Cyberduck / WinSCP importers produce
/// profiles that actually connect. Each test parses a fixture pointed at the
/// Docker test servers, maps it with `makeProfile()`, and connects with a
/// separately-supplied password (secrets are never imported — DOMAIN.md), then
/// lists the server root. Skips cleanly when the servers are down.
final class CompetitorImportIntegrationTests: XCTestCase {

    // MARK: FileZilla → SFTP (:2222)

    func testFileZillaImportConnectsSFTP() async throws {
        _ = try TestServers.requireGreeting(port: TestServers.sftpPort, serverName: "SFTP")
        let xml = """
        <?xml version="1.0"?>
        <FileZilla3 version="3.66.5" platform="mac">
          <Servers>
            <Folder expanded="1">Ferry Tests
              <Server>
                <Host>\(TestServers.host)</Host>
                <Port>\(TestServers.sftpPort)</Port>
                <Protocol>1</Protocol>
                <User>\(TestServers.username)</User>
                <Pass encoding="base64">bm90LXVzZWQ=</Pass>
                <Name>Ferry SFTP</Name>
              </Server>
            </Folder>
          </Servers>
        </FileZilla3>
        """
        let connections = FileZillaImporter.parse(xml)
        let connection = try XCTUnwrap(connections.first)
        XCTAssertEqual(connection.folderPath, ["Ferry Tests"])
        let profile = connection.makeProfile()
        XCTAssertEqual(profile.scheme, .sftp)
        XCTAssertEqual(profile.host, TestServers.host)
        XCTAssertEqual(profile.port, Int(TestServers.sftpPort))
        XCTAssertEqual(profile.username, TestServers.username)

        let source = try await connectSFTP(profile: profile)
        defer { Task { await source.disconnect() } }
        let root = try await source.list(directory: "/", includeHidden: false)
        XCTAssertTrue(root.contains { $0.name == "upload" })
    }

    // MARK: WinSCP → SFTP (:2222)

    func testWinSCPImportConnectsSFTP() async throws {
        _ = try TestServers.requireGreeting(port: TestServers.sftpPort, serverName: "SFTP")
        let ini = """
        [Sessions\\Ferry%20Tests/Ferry%20SFTP]
        HostName=\(TestServers.host)
        PortNumber=\(TestServers.sftpPort)
        UserName=\(TestServers.username)
        FSProtocol=1
        Password=A35Cobfuscated
        """
        let sessions = WinSCPImporter.parse(ini)
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.folderPath, ["Ferry Tests"])
        XCTAssertEqual(session.name, "Ferry SFTP")
        let profile = session.makeProfile()
        XCTAssertEqual(profile.scheme, .sftp)
        XCTAssertEqual(profile.host, TestServers.host)
        XCTAssertEqual(profile.port, Int(TestServers.sftpPort))

        let source = try await connectSFTP(profile: profile)
        defer { Task { await source.disconnect() } }
        let root = try await source.list(directory: "/", includeHidden: false)
        XCTAssertTrue(root.contains { $0.name == "upload" })
    }

    // MARK: Cyberduck → FTP (:2121)

    func testCyberduckImportConnectsFTP() async throws {
        _ = try TestServers.requireGreeting(port: TestServers.ftpPort, serverName: "FTP")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cyberduck-int-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let duck = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Protocol</key><string>ftp</string>
          <key>Nickname</key><string>Ferry FTP</string>
          <key>Hostname</key><string>\(TestServers.host)</string>
          <key>Port</key><string>\(TestServers.ftpPort)</string>
          <key>Username</key><string>\(TestServers.username)</string>
        </dict>
        </plist>
        """
        try Data(duck.utf8).write(to: dir.appendingPathComponent("ferry.duck"))

        let connections = CyberduckImporter.parse(bookmarksDirectory: dir)
        let connection = try XCTUnwrap(connections.first)
        let profile = connection.makeProfile()
        XCTAssertEqual(profile.scheme, .ftp)
        XCTAssertEqual(profile.host, TestServers.host)
        XCTAssertEqual(profile.port, Int(TestServers.ftpPort))

        let source = try await FTPSource.connect(host: profile.host, port: profile.port,
                                                 username: profile.username,
                                                 password: TestServers.password,
                                                 security: .none)
        defer { Task { await source.disconnect() } }
        let root = try await source.list(directory: TestServers.ftpHome, includeHidden: false)
        XCTAssertTrue(root.contains { $0.name == "fixtures" })
    }

    // MARK: Helpers

    /// Connects an SFTP source from a mapped profile, trusting the host key on
    /// first contact (mirrors the app's TOFU-then-connect), using the shared
    /// per-run store so repeated connects stay single-handshake.
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
