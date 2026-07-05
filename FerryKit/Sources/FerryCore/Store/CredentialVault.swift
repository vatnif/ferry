import Foundation
import Security

/// What kind of secret a profile owns. One Keychain item per (profile, role).
public enum CredentialRole: String, CaseIterable, Sendable {
    /// Login password (auth method .password, and FTP/FTPS).
    case password
    /// Passphrase for the private key file (auth method .publicKey).
    case keyPassphrase
}

public enum CredentialVaultError: Error, Equatable {
    /// The secret exists but its bytes are not valid UTF-8 — the item was
    /// tampered with or written by something else.
    case corruptedItem
    /// Any other Keychain failure, with the raw status for diagnostics
    /// (message via SecCopyErrorMessageString).
    case unexpectedStatus(OSStatus)
}

/// Keychain-backed secret storage — the ONLY place Ferry secrets live
/// (CLAUDE.md rule 6, DOMAIN.md → Credential policy).
///
/// Items are generic passwords: service = vault service (default
/// "com.gfragos.Ferry"), account = "<profileUUID>/<role>". Accessibility is
/// kSecAttrAccessibleWhenUnlocked. Uses the login (file-based) keychain, not
/// the data-protection keychain — see ADR-010.
public struct CredentialVault: Sendable {
    public static let defaultService = "com.gfragos.Ferry"

    public let service: String

    public init(service: String = CredentialVault.defaultService) {
        self.service = service
    }

    /// Stores or replaces the secret (upsert).
    public func store(_ secret: String, role: CredentialRole, profileID: UUID) throws {
        let account = Self.account(role: role, profileID: profileID)
        let data = Data(secret.utf8)

        var add = baseQuery(account: account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        add[kSecAttrLabel as String] = "Ferry: \(role.rawValue)"

        let status = SecItemAdd(add as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let update = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(baseQuery(account: account) as CFDictionary,
                                             update as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw CredentialVaultError.unexpectedStatus(updateStatus)
            }
        default:
            throw CredentialVaultError.unexpectedStatus(status)
        }
    }

    /// Returns the secret, or nil when none is stored (⇒ prompt at connect,
    /// DOMAIN.md).
    public func retrieve(role: CredentialRole, profileID: UUID) throws -> String? {
        var query = baseQuery(account: Self.account(role: role, profileID: profileID))
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let secret = String(data: data, encoding: .utf8) else {
                throw CredentialVaultError.corruptedItem
            }
            return secret
        case errSecItemNotFound:
            return nil
        default:
            throw CredentialVaultError.unexpectedStatus(status)
        }
    }

    /// Idempotent: deleting an absent secret is not an error.
    public func delete(role: CredentialRole, profileID: UUID) throws {
        let status = SecItemDelete(baseQuery(account: Self.account(role: role, profileID: profileID)) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialVaultError.unexpectedStatus(status)
        }
    }

    /// Removes every secret of a profile — MUST be called when a profile is
    /// deleted (DOMAIN.md).
    public func deleteAll(for profileID: UUID) throws {
        for role in CredentialRole.allCases {
            try delete(role: role, profileID: profileID)
        }
    }

    /// Stable Keychain account name. Part of the persistence contract —
    /// changing the format orphans existing user secrets.
    static func account(role: CredentialRole, profileID: UUID) -> String {
        "\(profileID.uuidString)/\(role.rawValue)"
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
