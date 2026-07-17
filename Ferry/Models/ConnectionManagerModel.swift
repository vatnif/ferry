import SwiftUI
import FerryCore

/// Main-actor state for the connection manager: owns the in-memory
/// ConnectionLibrary, persists every mutation, and mediates Keychain access.
/// Pure tree logic lives in FerryCore (tested there); this class is UI glue.
@MainActor @Observable
final class ConnectionManagerModel {
    private(set) var library = ConnectionLibrary()
    var selectedItemID: UUID?

    /// Non-nil presents the editor sheet.
    var editorContext: EditorContext?
    /// Non-nil presents the connect-time password prompt (no stored secret).
    var passwordPrompt: PasswordPrompt?
    /// Non-nil presents the key-passphrase prompt (encrypted key, no stored
    /// passphrase, or the stored/typed one was wrong).
    var keyPassphrasePrompt: KeyPassphrasePrompt?
    /// Non-nil presents the host-key trust dialog (screen 3: TOFU or changed).
    var hostKeyPrompt: HostKeyPrompt?
    /// Live connection state shown in the detail column.
    var connectionPhase: ConnectionPhase = .idle
    /// Non-nil presents the folder-name alert (create or rename).
    var folderPrompt: FolderPrompt?
    /// Non-nil presents the SSH-config import sheet (M11 checkpoint B).
    var sshImport: SSHImportContext?
    /// Non-nil presents an error alert.
    var errorMessage: String?
    /// Non-nil presents an informational alert (e.g. stubbed features).
    var infoMessage: String?
    /// Non-nil presents a neutral notice alert (e.g. import results).
    var noticeMessage: String?

    private let store: ConnectionStore
    let vault: CredentialVault
    /// Trust anchor for SSH host keys (TOFU). Same data dir as connections.json.
    let hostKeyStore: HostKeyStore

    /// The user's OpenSSH `known_hosts`, read as pre-trust so already-known
    /// hosts skip the TOFU prompt (M11 checkpoint B). Re-read at each connect so
    /// hosts the user adds via `ssh` are picked up. The Direct build reads
    /// freely; the App Store build resolves an empty file when `~/.ssh` is
    /// outside the sandbox (ADR-017) — pre-trust simply doesn't apply and TOFU
    /// behaves exactly as before.
    private var systemKnownHosts: KnownHostsFile {
        KnownHostsFile(contentsOf: Self.systemKnownHostsURL)
    }

