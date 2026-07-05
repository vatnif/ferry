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
    /// Live connection state shown in the detail column.
    var connectionPhase: ConnectionPhase = .idle
    /// Non-nil presents the folder-name alert (create or rename).
    var folderPrompt: FolderPrompt?
    /// Non-nil presents an error alert.
    var errorMessage: String?
    /// Non-nil presents an informational alert (e.g. stubbed features).
    var infoMessage: String?

    private let store: ConnectionStore
    let vault: CredentialVault

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

    struct PasswordPrompt: Identifiable {
        let id = UUID()
        var profileID: UUID
        var profileName: String
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
            store = ConnectionStore(fileURL: URL(fileURLWithPath: dir, isDirectory: true)
                .appendingPathComponent("connections.json"))
        } else if let defaultStore = try? ConnectionStore.default() {
            store = defaultStore
        } else {
            store = ConnectionStore(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("ferry-fallback-connections.json"))
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

    // MARK: Connecting (M7 — SFTP with password auth; key/agent land in M11)

    /// Entry point from the sidebar double-click and the detail Connect
    /// button. Resolves the secret (prompting when none is stored) and
    /// establishes the session.
    func connect(profileID: UUID) {
        guard let profile = library.profile(withID: profileID) else { return }
        guard profile.scheme == .sftp else {
            infoMessage = "\(profile.scheme.displayName) connections arrive in \(profile.scheme == .scp ? "Milestone 13" : "Milestone 12")."
            return
        }
        guard case .password = profile.authMethod else {
            infoMessage = "SSH key and agent authentication arrive in Milestone 11. Edit the connection to use password authentication for now."
            return
        }
        let stored = (try? vault.retrieve(role: .password, profileID: profile.id)) ?? nil
        if let stored {
            startConnection(profile: profile, password: stored)
        } else {
            passwordPrompt = PasswordPrompt(profileID: profile.id, profileName: profile.name)
        }
    }

    /// Continuation of `connect` after the user typed a password.
    func connectWithTypedPassword(_ password: String, profileID: UUID, remember: Bool) {
        guard let profile = library.profile(withID: profileID) else { return }
        if remember {
            try? vault.store(password, role: .password, profileID: profile.id)
        }
        startConnection(profile: profile, password: password)
    }

    private func startConnection(profile: ConnectionProfile, password: String) {
        connectionPhase = .connecting(profileName: profile.name)
        Task {
            do {
                let sftp = try await SFTPSource.connect(host: profile.host,
                                                        port: profile.port,
                                                        username: profile.username,
                                                        password: password,
                                                        displayName: profile.name)
                let session = BrowserSession(profile: profile, sftp: sftp, bookmarks: nil)
                await session.start()
                connectionPhase = .connected(session)
            } catch let error as RemoteSourceError {
                connectionPhase = .idle
                switch error {
                case .authenticationFailed:
                    errorMessage = "The server rejected the login for \(profile.username)@\(profile.host). Check the username and password."
                case .connectionFailed(let detail):
                    errorMessage = "Could not connect to \(profile.host):\(String(profile.port)) — \(detail)"
                }
            } catch {
                connectionPhase = .idle
                errorMessage = "Could not connect: \(error.localizedDescription)"
            }
        }
    }

    func disconnect() {
        guard let session = connectionPhase.session else { return }
        connectionPhase = .idle
        Task { await session.disconnect() }
    }
}
