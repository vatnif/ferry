import XCTest
@testable import FerryCore

/// Exercises the `~/.ssh/config` importer (M11 checkpoint B): which blocks
/// become profiles and how their fields map.
final class SSHConfigParserTests: XCTestCase {
    func testParsesAllFields() {
        let text = """
        Host prod-web
            HostName web.example.com
            User deploy
            Port 2222
            IdentityFile ~/.ssh/id_prod
        """
        let hosts = SSHConfigParser.parse(text)
        XCTAssertEqual(hosts.count, 1)
        let host = hosts[0]
        XCTAssertEqual(host.alias, "prod-web")
        XCTAssertEqual(host.hostName, "web.example.com")
        XCTAssertEqual(host.user, "deploy")
        XCTAssertEqual(host.port, 2222)
        XCTAssertEqual(host.endpointSummary, "deploy@web.example.com:2222")
        // Tilde expansion + public-key mapping.
        XCTAssertFalse(host.identityFile?.hasPrefix("~") ?? true)
        XCTAssertTrue(host.identityFile?.hasSuffix("/.ssh/id_prod") ?? false)
        XCTAssertEqual(host.makeProfile().authMethod,
                       .publicKey(privateKeyPath: host.identityFile!))
    }

    func testHostNameFallsBackToAliasAndDefaults() {
        let hosts = SSHConfigParser.parse("Host bare.example.com\n")
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].hostName, "bare.example.com")
        XCTAssertEqual(hosts[0].port, 22)
        XCTAssertNil(hosts[0].user)
        // No IdentityFile ⇒ password auth.
        XCTAssertEqual(hosts[0].makeProfile().authMethod, .password)
        // No `User` ⇒ profile falls back to the local login name (OpenSSH
        // semantics), never an empty username that would fail auth.
        XCTAssertEqual(hosts[0].makeProfile().username, NSUserName())
        XCTAssertFalse(hosts[0].makeProfile().username.isEmpty)
    }

    func testWildcardAndNegatedBlocksAreSkipped() {
        let text = """
        Host *
            User default-user

        Host !secret.example.com
            HostName secret.example.com

        Host web.example.com
            HostName web.example.com
        """
        let hosts = SSHConfigParser.parse(text)
        // Only the concrete block survives.
        XCTAssertEqual(hosts.map(\.alias), ["web.example.com"])
    }

    func testMultiplePatternsImportUnderFirstConcreteAlias() {
        let hosts = SSHConfigParser.parse("Host * prod\n    HostName prod.example.com\n")
        XCTAssertEqual(hosts.map(\.alias), ["prod"])
        XCTAssertEqual(hosts.first?.hostName, "prod.example.com")
    }

    func testEqualsSeparatorAndCaseInsensitiveKeywords() {
        let text = """
        HOST db
            hostname=db.example.com
            PORT=15432
        """
        let hosts = SSHConfigParser.parse(text)
        XCTAssertEqual(hosts.first?.hostName, "db.example.com")
        XCTAssertEqual(hosts.first?.port, 15432)
    }

    func testSpacesAroundEqualsSeparator() {
        let hosts = SSHConfigParser.parse("Host db\n    HostName = db.example.com\n    Port = 2200\n")
        XCTAssertEqual(hosts.first?.hostName, "db.example.com")
        XCTAssertEqual(hosts.first?.port, 2200)
    }

    func testMatchBlockEndsCurrentHost() {
        let text = """
        Host web
            HostName web.example.com

        Match host anything
            User should-not-attach

        Host db
            HostName db.example.com
        """
        let hosts = SSHConfigParser.parse(text)
        XCTAssertEqual(hosts.map(\.alias), ["web", "db"])
        // The User under Match must not leak onto either host.
        XCTAssertNil(hosts.first { $0.alias == "web" }?.user)
    }

    func testFullLineCommentsAndBlankLinesIgnored() {
        let text = """
        # my hosts

        Host web
            HostName web.example.com
        """
        let hosts = SSHConfigParser.parse(text)
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts.first?.hostName, "web.example.com")
    }

    func testEmptyConfigYieldsNothing() {
        XCTAssertTrue(SSHConfigParser.parse("").isEmpty)
        XCTAssertTrue(SSHConfigParser.parse("# just a comment\n").isEmpty)
    }
}
