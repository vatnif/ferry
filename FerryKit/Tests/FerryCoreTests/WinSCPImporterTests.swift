import XCTest
@testable import FerryCore

/// Exercises the WinSCP `WinSCP.ini` importer (M20 checkpoint A): session field
/// mapping, protocol/TLS mapping, percent-decoded folder hierarchy, and secret
/// suppression (rule 6).
final class WinSCPImporterTests: XCTestCase {
    func testParsesSFTPSessionWithKey() {
        let ini = """
        [Configuration\\Interface]
        CopyParamAutoSelectNotice=0

        [Sessions\\Prod%20Web]
        HostName=web.example.com
        PortNumber=2222
        UserName=deploy
        FSProtocol=1
        PublicKeyFile=C:\\Users\\me\\key.ppk
        Password=A35C88...obfuscated
        """
        let sessions = WinSCPImporter.parse(ini)
        XCTAssertEqual(sessions.count, 1)
        let s = sessions[0]
        XCTAssertEqual(s.name, "Prod Web")
        XCTAssertEqual(s.scheme, .sftp)
        XCTAssertEqual(s.host, "web.example.com")
        XCTAssertEqual(s.port, 2222)
        XCTAssertEqual(s.user, "deploy")
        XCTAssertEqual(s.identityFile, "C:\\Users\\me\\key.ppk")
        XCTAssertEqual(s.folderPath, [])
    }

    func testPasswordIsNeverSurfaced() {
        let ini = """
        [Sessions\\S]
        HostName=h
        FSProtocol=1
        Password=A35C88DEADBEEF
        """
        let s = WinSCPImporter.parse(ini)[0]
        // No key ⇒ password auth, and nothing secret rides along on the profile.
        XCTAssertEqual(s.makeProfile().authMethod, .password)
        XCTAssertNil(s.identityFile)
    }

    func testProtocolAndTLSMapping() {
        XCTAssertEqual(WinSCPImporter.scheme(fsProtocol: 0, ftps: nil), .scp)
        XCTAssertEqual(WinSCPImporter.scheme(fsProtocol: 1, ftps: nil), .sftp)
        XCTAssertEqual(WinSCPImporter.scheme(fsProtocol: 2, ftps: nil), .sftp)
        XCTAssertEqual(WinSCPImporter.scheme(fsProtocol: 5, ftps: 0), .ftp)
        XCTAssertEqual(WinSCPImporter.scheme(fsProtocol: 5, ftps: 1), .ftps) // implicit
        XCTAssertEqual(WinSCPImporter.scheme(fsProtocol: 5, ftps: 3), .ftps) // explicit
        XCTAssertEqual(WinSCPImporter.scheme(fsProtocol: nil, ftps: nil), .sftp) // default
        XCTAssertNil(WinSCPImporter.scheme(fsProtocol: 6, ftps: nil))  // WebDAV
        XCTAssertNil(WinSCPImporter.scheme(fsProtocol: 7, ftps: nil))  // S3
    }

    func testUnsupportedProtocolSessionIsSkipped() {
        let ini = """
        [Sessions\\Dav]
        HostName=dav.example.com
        FSProtocol=6

        [Sessions\\Files]
        HostName=sftp.example.com
        FSProtocol=1
        """
        XCTAssertEqual(WinSCPImporter.parse(ini).map(\.host), ["sftp.example.com"])
    }

    func testFolderHierarchyFromEncodedSessionName() {
        let ini = """
        [Sessions\\Clients/Europe/Acme%20GmbH]
        HostName=acme.example.com
        FSProtocol=1
        """
        let s = WinSCPImporter.parse(ini)[0]
        XCTAssertEqual(s.folderPath, ["Clients", "Europe"])
        XCTAssertEqual(s.name, "Acme GmbH")
    }

    func testDecodePathHandlesEscapedSlashInName() {
        // %2F inside a component is a literal slash, not a separator.
        let decoded = WinSCPImporter.decodePath("Team/a%2Fb")
        XCTAssertEqual(decoded?.folderPath, ["Team"])
        XCTAssertEqual(decoded?.name, "a/b")
    }

    func testDefaultSettingsTemplateIsSkipped() {
        let ini = """
        [Sessions\\Default%20Settings]
        FSProtocol=1

        [Sessions\\Real]
        HostName=real.example.com
        FSProtocol=1
        """
        XCTAssertEqual(WinSCPImporter.parse(ini).map(\.name), ["Real"])
    }

    func testSessionWithoutHostIsSkipped() {
        let ini = """
        [Sessions\\Empty]
        FSProtocol=1
        UserName=u
        """
        XCTAssertTrue(WinSCPImporter.parse(ini).isEmpty)
    }

    func testFTPSessionGetsNoIdentityFile() {
        let ini = """
        [Sessions\\S]
        HostName=h
        FSProtocol=5
        PublicKeyFile=C:\\key.ppk
        """
        let s = WinSCPImporter.parse(ini)[0]
        XCTAssertEqual(s.scheme, .ftp)
        XCTAssertNil(s.identityFile)
    }

    func testEmptyInput() {
        XCTAssertTrue(WinSCPImporter.parse("").isEmpty)
        XCTAssertTrue(WinSCPImporter.parse("[Configuration\\Foo]\nBar=1").isEmpty)
    }
}
