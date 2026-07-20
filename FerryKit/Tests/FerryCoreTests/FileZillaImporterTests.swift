import XCTest
@testable import FerryCore

/// Exercises the FileZilla `sitemanager.xml` importer (M20 checkpoint A): which
/// `<Server>` blocks become connections, how their fields map, and how the
/// folder hierarchy is preserved. No secrets are surfaced (rule 6).
final class FileZillaImporterTests: XCTestCase {
    func testParsesAllFieldsForSFTPKeySite() {
        let xml = """
        <?xml version="1.0"?>
        <FileZilla3 version="3.66.5" platform="mac">
          <Servers>
            <Server>
              <Host>web.example.com</Host>
              <Port>2222</Port>
              <Protocol>1</Protocol>
              <Type>0</Type>
              <User>deploy</User>
              <Pass encoding="base64">c3VwZXJzZWNyZXQ=</Pass>
              <Logontype>5</Logontype>
              <KeyFile>/Users/me/.ssh/id_prod</KeyFile>
              <Name>Prod Web</Name>
            </Server>
          </Servers>
        </FileZilla3>
        """
        let connections = FileZillaImporter.parse(xml)
        XCTAssertEqual(connections.count, 1)
        let c = connections[0]
        XCTAssertEqual(c.name, "Prod Web")
        XCTAssertEqual(c.scheme, .sftp)
        XCTAssertEqual(c.host, "web.example.com")
        XCTAssertEqual(c.port, 2222)
        XCTAssertEqual(c.user, "deploy")
        XCTAssertEqual(c.identityFile, "/Users/me/.ssh/id_prod")
        XCTAssertEqual(c.folderPath, [])
        XCTAssertEqual(c.makeProfile().authMethod, .publicKey(privateKeyPath: "/Users/me/.ssh/id_prod"))
    }

    func testSecretIsNeverSurfaced() {
        let xml = """
        <FileZilla3><Servers><Server>
          <Host>h</Host><Protocol>1</Protocol>
          <Pass encoding="base64">c3VwZXJzZWNyZXQ=</Pass>
          <Name>S</Name>
        </Server></Servers></FileZilla3>
        """
        let c = FileZillaImporter.parse(xml)[0]
        // Password auth (no key), and the profile carries no secret material.
        XCTAssertEqual(c.makeProfile().authMethod, .password)
        XCTAssertNil(c.identityFile)
    }

    func testProtocolMapping() {
        XCTAssertEqual(FileZillaImporter.scheme(forProtocol: 0), .ftp)
        XCTAssertEqual(FileZillaImporter.scheme(forProtocol: 1), .sftp)
        XCTAssertEqual(FileZillaImporter.scheme(forProtocol: 3), .ftps)
        XCTAssertEqual(FileZillaImporter.scheme(forProtocol: 4), .ftps)
        XCTAssertNil(FileZillaImporter.scheme(forProtocol: 2))   // HTTP
        XCTAssertNil(FileZillaImporter.scheme(forProtocol: 99))  // S3/other
    }

    func testUnsupportedProtocolSiteIsSkipped() {
        let xml = """
        <FileZilla3><Servers>
          <Server><Host>http.example.com</Host><Protocol>2</Protocol><Name>Web</Name></Server>
          <Server><Host>sftp.example.com</Host><Protocol>1</Protocol><Name>Files</Name></Server>
        </Servers></FileZilla3>
        """
        let connections = FileZillaImporter.parse(xml)
        XCTAssertEqual(connections.map(\.host), ["sftp.example.com"])
    }

    func testAnonymousLogonMapsUser() {
        let xml = """
        <FileZilla3><Servers><Server>
          <Host>ftp.example.com</Host><Protocol>0</Protocol>
          <Logontype>0</Logontype><Name>Public FTP</Name>
        </Server></Servers></FileZilla3>
        """
        let c = FileZillaImporter.parse(xml)[0]
        XCTAssertEqual(c.scheme, .ftp)
        XCTAssertEqual(c.user, "anonymous")
    }

    func testDefaultsWhenPortAndNameMissing() {
        let xml = """
        <FileZilla3><Servers><Server>
          <Host>bare.example.com</Host><Protocol>1</Protocol><User>u</User>
        </Server></Servers></FileZilla3>
        """
        let c = FileZillaImporter.parse(xml)[0]
        XCTAssertEqual(c.port, 22)          // SFTP default
        XCTAssertEqual(c.name, "bare.example.com")  // falls back to host
    }

    func testFolderHierarchyIsPreserved() {
        let xml = """
        <FileZilla3>
          <Servers>
            <Server><Host>top.example.com</Host><Protocol>1</Protocol><Name>Top</Name></Server>
            <Folder expanded="1">Clients
              <Server><Host>acme.example.com</Host><Protocol>1</Protocol><Name>Acme</Name></Server>
              <Folder expanded="0">Europe
                <Server><Host>eu.example.com</Host><Protocol>1</Protocol><Name>EU</Name></Server>
              </Folder>
            </Folder>
          </Servers>
        </FileZilla3>
        """
        let connections = FileZillaImporter.parse(xml)
        let byName = Dictionary(uniqueKeysWithValues: connections.map { ($0.name, $0) })
        XCTAssertEqual(byName["Top"]?.folderPath, [])
        XCTAssertEqual(byName["Acme"]?.folderPath, ["Clients"])
        XCTAssertEqual(byName["EU"]?.folderPath, ["Clients", "Europe"])
    }

    func testEmptyAndGarbageInput() {
        XCTAssertTrue(FileZillaImporter.parse("").isEmpty)
        XCTAssertTrue(FileZillaImporter.parse("not xml at all <<< >>>").isEmpty)
        XCTAssertTrue(FileZillaImporter.parse("<FileZilla3><Servers></Servers></FileZilla3>").isEmpty)
    }
}
