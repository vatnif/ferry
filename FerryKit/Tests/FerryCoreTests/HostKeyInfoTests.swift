import XCTest
@testable import FerryCore

/// Vectors are real keys produced by `ssh-keygen`; the SHA256 fingerprints are
/// exactly what `ssh-keygen -lf` reports for them, so this pins Ferry's
/// fingerprint math to OpenSSH's.
final class HostKeyInfoTests: XCTestCase {
    // ssh-keygen -t ed25519 ; ssh-keygen -lf key.pub
    private let ed25519Line =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINPThizqWf0Z6Lvo9v8G5cPHYG667J3hD7XRkVP/e4k/ ferry-test"
    private let ed25519SHA256 = "SHA256:DtssY9xVYOU71AmcKfdqhByuOFqtYIcU9DdDTwukNgk"

    // ssh-keygen -t rsa -b 2048
    private let rsaLine =
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCr0tPPLjuXyrOAq9uSW8vzi+x+GNBRe7o9JF7YxNJncOejxCue9CVDUsMNgAknoIcRRdde7XAc4a8KfQ7TXqd5KzEacpU8W/DJHMea4RqYwPvpLs42gxMdPKac9UJEncAuZWky0q+YHTzWXDl7AxlarM8welsijEDfao2SX2MMjAybN1M9NCcLIYfefT/lcPWLw5elbz9QZtHCLXCUzf8JRopKKJ6NnuiSWj/4dnEzZgS13nxv+7/9OE9CznOyKXxxs0iAKJGVMSxozDPEsdGYBVCwY6JkJc7TVDQWx9n/DIZ3BlZAtTBcZ8yBYRlX+xpHJHKHNbboJ/0kCYBe7PR/ ferry-test"
    private let rsaSHA256 = "SHA256:BV9D+vu543uMXyNP/QkYQS8lMGGT/53fwEeZ1ZtWyWI"

    func testEd25519Fingerprint() throws {
        let info = try XCTUnwrap(HostKeyInfo(openSSHLine: ed25519Line))
        XCTAssertEqual(info.algorithm, "ED25519")
        XCTAssertEqual(info.keyType, "ssh-ed25519")
        XCTAssertEqual(info.sha256, ed25519SHA256)
        // Comment is stripped; only "<type> <base64>" is retained for storage.
        XCTAssertEqual(info.openSSH,
                       "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINPThizqWf0Z6Lvo9v8G5cPHYG667J3hD7XRkVP/e4k/")
        XCTAssertEqual(info.displayFingerprint, "ED25519 · \(ed25519SHA256)")
    }

    func testRSAFingerprint() throws {
        let info = try XCTUnwrap(HostKeyInfo(openSSHLine: rsaLine))
        XCTAssertEqual(info.algorithm, "RSA")
        XCTAssertEqual(info.sha256, rsaSHA256)
    }

    func testECDSALabel() throws {
        // Only the type field matters for the label; the (bogus) blob still
        // base64-decodes.
        let line = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTY="
        let info = try XCTUnwrap(HostKeyInfo(openSSHLine: line))
        XCTAssertEqual(info.algorithm, "ECDSA")
    }

    func testInvalidLinesReturnNil() {
        XCTAssertNil(HostKeyInfo(openSSHLine: "ssh-ed25519"))          // missing blob
        XCTAssertNil(HostKeyInfo(openSSHLine: "ssh-ed25519 !!!notbase64!!!"))
        XCTAssertNil(HostKeyInfo(openSSHLine: ""))
    }
}