    /// `~/.ssh/known_hosts`, overridable via `FERRY_SYSTEM_KNOWN_HOSTS` for
    /// tests (docs/TESTING.md).
    static var systemKnownHostsURL: URL {
        if let override = ProcessInfo.processInfo.environment["FERRY_SYSTEM_KNOWN_HOSTS"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/known_hosts")
    }

    struct EditorContext: Identifiable {
        var id: UUID { profileID ?? Self.newSentinel }
        /// nil ⇒ creating a new profile.
        var profileID: UUID?
        /// Preselected folder for new profiles (context-menu "New Connection Here").
        var initialFolderID: UUID?
        private static let newSentinel = UUID()
    }

    struct FolderPrompt: Identifiable {
        let id = UUID()
        /// nil ⇒ creating; set ⇒ renaming that folder.
        var renameFolderID: UUID?
        /// Parent for creation ("New Folder Here").
        var parentFolderID: UUID?
        var name: String = ""
    }

    /// Backs the SSH-config import sheet: the hosts parsed from `~/.ssh/config`.
    struct SSHImportContext: Identifiable {
        let id = UUID()
        var hosts: [ImportedSSHHost]
    }

    struct PasswordPrompt: Identifiable {
        let id = UUID()
        var profileID: UUID
        var profileName: String
    }

    struct KeyPassphrasePrompt: Identifiable {
        let id = UUID()
        var profileID: UUID
        var profileName: String
        /// The key bytes, already read — retry after the user types a
        /// passphrase without re-reading the file.
        var pem: Data
        /// True when a previous attempt's passphrase was rejected.
        var incorrect: Bool
    }

    struct HostKeyPrompt: Identifiable {
        let id = UUID()
        var profile: ConnectionProfile
        var offered: HostKeyInfo
        /// Keys Ferry already trusts for this endpoint. Empty ⇒ first contact
        /// (TOFU); non-empty ⇒ the key has CHANGED (MITM alarm).
        var stored: [HostKeyInfo]
        /// The credential to reuse on the retry after the user trusts the key.
        var credential: SSHAuthCredential
        var isChanged: Bool { !stored.isEmpty }
    }

    enum ConnectionPhase {
        case idle
        case connecting(profileName: String)
        case connected(BrowserSession)

        var session: BrowserSession? {
            if case .connected(let session) = self { return session }
            return nil
        }
        var isConnecting: Bool {
            if case .connecting = self { return true }
            return false
        }
    }

    init() {
        // UI tests and dev runs can isolate all persistence:
        // FERRY_DATA_DIR redirects connections.json, FERRY_KEYCHAIN_SERVICE
        // the Keychain service (docs/TESTING.md).
        let env = ProcessInfo.processInfo.environment
        if let dir = env["FERRY_DATA_DIR"] {
            let base = URL(fileURLWithPath: dir, isDirectory: true)
            store = ConnectionStore(fileURL: base.appendingPathComponent("connections.json"))
            hostKeyStore = HostKeyStore(fileURL: base.appendingPathComponent("known_hosts"))
        } else if let defaultStore = try? ConnectionStore.default(),
                  let defaultHostKeys = try? HostKeyStore.default() {
            store = defaultStore
            hostKeyStore = defaultHostKeys
        } else {
            let tmp = FileManager.default.temporaryDirectory
            store = ConnectionStore(fileURL: tmp.appendingPathComponent("ferry-fallback-connections.json"))
            hostKeyStore = HostKeyStore(fileURL: tmp.appendingPathComponent("ferry-fallback-known_hosts"))
        }
        vault = CredentialVault(service: env["FERRY_KEYCHAIN_SERVICE"] ?? CredentialVault.defaultService)

        do {
            library = try store.load()
        } catch {
            errorMessage = "Could not load your connections: \(error.localizedDescription)\n" +
                           "Fix or remove the file at \(store.fileURL.path), then relaunch."
        }
    }

    // MARK: Mutations (every change persists immediately)

    private func mutate(_ change: (inout ConnectionLibrary) -> Void) {
        change(&library)
        do {
            try store.save(library)
        } catch {
            errorMessage = "Could not save your connections: \(error.localizedDescription)"
        }
    }

    func setFolderExpanded(_ id: UUID, _ expanded: Bool) {
        mutate { $0.setFolderExpanded(withID: id, expanded) }
    }

    func createFolder(named name: String, in parentID: UUID?) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        mutate { $0.add(.folder(ProfileFolder(name: trimmed)), toFolder: parentID) }
    }

    func renameFolder(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        mutate { $0.renameFolder(withID: id, to: trimmed) }
    }

    /// Deletes a profile or a whole folder subtree, removing every affected
    /// profile's Keychain secrets (DOMAIN.md → Credential policy).
    func deleteItem(_ id: UUID) {
        let doomedProfiles: [ConnectionProfile]
        if let profile = library.profile(withID: id) {
            doomedProfiles = [profile]
        } else if let folder = library.folder(withID: id) {
            doomedProfiles = ConnectionLibrary(items: folder.items).allProfiles
        } else {
            return
        }
        mutate { $0.removeItem(withID: id) }
        for profile in doomedProfiles {
            do {
                try vault.deleteAll(for: profile.id)
            } catch {
                errorMessage = "The connection was deleted, but removing its stored password failed: \(error.localizedDescription)"
            }
        }
        if selectedItemID == id { selectedItemID = nil }
    }

    func duplicateProfile(_ id: UUID) {
        guard var copy = library.profile(withID: id) else { return }
        let originalID = copy.id
        copy.id = UUID()
        copy.name += " copy"
        copy.createdAt = Date()
        copy.modifiedAt = Date()
        let parent = library.parentFolderID(ofItem: originalID)
        mutate { $0.add(.profile(copy), toFolder: parent) }
        // Duplicate the secrets too, so the copy connects like the original.
        for role in CredentialRole.allCases {
            if let secret = try? vault.retrieve(role: role, profileID: originalID) {
                try? vault.store(secret, role: role, profileID: copy.id)
            }
        }
    }

    func moveItem(_ id: UUID, toFolder folderID: UUID?) {
        guard library.parentFolderID(ofItem: id) != folderID else { return }
        mutate { _ = $0.move(itemID: id, toFolder: folderID) }
    }

    // MARK: SSH config import (M11 checkpoint B)

