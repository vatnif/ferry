import XCTest
@testable import FerryCore

/// Unit tests for the Unix `ls -l` LIST parser — the fragile seam of any FTP
/// client (ADR-019). Pinned against the dialect vsftpd/proftpd emit.
final class FTPListParserTests: XCTestCase {
    // A fixed "now" and zone so time-only dates resolve deterministically.
    private let now = Date(timeIntervalSince1970: 1_788_220_800)   // 2026-09-01 UTC
    private let utc = TimeZone(identifier: "UTC")!

    private func parse(_ listing: String, directory: String = "/home/ferry") -> [FileItem] {
        FTPListParser.parse(listing, directory: directory, now: now, timeZone: utc)
    }

    func testParsesFilesAndDirectories() {
        let listing = """
        total 12
        drwxr-xr-x    2 1001     1001         4096 Jul 18 10:00 subdir
        -rw-r--r--    1 1001     1001      1048576 Jul 18 10:00 medium-1mb.bin
        -rw-r--r--    1 1001     1001           14 Jul 18 10:00 hello.txt
        """
        let items = parse(listing)
        XCTAssertEqual(items.count, 3)

        let dir = items[0]
        XCTAssertEqual(dir.name, "subdir")
        XCTAssertTrue(dir.isDirectory)
        XCTAssertNil(dir.size)                       // directories report no size
        XCTAssertEqual(dir.path, "/home/ferry/subdir")
        XCTAssertEqual(dir.permissions?.octalString, "755")
        XCTAssertEqual(dir.owner, "1001")
        XCTAssertEqual(dir.group, "1001")

        let bin = items[1]
        XCTAssertFalse(bin.isDirectory)
        XCTAssertEqual(bin.size, 1_048_576)
        XCTAssertEqual(bin.permissions?.octalString, "644")
    }

    func testSkipsTotalHeaderAndDotEntries() {
        let listing = """
        total 4
        drwxr-xr-x    2 0 0 4096 Jul 18 10:00 .
        drwxr-xr-x    3 0 0 4096 Jul 18 10:00 ..
        -rw-r--r--    1 0 0    5 Jul 18 10:00 keep
        """
        let items = parse(listing)
        XCTAssertEqual(items.map(\.name), ["keep"])
    }

    func testSymlinkNameStripsTarget() {
        let listing = "lrwxrwxrwx    1 0        0               9 Jul 18 10:00 current -> hello.txt"
        let items = parse(listing)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].name, "current")
        XCTAssertTrue(items[0].isSymlink)
        XCTAssertFalse(items[0].isDirectory)
    }

    func testFileNameWithSpaces() {
        let listing = "-rw-r--r--    1 1001     1001           20 Jul 18 10:00 my report v2.txt"
        let items = parse(listing)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].name, "my report v2.txt")
        XCTAssertEqual(items[0].path, "/home/ferry/my report v2.txt")
    }

    func testHiddenFlagFromDotPrefix() {
        let listing = "-rw-------    1 1001     1001           10 Jul 18 10:00 .netrc"
        let items = parse(listing)
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items[0].isHidden)
        XCTAssertEqual(items[0].permissions?.octalString, "600")
    }

    func testSpecialModeBits() {
        // setuid (s in user-x), setgid (s in group-x), sticky (t in other-x).
        let listing = """
        -rwsr-xr-x    1 0 0   100 Jul 18 10:00 setuid
        drwxrwsr-x    2 0 0  4096 Jul 18 10:00 setgid
        drwxrwxrwt    2 0 0  4096 Jul 18 10:00 sticky
        """
        let items = parse(listing)
        XCTAssertEqual(items[0].permissions?.octalString, "4755")
        XCTAssertEqual(items[1].permissions?.octalString, "2775")
        XCTAssertEqual(items[2].permissions?.octalString, "1777")
    }

    func testRecentDateInfersCurrentYear() {
        let listing = "-rw-r--r--    1 0 0   1 Jul 18 10:00 f"
        let item = parse(listing).first
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: item!.modifiedAt!)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 7)
        XCTAssertEqual(components.day, 18)
        XCTAssertEqual(components.hour, 10)
        XCTAssertEqual(components.minute, 0)
    }

    func testExplicitYearDate() {
        let listing = "-rw-r--r--    1 0 0   1 Mar  1  2024 old.txt"
        let item = parse(listing).first
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let components = calendar.dateComponents([.year, .month, .day], from: item!.modifiedAt!)
        XCTAssertEqual(components.year, 2024)
        XCTAssertEqual(components.month, 3)
        XCTAssertEqual(components.day, 1)
    }

    func testFutureTimeRollsBackAYear() {
        // "Dec 31 23:59" seen from a Feb 2026 "now" must be Dec 2025.
        let listing = "-rw-r--r--    1 0 0   1 Dec 31 23:59 newyear"
        let item = parse(listing).first
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        XCTAssertEqual(calendar.component(.year, from: item!.modifiedAt!), 2025)
    }

    func testCRLFAndBlankLinesTolerated() {
        let listing = "-rw-r--r--    1 0 0   5 Jul 18 10:00 a\r\n\r\n-rw-r--r--    1 0 0   6 Jul 18 10:00 b\r\n"
        XCTAssertEqual(parse(listing).map(\.name), ["a", "b"])
    }

    func testGarbageLinesIgnored() {
        let listing = "not a listing line\n-rw-r--r--    1 0 0 5 Jul 18 10:00 ok"
        XCTAssertEqual(parse(listing).map(\.name), ["ok"])
    }

    func testDirectoryPathJoinNoDoubleSlashAtRoot() {
        let items = FTPListParser.parse("drwxr-xr-x 2 0 0 4096 Jul 18 10:00 etc",
                                        directory: "/", now: now, timeZone: utc)
        XCTAssertEqual(items.first?.path, "/etc")
    }
}
