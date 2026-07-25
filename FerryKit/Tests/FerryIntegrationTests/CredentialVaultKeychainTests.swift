import XCTest
@testable import FerryCore

/// M3 integration tests against the REAL macOS Keychain.
/// Uses a test-only service name so nothing collides with app data, and
/// tears down every item it creates.
final class CredentialVaultKeychainTests: XCTestCase {
    private let vault = CredentialVault(service: "com.gfragos.Ferry.tests")
    private var profileIDs: [UUID] = []

    private func makeProfileID() -> UUID {
        let id = UUID()
        profileIDs.append(id)
        return id
    }

    override func tearDownWithError() throws {
        for id in profileIDs {
            try? vault.deleteAll(for: id)
        }
        profileIDs = []
    }

    func testStoreRetrieveRoundTrip() throws {
        let id = makeProfileID()
        try vault.store("s3cr3t-p@ss", role: .password, profileID: id)
        XCTAssertEqual(try vault.retrieve(role: .password, profileID: id), "s3cr3t-p@ss")
    }

    func testUnicodeAndLongSecretsSurvive() throws {
        let id = makeProfileID()
        let secret = "κωδικός-🔑-" + String(repeating: "x", count: 4096)
        try vault.store(secret, role: .keyPassphrase, profileID: id)
        XCTAssertEqual(try vault.retrieve(role: .keyPassphrase, profileID: id), secret)
    }

    func testStoreIsUpsert() throws {
        let id = makeProfileID()
        try vault.store("first", role: .password, profileID: id)
        try vault.store("second", role: .password, profileID: id)
        XCTAssertEqual(try vault.retrieve(role: .password, profileID: id), "second")
    }

    func testRetrieveAbsentReturnsNil() throws {
        XCTAssertNil(try vault.retrieve(role: .password, profileID: makeProfileID()))
    }

    func testRolesAndProfilesAreIsolated() throws {
        let a = makeProfileID(), b = makeProfileID()
        try vault.store("a-pass", role: .password, profileID: a)
        try vault.store("a-phrase", role: .keyPassphrase, profileID: a)
        try vault.store("b-pass", role: .password, profileID: b)

        XCTAssertEqual(try vault.retrieve(role: .password, profileID: a), "a-pass")
        XCTAssertEqual(try vault.retrieve(role: .keyPassphrase, profileID: a), "a-phrase")
        XCTAssertEqual(try vault.retrieve(role: .password, profileID: b), "b-pass")
        XCTAssertNil(try vault.retrieve(role: .keyPassphrase, profileID: b))
    }

    func testDeleteIsIdempotentAndScoped() throws {
        let id = makeProfileID()
        try vault.store("doomed", role: .password, profileID: id)
        try vault.store("kept", role: .keyPassphrase, profileID: id)

        try vault.delete(role: .password, profileID: id)
        XCTAssertNil(try vault.retrieve(role: .password, profileID: id))
        XCTAssertEqual(try vault.retrieve(role: .keyPassphrase, profileID: id), "kept")

        try vault.delete(role: .password, profileID: id) // second delete: no error
    }

    func testDeleteAllRemovesEveryRole() throws {
        let id = makeProfileID()
        try vault.store("p", role: .password, profileID: id)
        try vault.store("k", role: .keyPassphrase, profileID: id)

        try vault.deleteAll(for: id)
        XCTAssertNil(try vault.retrieve(role: .password, profileID: id))
        XCTAssertNil(try vault.retrieve(role: .keyPassphrase, profileID: id))
    }

    // MARK: Off-the-main-actor variants (ADR-034)

    func testAsyncVariantsRoundTrip() async throws {
        let id = makeProfileID()
        try await vault.storeAsync("async-p@ss", role: .password, profileID: id)
        let read = try await vault.retrieveAsync(role: .password, profileID: id)
        XCTAssertEqual(read, "async-p@ss")
    }

    func testAsyncRetrieveOfAbsentSecretReturnsNil() async throws {
        let absent = try await vault.retrieveAsync(role: .keyPassphrase, profileID: makeProfileID())
        XCTAssertNil(absent)
    }

    func testAsyncDeleteAllRemovesEveryRole() async throws {
        let id = makeProfileID()
        try await vault.storeAsync("p", role: .password, profileID: id)
        try await vault.storeAsync("k", role: .keyPassphrase, profileID: id)

        try await vault.deleteAllAsync(for: id)
        let password = try await vault.retrieveAsync(role: .password, profileID: id)
        let passphrase = try await vault.retrieveAsync(role: .keyPassphrase, profileID: id)
        XCTAssertNil(password)
        XCTAssertNil(passphrase)
    }

    /// The UI calls these from the main actor (ADR-034): they must suspend and
    /// resume there cleanly, not deadlock against their own detached work.
    @MainActor
    func testAsyncVariantsAreCallableFromTheMainActor() async throws {
        let id = makeProfileID()
        try await vault.storeAsync("off-main", role: .password, profileID: id)
        let read = try await vault.retrieveAsync(role: .password, profileID: id)
        XCTAssertEqual(read, "off-main")
        XCTAssertTrue(Thread.isMainThread, "resumes back on the main actor")
    }

    func testServicesAreIsolatedFromEachOther() throws {
        let id = makeProfileID()
        let otherVault = CredentialVault(service: "com.gfragos.Ferry.tests.other")
        defer { try? otherVault.deleteAll(for: id) }

        try vault.store("mine", role: .password, profileID: id)
        XCTAssertNil(try otherVault.retrieve(role: .password, profileID: id),
                     "a different service must not see this vault's secrets")
    }
}
