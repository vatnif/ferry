import XCTest
@testable import FerryCore

/// Pure-logic tests for CredentialVault (real-Keychain behavior is covered
/// by FerryIntegrationTests/CredentialVaultKeychainTests).
final class CredentialVaultTests: XCTestCase {
    func testAccountNameFormatIsStable() {
        // Contract: "<uuid>/<role>" — changing it orphans users' stored secrets.
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        XCTAssertEqual(CredentialVault.account(role: .password, profileID: id),
                       "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE/password")
        XCTAssertEqual(CredentialVault.account(role: .keyPassphrase, profileID: id),
                       "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE/keyPassphrase")
    }

    func testAccountNamesAreUniquePerProfileAndRole() {
        let a = UUID(), b = UUID()
        let names = [
            CredentialVault.account(role: .password, profileID: a),
            CredentialVault.account(role: .keyPassphrase, profileID: a),
            CredentialVault.account(role: .password, profileID: b),
            CredentialVault.account(role: .keyPassphrase, profileID: b),
        ]
        XCTAssertEqual(Set(names).count, names.count)
    }

    func testDefaultServiceMatchesBundleIdentifierConvention() {
        XCTAssertEqual(CredentialVault.defaultService, "com.gfragos.Ferry")
        XCTAssertEqual(CredentialVault().service, CredentialVault.defaultService)
    }
}