    /// Presents the import sheet, or an info alert when there's nothing to
    /// import (no `~/.ssh/config`, or only wildcard/default blocks).
    func beginSSHConfigImport() {
        let hosts = SSHConfigParser.parse(contentsOf: Self.sshConfigURL)
        if hosts.isEmpty {
            noticeMessage = "No importable hosts were found in ~/.ssh/config."
        } else {
            sshImport = SSHImportContext(hosts: hosts)
        }
    }

    /// Imports the chosen config hosts as profiles under a fresh "Imported"
    /// folder. Secrets are never read from the config — key passphrases /
    /// passwords are prompted on first connect per the credential policy.
    func importSSHHosts(_ hosts: [ImportedSSHHost]) {
        guard !hosts.isEmpty else { return }
        let folder = ProfileFolder(name: uniqueFolderName("Imported"))
        mutate { library in
            _ = library.add(.folder(folder))
            for host in hosts {
                _ = library.add(.profile(host.makeProfile()), toFolder: folder.id)
            }
        }
        selectedItemID = folder.id
        let n = hosts.count
        noticeMessage = "Imported \(n) connection\(n == 1 ? "" : "s") into “\(folder.name)”."
    }

    /// `~/.ssh/config`, overridable via `FERRY_SSH_CONFIG` for tests.
    static var sshConfigURL: URL {
        if let override = ProcessInfo.processInfo.environment["FERRY_SSH_CONFIG"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
    }

    private func uniqueFolderName(_ base: String) -> String {
        let existing = Set(library.allFolders.map(\.name))
        guard existing.contains(base) else { return base }
        var suffix = 2
        while existing.contains("\(base) \(suffix)") { suffix += 1 }
        return "\(base) \(suffix)"
    }

    /// Saves the editor sheet. Returns false (with errorMessage set) when the
    /// tree update fails.
    func saveDraft(_ draft: ProfileDraft, existingID: UUID?) {
        let profileID: UUID
        if let existingID, var profile = library.profile(withID: existingID) {
            draft.apply(to: &profile)
            mutate { $0.updateProfile(profile) }
            if library.parentFolderID(ofItem: existingID) != draft.folderID {
                moveItem(existingID, toFolder: draft.folderID)
            }
            profileID = existingID
        } else {
            let profile = draft.buildProfile()
            mutate { $0.add(.profile(profile), toFolder: draft.folderID) }
            profileID = profile.id
            selectedItemID = profile.id
        }

        do {
            try storeSecrets(from: draft, profileID: profileID)
        } catch {
            errorMessage = "The connection was saved, but storing its secret in the Keychain failed: \(error.localizedDescription)"
        }
    }

    /// Keychain policy per auth method: only the active method's secret is
    /// kept; empty secret ⇒ item removed ⇒ prompt at connect (DOMAIN.md).
    private func storeSecrets(from draft: ProfileDraft, profileID: UUID) throws {
        switch draft.authChoice {
        case .password:
            try upsertOrDelete(draft.password, role: .password, profileID: profileID)
            try vault.delete(role: .keyPassphrase, profileID: profileID)
        case .publicKey:
            try upsertOrDelete(draft.keyPassphrase, role: .keyPassphrase, profileID: profileID)
            try vault.delete(role: .password, profileID: profileID)
        case .agent:
            try vault.deleteAll(for: profileID)
        }
    }

    private func upsertOrDelete(_ secret: String, role: CredentialRole, profileID: UUID) throws {
        if secret.isEmpty {
            try vault.delete(role: role, profileID: profileID)
        } else {
            try vault.store(secret, role: role, profileID: profileID)
        }
    }

    // MARK: Connecting (M7 password; M11 adds SSH-key auth + host-key TOFU)

    /// Entry point from the sidebar double-click and the detail Connect
    /// button. Resolves the credential (prompting when needed) and establishes
    /// the session, driving the host-key trust flow on the way.
    func connect(profileID: UUID) {
        guard let profile = library.profile(withID: profileID) else { return }
        guard profile.scheme != .scp else {
            infoMessage = "SCP connections arrive in Milestone 13."
            return
        }

        switch profile.authMethod {
        case .password:
            if let stored = (try? vault.retrieve(role: .password, profileID: profile.id)) ?? nil {
                startConnection(profile: profile, credential: .password(stored))
            } else {
                passwordPrompt = PasswordPrompt(profileID: profile.id, profileName: profile.name)
            }
        case .publicKey(let path):
            connectWithKey(profile: profile, path: path)
        case .agent:
            infoMessage = "SSH-agent authentication is planned for a later release. Edit the connection to use a key file or password for now."
        }
    }

    /// Continuation of `connect` after the user typed a password.
    func connectWithTypedPassword(_ password: String, profileID: UUID, remember: Bool) {
        guard let profile = library.profile(withID: profileID) else { return }
        if remember {
            try? vault.store(password, role: .password, profileID: profile.id)
        }
        startConnection(profile: profile, credential: .password(password))
    }

    /// Resolves an SSH-key credential: read the key file, then attempt with any
    /// stored passphrase. The connect flow prompts for a passphrase only if the
    /// key turns out to be encrypted and the stored one is missing/wrong.
    private func connectWithKey(profile: ConnectionProfile, path: String) {
        let pem: Data
        do {
            pem = try Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        } catch {
            errorMessage = "Could not read the key file at \(path). Check the path and permissions."
            return
        }
        let storedPassphrase = (try? vault.retrieve(role: .keyPassphrase, profileID: profile.id)) ?? nil
        startConnection(profile: profile,
                        credential: .privateKey(pem: pem, passphrase: storedPassphrase))
    }

    /// Continuation after the user typed a key passphrase.
    func connectWithTypedPassphrase(_ passphrase: String,
                                    prompt: KeyPassphrasePrompt, remember: Bool) {
        guard let profile = library.profile(withID: prompt.profileID) else { return }
        if remember {
            try? vault.store(passphrase, role: .keyPassphrase, profileID: profile.id)
        }
        startConnection(profile: profile,
                        credential: .privateKey(pem: prompt.pem, passphrase: passphrase))
    }

    /// The user approved an unknown host key (TOFU) — retry the connection. When
    /// `remember` is on the key is persisted to the store; otherwise it is
    /// trusted for this session only (DOMAIN.md → Host key trust).
    func trustHostKeyAndConnect(_ prompt: HostKeyPrompt, remember: Bool) {
        if remember {
            do {
                try hostKeyStore.trust(prompt.offered, host: prompt.profile.host, port: prompt.profile.port)
            } catch {
                errorMessage = "Could not save the host key: \(error.localizedDescription)"
                return
            }
            startConnection(profile: prompt.profile, credential: prompt.credential)
        } else {
            startConnection(profile: prompt.profile, credential: prompt.credential,
                            sessionTrusted: prompt.offered)
        }
    }

    /// The user chose to replace a CHANGED host key (second confirmation already
    /// given by the UI) — swap the trusted key and retry.
    func replaceHostKeyAndConnect(_ prompt: HostKeyPrompt) {
        do {
            try hostKeyStore.replace(with: prompt.offered, host: prompt.profile.host, port: prompt.profile.port)
        } catch {
            errorMessage = "Could not update the host key: \(error.localizedDescription)"
            return
        }
        startConnection(profile: prompt.profile, credential: prompt.credential)
    }

    private func startConnection(profile: ConnectionProfile, credential: SSHAuthCredential,
                                 sessionTrusted: HostKeyInfo? = nil) {
        connectionPhase = .connecting(profileName: profile.name)
        switch profile.scheme {
        case .ftp, .ftps:
            startFTPConnection(profile: profile, credential: credential)
        case .sftp, .scp:
            startSFTPConnection(profile: profile, credential: credential, sessionTrusted: sessionTrusted)
        }
    }

    private func startSFTPConnection(profile: ConnectionProfile, credential: SSHAuthCredential,
                                     sessionTrusted: HostKeyInfo?) {
        Task {
            do {
                let sftp = try await SFTPSource.connect(host: profile.host,
                                                        port: profile.port,
                                                        username: profile.username,
                                                        credential: credential,
                                                        hostKeyStore: hostKeyStore,
                                                        systemKnownHosts: systemKnownHosts,
                                                        sessionTrusted: sessionTrusted,
                                                        displayName: profile.name)
                let session = BrowserSession(profile: profile, remote: sftp, bookmarks: nil)
                await session.start()
                connectionPhase = .connected(session)
            } catch let error as RemoteSourceError {
                handleConnectError(error, profile: profile, credential: credential)
            } catch let error as SSHKeyLoadError {
                handleKeyError(error, profile: profile, credential: credential)
            } catch {
                connectionPhase = .idle
                errorMessage = "Could not connect: \(error.localizedDescription)"
            }
        }
    }

    /// FTP / FTPS connect (M12). Password auth only; TLS posture is derived
    /// from the scheme + port: `.ftps` on 990 is implicit, otherwise explicit
    /// AUTH TLS (ADR-019). Certificates are verified against the system trust
    /// store (no self-signed override in the UI yet — a cert-trust prompt is a
    /// backlog item).
    private func startFTPConnection(profile: ConnectionProfile, credential: SSHAuthCredential) {
        guard case .password(let password) = credential else {
            connectionPhase = .idle
            errorMessage = "FTP connections authenticate with a password."
            return
        }
        let security: FTPSecurity
        switch profile.scheme {
        case .ftps: security = profile.port == 990 ? .implicit : .explicit
        default: security = .none
        }
        Task {
            do {
                let ftp = try await FTPSource.connect(host: profile.host,
                                                      port: profile.port,
                                                      username: profile.username,
                                                      password: password,
                                                      security: security,
                                                      displayName: profile.name)
                let session = BrowserSession(profile: profile, remote: ftp, bookmarks: nil)
                await session.start()
                connectionPhase = .connected(session)
            } catch let error as RemoteSourceError {
                handleFTPConnectError(error, profile: profile)
            } catch {
                connectionPhase = .idle
                errorMessage = "Could not connect: \(error.localizedDescription)"
            }
        }
    }

    private func handleFTPConnectError(_ error: RemoteSourceError, profile: ConnectionProfile) {
        connectionPhase = .idle
        switch error {
        case .authenticationFailed:
            errorMessage = "The server rejected the login for \(profile.username)@\(profile.host). Check the username and password."
        case .connectionFailed(let detail):
            errorMessage = "Could not connect to \(profile.host):\(String(profile.port)) — \(detail)"
        case .tlsFailed(let detail):
            errorMessage = "The secure (TLS) connection to \(profile.host) failed: \(detail). The server's certificate may be untrusted, or the TLS mode (implicit vs. explicit) may not match the port."
        case .hostKeyUnknown, .hostKeyChanged:
            errorMessage = "Unexpected host-key error on an FTP connection."
        }
    }

    private func handleConnectError(_ error: RemoteSourceError,
                                    profile: ConnectionProfile,
                                    credential: SSHAuthCredential) {
        connectionPhase = .idle
        switch error {
        case .authenticationFailed:
            errorMessage = authFailureMessage(profile: profile, credential: credential)
        case .connectionFailed(let detail):
            errorMessage = "Could not connect to \(profile.host):\(String(profile.port)) — \(detail)"
        case .hostKeyUnknown(let offered):
            hostKeyPrompt = HostKeyPrompt(profile: profile, offered: offered,
                                          stored: [], credential: credential)
        case .hostKeyChanged(let stored, let offered):
            hostKeyPrompt = HostKeyPrompt(profile: profile, offered: offered,
                                          stored: stored, credential: credential)
        case .tlsFailed(let detail):
            // TLS is an FTPS concern; an SSH connect shouldn't produce it.
            errorMessage = "Unexpected TLS error connecting to \(profile.host): \(detail)"
        }
    }

    private func handleKeyError(_ error: SSHKeyLoadError,
                                profile: ConnectionProfile,
                                credential: SSHAuthCredential) {
        connectionPhase = .idle
        guard case .privateKey(let pem, _) = credential else {
            errorMessage = "The key could not be used: \(error.localizedDescription)"
            return
        }
        switch error {
        case .passphraseRequired:
            keyPassphrasePrompt = KeyPassphrasePrompt(profileID: profile.id,
                                                      profileName: profile.name,
                                                      pem: pem, incorrect: false)
        case .incorrectPassphrase:
            keyPassphrasePrompt = KeyPassphrasePrompt(profileID: profile.id,
                                                      profileName: profile.name,
                                                      pem: pem, incorrect: true)
        case .unsupportedKeyType(let label):
            errorMessage = "This key isn’t supported: \(label). Ferry supports OpenSSH-format ed25519 and RSA keys."
        case .malformed:
            errorMessage = "The key file for “\(profile.name)” is not a valid OpenSSH private key."
        }
    }

    private func authFailureMessage(profile: ConnectionProfile,
                                    credential: SSHAuthCredential) -> String {
        switch credential {
        case .password:
            return "The server rejected the login for \(profile.username)@\(profile.host). Check the username and password."
        case .privateKey:
            return "The server rejected the key for \(profile.username)@\(profile.host). Check that the matching public key is in the server’s authorized_keys."
        }
    }

    func disconnect() {
        guard let session = connectionPhase.session else { return }
        connectionPhase = .idle
        Task { await session.disconnect() }
    }
}
