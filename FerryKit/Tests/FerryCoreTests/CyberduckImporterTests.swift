import XCTest
@testable import FerryCore

/// Exercises the Cyberduck `.duck` bookmark importer (M20 checkpoint A): field
/// mapping and provider filtering. Uses inline plist fixtures.
final class CyberduckImporterTests: XCTestCase {
    private func duck(_ pairs: [String: String]) -> Data {
        let body = pairs.map { "\t<key>\($0.key)</key>\n\t<string>\($0.value)</string>" }
            .joined(separator: "\n")
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \(body)
        </dict>
        </plist>
        """
        return Data(xml.utf8)
    }

    func testParsesSFTPBookmarkWithKey() throws {
        let data = duck([
            "Protocol": "sftp",
            "Nickname": "Prod Web",
            "Hostname": "web.example.com",
            "Port": "2222",
            "Username": "deploy",
            "Private Key File": "/Users/me/.ssh/id_prod",
        ])
        let c = try XCTUnwrap(CyberduckImporter.parse(plistData: data))
        XCTAssertEqual(c.name, "Prod Web")
        XCTAssertEqual(c.scheme, .sftp)
        XCTAssertEqual(c.host, "web.example.com")
        XCTAssertEqual(c.port, 2222)
        XCTAssertEqual(c.user, "deploy")
        XCTAssertEqual(c.identityFile, "/Users/me/.ssh/id_prod")
        XCTAssertEqual(c.folderPath, [])  // bookmarks are flat
        XCTAssertEqual(c.makeProfile().authMethod, .publicKey(privateKeyPath: "/Users/me/.ssh/id_prod"))
    }

    func testProtocolMapping() {
        XCTAssertEqual(CyberduckImporter.scheme(forProtocol: "sftp"), .sftp)
        XCTAssertEqual(CyberduckImporter.scheme(forProtocol: "ftp"), .ftp)
        XCTAssertEqual(CyberduckImporter.scheme(forProtocol: "ftps"), .ftps)
        XCTAssertEqual(CyberduckImporter.scheme(forProtocol: "ftp-ssl"), .ftps)
        XCTAssertNil(CyberduckImporter.scheme(forProtocol: "s3"))
        XCTAssertNil(CyberduckImporter.scheme(forProtocol: "dav"))
    }

    func testUnsupportedProviderReturnsNil() {
        let s3 = duck(["Protocol": "s3", "Nickname": "Bucket", "Hostname": "s3.amazonaws.com"])
        XCTAssertNil(CyberduckImporter.parse(plistData: s3))
    }

    func testMissingHostnameReturnsNil() {
        let data = duck(["Protocol": "sftp", "Nickname": "Broken"])
        XCTAssertNil(CyberduckImporter.parse(plistData: data))
    }

    func testDefaultsWhenPortAndNicknameMissing() {
        let data = duck(["Protocol": "ftp", "Hostname": "ftp.example.com"])
        let c = try! XCTUnwrap(CyberduckImporter.parse(plistData: data))
        XCTAssertEqual(c.port, 21)                  // FTP default
        XCTAssertEqual(c.name, "ftp.example.com")   // falls back to host
        XCTAssertNil(c.user)
    }

    func testFTPBookmarkGetsNoIdentityFile() {
        // A key path on a non-SSH scheme must be ignored.
        let data = duck([
            "Protocol": "ftp", "Hostname": "h", "Nickname": "N",
            "Private Key File": "/tmp/key",
        ])
        let c = try! XCTUnwrap(CyberduckImporter.parse(plistData: data))
        XCTAssertNil(c.identityFile)
        XCTAssertEqual(c.makeProfile().authMethod, .password)
    }

    func testGarbageDataReturnsNil() {
        XCTAssertNil(CyberduckImporter.parse(plistData: Data("not a plist".utf8)))
        XCTAssertNil(CyberduckImporter.parse(plistData: Data()))
    }

    func testParsesDirectorySortedByName() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cyberduck-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try duck(["Protocol": "sftp", "Nickname": "Zeta", "Hostname": "z"])
            .write(to: dir.appendingPathComponent("z.duck"))
        try duck(["Protocol": "sftp", "Nickname": "Alpha", "Hostname": "a"])
            .write(to: dir.appendingPathComponent("a.duck"))
        // A non-.duck file is ignored.
        try Data("junk".utf8).write(to: dir.appendingPathComponent("notes.txt"))

        let connections = CyberduckImporter.parse(bookmarksDirectory: dir)
        XCTAssertEqual(connections.map(\.name), ["Alpha", "Zeta"])
    }
}
