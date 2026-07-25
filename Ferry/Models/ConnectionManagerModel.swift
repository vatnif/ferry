import SwiftUI
import UniformTypeIdentifiers
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
    /// Non-nil presents the FTPS certificate trust dialog (cert TOFU or changed,
    /// ADR-033) — the TLS analog of `hostKeyPrompt`.
    var certificatePrompt: CertificatePrompt?
    /// The open connection tabs (DESIGN.md screen 1 tab strip, M16 checkpoint B
    /// / ADR-027). Each tab holds its own `ConnectionPhase`; the selected tab
    /// drives the detail column. The window always keeps at least one tab (the
    /// initial one is empty). Phase transitions persist the connected tabs'
    /// profile IDs for Settings ▸ General "Reopen last connections".
    var tabs = OrderedTabs<ConnectionTab>(tabs: [ConnectionTab()])
    /// The tab currently shown in the detail column.
    var selectedTab: ConnectionTab? { tabs.selected }
    /// Non-nil presents the "close a tab that still has running transfers?"
    /// confirmation (ADR-027 — not in the mockups, signed off 2026-07-19).
    var pendingTabClose: UUID?
    /// Guards one-shot restore-on-launch.
    private var didAttemptRestore = false
    /// Non-nil presents the folder-name alert (create or rename).
    var folderPrompt: FolderPrompt?
    /// Non-nil presents the SSH-config import sheet (M11 checkpoint B).
    var sshImport: SSHImportContext?
    /// Non-nil presents the competitor-import sheet (FileZilla/Cyberduck/WinSCP,
    /// M20 checkpoint A).
    var profileImport: ProfileImportContext?
    /// Non-nil presents the Ferry-export import sheet (M20 checkpoint B).
    var ferryImport: FerryImportContext?
    /// Non-nil presents an error alert.
    var errorMessage: String?
    /// Non-nil presents an informational alert (e.g. stubbed features).
    var infoMessage: String?
    /// Non-nil presents a neutral notice alert (e.g. import results).
    var noticeMessage: String?

    /// Terminal windows (pop-out + terminal-only, screen 7), keyed by
    /// controller id. Type-erased so this macOS-14 class can hold the
    /// macOS-15-only `TerminalController`s; use the gated accessors.
    private var terminalWindowStorage: [UUID: Any] = [:]
    /// Set to ask the UI to open the terminal window scene for this
    /// controller (models can't call `openWindow`; MainWindow observes this).
    var pendingTerminalWindowID: UUID?

    @available(macOS 15.0, *)
    func terminalWindow(_ id: UUID) -> TerminalController? {
        terminalWindowStorage[id] as? TerminalController
    }

    @available(macOS 15.0, *)
    func registerTerminalWindow(_ controller: TerminalController) {
        terminalWindowStorage[controller.id] = controller
    }

    func removeTerminalWindow(_ id: UUID) {
        terminalWindowStorage.removeValue(forKey: id)
    }

    private let store: ConnectionStore
    let vault: CredentialVault
    /// Trust anchor for SSH host keys (TOFU). Same data dir as connections.json.
    let hostKeyStore: HostKeyStore
    /// Trust anchor for pinned FTPS certificates (cert TOFU, ADR-033). Same data
    /// dir as connections.json / known_hosts.
    let certificateTrustStore: CertificateTrustStore

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

    /// Backs the competitor-import sheet (M20 checkpoint A): the connections
    /// parsed from a FileZilla/Cyberduck/WinSCP export, plus a human-readable
    /// source label used for the sheet title and the destination folder name.
    struct ProfileImportContext: Identifiable {
        let id = UUID()
        var sourceName: String
        var connections: [ImportedConnection]
    }

    /// Backs the Ferry-export import sheet (M20 checkpoint B): the connections
    /// flattened from a chosen `.json` export.
    struct FerryImportContext: Identifiable {
        let id = UUID()
        var entries: [ImportEntry]
    }

    /// What a resolved credential opens: the browser session, or a
    /// terminal-only window (screen 7 note 4, ADR-023). Carried through the
    /// password/passphrase/host-key prompts so their continuations land on
    /// the right path.
    enum ConnectIntent {
        case browser
        case terminal
    }

    struct PasswordPrompt: Identifiable {
        let id = UUID()
        var profileID: UUID
        var profileName: String
        var intent: ConnectIntent = .browser
        /// The tab the browser connect targets (nil for `.terminal`). Resolved
        /// back to a live tab on the continuation; if the tab was closed
        /// meanwhile the connect is abandoned.
        var tabID: UUID?
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
        var intent: ConnectIntent = .browser
        var tabID: UUID?
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
        var intent: ConnectIntent = .browser
        var tabID: UUID?
        var isChanged: Bool { !stored.isEmpty }
    }

    /// Presents the FTPS certificate-trust dialog (ADR-033) — the TLS analog of
    /// `HostKeyPrompt`. Carries everything needed to re-drive the FTP connect
    /// once the user trusts (or replaces) the certificate.
    struct CertificatePrompt: Identifiable {
        let id = UUID()
        var profile: ConnectionProfile
        /// The certificate the server offered.
        var offered: CertificateInfo
        /// The certificate Ferry already pinned for this endpoint. Empty ⇒ first
        /// contact (TOFU); non-empty ⇒ the certificate has CHANGED.
        var stored: [CertificateInfo]
        /// The password to reuse on the retry (FTP is password-only).
        var password: String
        var tabID: UUID?
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
            certificateTrustStore = CertificateTrustStore(fileURL: base.appendingPathComponent("trusted_certs.json"))
        } else if let defaultStore = try? ConnectionStore.default(),
                  let defaultHostKeys = try? HostKeyStore.default(),
                  let defaultCerts = try? CertificateTrustStore.default() {
            store = defaultStore
            hostKeyStore = defaultHostKeys
            certificateTrustStore = defaultCerts
        } else {
            let tmp = FileManager.default.temporaryDirectory
            store = ConnectionStore(fileURL: tmp.appendingPathComponent("ferry-fallback-connections.json"))
            hostKeyStore = HostKeyStore(fileURL: tmp.appendingPathComponent("ferry-fallback-known_hosts"))
            certificateTrustStore = CertificateTrustStore(fileURL: tmp.appendingPathComponent("ferry-fallback-trusted_certs.json"))
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
        let vault = vault
        Task {
            for profile in doomedProfiles {
                do {
                    try await vault.deleteAllAsync(for: profile.id)
                } catch {
                    errorMessage = "The connection was deleted, but removing its stored password failed: \(Self.describe(error))"
                }
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
        let vault = vault
        let newID = copy.id
        Task.detached(priority: .userInitiated) {
            for role in CredentialRole.allCases {
                if let secret = try? vault.retrieve(role: role, profileID: originalID) {
                    try? vault.store(secret, role: role, profileID: newID)
                }
            }
        }
    }

    func moveItem(_ id: UUID, toFolder folderID: UUID?) {
        guard library.parentFolderID(ofItem: id) != folderID else { return }
        mutate { _ = $0.move(itemID: id, toFolder: folderID) }
    }

    /// Within-folder (and cross-folder positioned) drag reorder — deferred from
    /// M4 to M16 (DESIGN.md). Drops `draggedID` immediately before `targetID`,
    /// landing it in `targetID`'s parent at `targetID`'s slot. The library's
    /// `move` removes then inserts, so a same-parent drag from above the target
    /// must insert one slot lower to end up before it.
    func reorderItem(_ draggedID: UUID, before targetID: UUID) {
        guard draggedID != targetID else { return }
        let parent = library.parentFolderID(ofItem: targetID)
        let siblings = childItems(inFolder: parent)
        guard let targetIndex = siblings.firstIndex(where: { $0.id == targetID }) else { return }
        var index = targetIndex
        if library.parentFolderID(ofItem: draggedID) == parent,
           let fromIndex = siblings.firstIndex(where: { $0.id == draggedID }),
           fromIndex < targetIndex {
            index = targetIndex - 1
        }
        mutate { _ = $0.move(itemID: draggedID, toFolder: parent, at: index) }
    }

    /// The sidebar items directly inside `folder` (nil = root).
    private func childItems(inFolder folder: UUID?) -> [SidebarItem] {
        if let folder { return library.folder(withID: folder)?.items ?? [] }
        return library.items
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

    // MARK: Competitor imports (M20 checkpoint A — FileZilla / Cyberduck / WinSCP)

    /// FileZilla Site Manager import. Reads a chosen `sitemanager.xml` (default
    /// `~/.config/filezilla/sitemanager.xml`); `FERRY_FILEZILLA_SITEMANAGER`
    /// bypasses the picker for tests.
    func beginFileZillaImport() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fallback = home.appendingPathComponent(".config/filezilla/sitemanager.xml")
        guard let url = resolveImportURL(env: "FERRY_FILEZILLA_SITEMANAGER",
                                         defaultURL: fallback,
                                         chooseDirectory: false,
                                         allowedExtensions: ["xml"],
                                         prompt: "Import") else { return }
        presentImport(FileZillaImporter.parse(contentsOf: url), sourceName: "FileZilla")
    }

    /// Cyberduck bookmarks import. Reads every `.duck` in a chosen Bookmarks
    /// folder (default `~/Library/Application Support/Cyberduck/Bookmarks/`);
    /// `FERRY_CYBERDUCK_BOOKMARKS` bypasses the picker for tests.
    func beginCyberduckImport() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fallback = home.appendingPathComponent("Library/Application Support/Cyberduck/Bookmarks", isDirectory: true)
        guard let url = resolveImportURL(env: "FERRY_CYBERDUCK_BOOKMARKS",
                                         defaultURL: fallback,
                                         chooseDirectory: true,
                                         allowedExtensions: nil,
                                         prompt: "Choose") else { return }
        presentImport(CyberduckImporter.parse(bookmarksDirectory: url), sourceName: "Cyberduck")
    }

    /// WinSCP import. Reads a chosen exported `WinSCP.ini` (WinSCP is
    /// Windows-only, so there is no macOS default location);
    /// `FERRY_WINSCP_INI` bypasses the picker for tests.
    func beginWinSCPImport() {
        let fallback = FileManager.default.homeDirectoryForCurrentUser
        guard let url = resolveImportURL(env: "FERRY_WINSCP_INI",
                                         defaultURL: fallback,
                                         chooseDirectory: false,
                                         allowedExtensions: ["ini"],
                                         prompt: "Import") else { return }
        presentImport(WinSCPImporter.parse(contentsOf: url), sourceName: "WinSCP")
    }

    /// Shows the import checklist, or a notice when nothing importable was found.
    private func presentImport(_ connections: [ImportedConnection], sourceName: String) {
        if connections.isEmpty {
            noticeMessage = "No importable connections were found in the \(sourceName) file."
        } else {
            profileImport = ProfileImportContext(sourceName: sourceName, connections: connections)
        }
    }

    /// Resolves the source URL: the env override wins (tests); otherwise an
    /// `NSOpenPanel` lets the user pick the file/folder. Returns nil if cancelled.
    private func resolveImportURL(env: String, defaultURL: URL, chooseDirectory: Bool,
                                  allowedExtensions: [String]?, prompt: String) -> URL? {
        if let override = ProcessInfo.processInfo.environment[env] {
            return URL(fileURLWithPath: override)
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = chooseDirectory
        panel.canChooseFiles = !chooseDirectory
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        if let allowedExtensions {
            panel.allowedContentTypes = allowedExtensions.compactMap { UTType(filenameExtension: $0) }
        }
        panel.directoryURL = defaultURL
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Imports the chosen connections into a fresh, uniquely-named folder,
    /// rebuilding each connection's source folder hierarchy as nested subfolders
    /// (only the folders the selection needs). Secrets are never read from the
    /// source — passwords/passphrases are prompted on first connect.
    func importConnections(_ connections: [ImportedConnection], sourceName: String) {
        let entries = connections.map { ImportEntry(profile: $0.makeProfile(), folderPath: $0.folderPath) }
        importEntries(entries, folderBaseName: "\(sourceName) Import", noticeSuffix: " from \(sourceName)")
    }

    /// Shared import: adds `entries` under a fresh, uniquely-named folder with
    /// their folder hierarchy rebuilt and fresh ids (collision-safe — see
    /// `ConnectionLibrary.addImported`). Used by the competitor importers and the
    /// Ferry-export importer.
    private func importEntries(_ entries: [ImportEntry], folderBaseName: String, noticeSuffix: String) {
        guard !entries.isEmpty else { return }
        let rootName = uniqueFolderName(folderBaseName)
        var rootID: UUID?
        mutate { rootID = $0.addImported(entries, intoFolderNamed: rootName) }
        selectedItemID = rootID
        let n = entries.count
        noticeMessage = "Imported \(n) connection\(n == 1 ? "" : "s")\(noticeSuffix) into “\(rootName)”."
    }

    private func uniqueFolderName(_ base: String) -> String {
        let existing = Set(library.allFolders.map(\.name))
        guard existing.contains(base) else { return base }
        var suffix = 2
        while existing.contains("\(base) \(suffix)") { suffix += 1 }
        return "\(base) \(suffix)"
    }

    // MARK: Ferry-format export / import (M20 checkpoint B — ADR-032)

    /// Exports a single sidebar item (a profile, or a whole folder subtree) to a
    /// chosen `.json` file. Secret-free by construction (rule 6).
    func exportItem(_ id: UUID) {
        guard let item = library.item(withID: id) else { return }
        presentExport([item], suggestedName: item.name)
    }

    /// Exports the entire connection library.
    func exportAll() {
        presentExport(library.items, suggestedName: "Ferry Connections")
    }

    /// Encodes the items and writes them to a user-chosen file
    /// (`FERRY_EXPORT_PATH` bypasses the save panel for tests).
    private func presentExport(_ items: [SidebarItem], suggestedName: String) {
        let data: Data
        do {
            data = try ConnectionExport.encode(items: items, generator: "Ferry \(FerryVersion.current)")
        } catch {
            errorMessage = "Could not prepare the export: \(error.localizedDescription)"
            return
        }
        let url: URL
        if let override = ProcessInfo.processInfo.environment["FERRY_EXPORT_PATH"] {
            url = URL(fileURLWithPath: override)
        } else {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "\(suggestedName).json"
            panel.prompt = "Export"
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            url = chosen
        }
        do {
            try data.write(to: url, options: .atomic)
            let n = ConnectionExport.flatten(items).count
            noticeMessage = "Exported \(n) connection\(n == 1 ? "" : "s") to “\(url.lastPathComponent)”. "
                          + "The file contains no passwords."
        } catch {
            errorMessage = "Could not write the export: \(error.localizedDescription)"
        }
    }

    /// Ferry-export import. Reads a chosen `.json` export
    /// (`FERRY_IMPORT_PATH` bypasses the picker for tests).
    func beginFerryImport() {
        guard let url = resolveImportURL(env: "FERRY_IMPORT_PATH",
                                         defaultURL: FileManager.default.homeDirectoryForCurrentUser,
                                         chooseDirectory: false,
                                         allowedExtensions: ["json"],
                                         prompt: "Import") else { return }
        let export: ConnectionExport
        do {
            export = try ConnectionExport.decode(try Data(contentsOf: url))
        } catch let error as ConnectionExportError {
            errorMessage = Self.message(for: error)
            return
        } catch {
            errorMessage = "Could not read that file: \(error.localizedDescription)"
            return
        }
        let entries = ConnectionExport.flatten(export.items)
        if entries.isEmpty {
            noticeMessage = "That Ferry export contains no connections."
        } else {
            ferryImport = FerryImportContext(entries: entries)
        }
    }

    /// Imports the chosen entries from a Ferry export into a fresh "Imported"
    /// folder (structure rebuilt, fresh ids — never clobbers existing items).
    func importFerryEntries(_ entries: [ImportEntry]) {
        importEntries(entries, folderBaseName: "Imported", noticeSuffix: "")
    }

    private static func message(for error: ConnectionExportError) -> String {
        switch error {
        case .notAFerryExport:
            return "That file isn’t a Ferry connections export."
        case .unsupportedFormatVersion(let found, let supported):
            return "That export was written by a newer version of Ferry "
                 + "(format \(found); this build supports up to \(supported)). Please update Ferry."
        case .corrupted(let detail):
            return "That Ferry export could not be read: \(detail)"
        }
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

        // Keychain writes hop off the main actor: an ACL check on an existing
        // item can put a macOS panel in front of the write (ADR-034).
        let vault = vault
        Task {
            do {
                try await Self.storeSecrets(from: draft, profileID: profileID, vault: vault)
            } catch {
                errorMessage = "The connection was saved, but storing its secret in the Keychain failed: \(Self.describe(error))"
            }
        }
    }

    /// Keychain policy per auth method: only the active method's secret is
    /// kept; empty secret ⇒ item removed ⇒ prompt at connect (DOMAIN.md).
    private nonisolated static func storeSecrets(from draft: ProfileDraft, profileID: UUID,
                                                 vault: CredentialVault) async throws {
        try await Task.detached(priority: .userInitiated) {
            switch draft.authChoice {
            case .password:
                try upsertOrDelete(draft.password, role: .password, profileID: profileID, vault: vault)
                try vault.delete(role: .keyPassphrase, profileID: profileID)
            case .publicKey:
                try upsertOrDelete(draft.keyPassphrase, role: .keyPassphrase, profileID: profileID, vault: vault)
                try vault.delete(role: .password, profileID: profileID)
            case .agent:
                try vault.deleteAll(for: profileID)
            }
        }.value
    }

    private nonisolated static func upsertOrDelete(_ secret: String, role: CredentialRole,
                                                   profileID: UUID, vault: CredentialVault) throws {
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
    ///
    /// `inNewTab` (⌘-double-click, DESIGN.md screen 1) opens a fresh tab;
    /// otherwise the connection lands in the selected tab, disconnecting
    /// whatever it currently holds first ("connects in current tab").
    func connect(profileID: UUID, inNewTab: Bool = false) {
        guard let profile = library.profile(withID: profileID) else { return }
        // SCP rides Citadel's bidirectional exec channel, which is macOS 15+
        // (ADR-020). Fail fast with a clear message on older systems rather than
        // partway through connecting.
        if profile.scheme == .scp, #unavailable(macOS 15.0) {
            errorMessage = "SCP connections require macOS 15 or later. Use SFTP for this server on this Mac."
            return
        }
        FerryLog.debug("Connecting to \(profile.host):\(profile.port) via \(profile.scheme.displayName)")
        let tab = targetTab(newTab: inNewTab)
        prepareForConnect(tab)
        tab.profileID = profileID
        // The credential read can block on a macOS Keychain panel, so it never
        // runs inline on the main actor (ADR-034). The tab is already prepared,
        // so restore-many keeps its tab order regardless of resolution order.
        Task { await resolveCredential(profile: profile, intent: .browser, tab: tab) }
    }

    // MARK: Tabs (M16 checkpoint B, ADR-027)

    /// The tab a connect should land in: a fresh selected tab (⌘-double-click),
    /// or the selected one (reused, or created if somehow none).
    private func targetTab(newTab: Bool) -> ConnectionTab {
        if newTab {
            let tab = ConnectionTab()
            tabs.append(tab)
            return tab
        }
        if let selected = tabs.selected { return selected }
        let tab = ConnectionTab()
        tabs.append(tab)
        return tab
    }

    /// Tears down any live session in `tab` before it hosts a new connection
    /// (double-click "connects in current tab" replaces the session).
    private func prepareForConnect(_ tab: ConnectionTab) {
        teardownSession(in: tab)
        tab.phase = .idle
    }

    func tab(withID id: UUID?) -> ConnectionTab? {
        guard let id else { return nil }
        return tabs.tab(id)
    }

    /// Opens a fresh empty tab (＋ button / ⌘T) and selects it.
    func newTab() {
        tabs.append(ConnectionTab())
    }

    func selectTab(_ id: UUID) {
        tabs.select(id)
    }

    /// ⌘E — open the file selected in the frontmost tab's active pane in an
    /// external editor (M19). Remote files round-trip (edit + auto-upload on
    /// save); local files open in place. No-op without a single-file selection.
    func editSelectedFile() {
        guard let session = selectedTab?.session else { return }
        let pane = session.activePane
        guard let id = pane.selection.first,
              let item = pane.items.first(where: { $0.id == id }),
              !item.isDirectory else { return }
        if pane.kind == .remote {
            session.editRemoteFile(item)
        } else {
            session.editLocalFile(item)
        }
    }

    /// The title shown on a tab chip: the connected/connecting profile name,
    /// the bound profile's name when disconnected, else "New Tab".
    func title(for tab: ConnectionTab) -> String {
        switch tab.phase {
        case .connected(let session): return session.profile.name
        case .connecting(let name): return name
        case .idle:
            if let id = tab.profileID, let profile = library.profile(withID: id) {
                return profile.name
            }
            return "New Tab"
        }
    }

    /// True when `tab` holds a live queue with running or waiting transfers —
    /// closing it should warn first (ADR-027).
    func tabHasActiveTransfers(_ tab: ConnectionTab) -> Bool {
        guard let session = tab.session else { return false }
        return session.queue.activeCount > 0 || session.queue.queuedCount > 0
    }

    /// Closes a tab (✕ / ⌘W): disconnects its session (DOMAIN.md "disconnect on
    /// tab close") and removes it. Closing the last tab leaves one empty tab so
    /// the window (and its shared sidebar) stays — user decision 2026-07-19.
    /// A popped-out terminal survives (it owns its own session); a docked one
    /// shuts down.
    func closeTab(_ id: UUID) {
        if let tab = tabs.tab(id) { teardownSession(in: tab) }
        tabs.close(id)
        if tabs.isEmpty { tabs.append(ConnectionTab()) }
        persistOpenConnections()
    }

    /// ⌘W closes the selected tab.
    func closeSelectedTab() {
        guard let id = tabs.selectedID else { return }
        if let tab = tabs.tab(id), tabHasActiveTransfers(tab) {
            pendingTabClose = id
        } else {
            closeTab(id)
        }
    }

    /// Disconnects `tab` in place (toolbar Disconnect): the session is torn
    /// down but the tab stays, bound to its profile, showing the summary +
    /// Connect (the grey-dot state in the mockup).
    func disconnect(_ tab: ConnectionTab) {
        teardownSession(in: tab)
        tab.phase = .idle
        persistOpenConnections()
    }

    /// Shared teardown for disconnect + close. Screen 7 note 7: a popped-out
    /// terminal keeps its own session but can no longer re-dock (its tab is
    /// gone); a docked terminal is shut down.
    private func teardownSession(in tab: ConnectionTab) {
        guard let session = tab.session else { return }
        if #available(macOS 15.0, *), let terminal = session.terminal {
            if terminal.isWindowed {
                terminal.canRedock = false
            } else {
                Task { await terminal.shutdown() }
            }
        }
        Task { await session.disconnect() }
    }

    // MARK: Reopen last connections (Settings ▸ General, M16)

    private func persistOpenConnections() {
        let ids = tabs.tabs.compactMap { tab -> String? in
            if case .connected(let session) = tab.phase { return session.profile.id.uuidString }
            return nil
        }
        UserDefaults.standard.set(ids, forKey: AppSettings.Key.lastOpenConnectionIDs)
    }

    /// Reconnects every connection open at last quit, one tab each, if the
    /// setting is on (user decision 2026-07-19). Called once from the main
    /// window's `onAppear`. Skipped under test isolation (`FERRY_DATA_DIR`) so
    /// XCUITests never auto-connect. Each connect prompts for any non-Keychain
    /// credential exactly as a manual connect does.
    func restoreLastConnectionsIfEnabled() {
        guard !didAttemptRestore else { return }
        didAttemptRestore = true
        guard ProcessInfo.processInfo.environment["FERRY_DATA_DIR"] == nil else { return }
        let enabled = UserDefaults.standard.object(forKey: AppSettings.Key.reopenLastConnections) as? Bool ?? true
        guard enabled else { return }
        let ids = (UserDefaults.standard.array(forKey: AppSettings.Key.lastOpenConnectionIDs) as? [String]) ?? []
        let profileIDs = ids.compactMap(UUID.init(uuidString:)).filter { library.profile(withID: $0) != nil }
        guard !profileIDs.isEmpty else { return }
        // The first restored connection reuses the initial empty tab; the rest
        // each open a new tab.
        for (offset, profileID) in profileIDs.enumerated() {
            connect(profileID: profileID, inNewTab: offset > 0)
        }
    }

    /// Sidebar context menu "Open Terminal" (screen 7 note 4): a shell with no
    /// browser. Dispatches on the terminal-choice setting (M15, ADR-024) —
    /// built-in opens a terminal-only window (resolving the credential through
    /// the same prompts as `connect`, then preflighting); external hands off to
    /// Terminal.app / iTerm2 / a custom command (ssh authenticates there).
    func openTerminal(profileID: UUID) {
        guard let profile = library.profile(withID: profileID) else { return }
        guard profile.scheme == .sftp || profile.scheme == .scp else { return }
        switch TerminalLaunchService.dispatch() {
        case .builtIn:
            guard #available(macOS 15.0, *) else {
                errorMessage = "The built-in terminal requires macOS 15 or later."
                return
            }
            Task { await resolveCredential(profile: profile, intent: .terminal, tab: nil) }
        case .external(let terminal):
            launchExternalTerminal(terminal, profile: profile)
        case .unavailable(let reason):
            errorMessage = reason
        }
    }

    /// The resolved Terminal action for a profile — the browser toolbar toggle
    /// reads this to choose between toggling the docked panel (built-in) and
    /// firing the external hand-off (ADR-024).
    func terminalDispatch() -> TerminalDispatch {
        TerminalLaunchService.dispatch()
    }

    /// Hand the profile's ssh command to an external terminal (Direct only). No
    /// credential is resolved: passwords are never passed (rule 6), and ssh does
    /// its own host-key TOFU against `~/.ssh/known_hosts`, not Ferry's store.
    func launchExternalTerminal(_ terminal: ExternalTerminal, profile: ConnectionProfile) {
        #if APPSTORE
        errorMessage = "Opening an external terminal isn’t available in this build."
        #else
        let keyPath: String?
        if case .publicKey(let path) = profile.authMethod { keyPath = path } else { keyPath = nil }
        let command = SSHCommandBuilder.build(host: profile.host,
                                              port: profile.port,
                                              username: profile.username,
                                              keyPath: keyPath,
                                              remoteStartPath: profile.remoteStartPath)
        do {
            try ExternalTerminalLauncher.launch(terminal, command: command)
        } catch {
            errorMessage = "Could not open \(terminal.displayName): \(error.localizedDescription)"
        }
        #endif
    }

    /// Shared credential resolution for both intents: stored secret → go,
    /// otherwise the matching prompt (which carries the intent + target tab
    /// forward). `tab` is nil for the terminal-only intent.
    private func resolveCredential(profile: ConnectionProfile, intent: ConnectIntent,
                                   tab: ConnectionTab?) async {
        switch profile.authMethod {
        case .password:
            do {
                if let stored = try await vault.retrieveAsync(role: .password, profileID: profile.id) {
                    startResolved(profile: profile, credential: .password(stored), intent: intent, tab: tab)
                } else {
                    passwordPrompt = PasswordPrompt(profileID: profile.id, profileName: profile.name,
                                                    intent: intent, tabID: tab?.id)
                }
            } catch {
                credentialReadFailed(error, secret: "password", profile: profile,
                                     intent: intent, tab: tab)
            }
        case .publicKey(let path):
            await connectWithKey(profile: profile, path: path, intent: intent, tab: tab)
        case .agent:
            infoMessage = "SSH-agent authentication is planned for a later release. Edit the connection to use a key file or password for now."
        }
    }

    /// Continuation of `connect`/`openTerminal` after the user typed a password.
    func connectWithTypedPassword(_ password: String, prompt: PasswordPrompt, remember: Bool) {
        guard let profile = library.profile(withID: prompt.profileID) else { return }
        if remember { rememberSecret(password, role: .password, profileID: profile.id) }
        startResolved(profile: profile, credential: .password(password),
                      intent: prompt.intent, tab: tab(withID: prompt.tabID))
    }

    /// Resolves an SSH-key credential: read the key file, then attempt with any
    /// stored passphrase. The connect flow prompts for a passphrase only if the
    /// key turns out to be encrypted and the stored one is missing/wrong.
    private func connectWithKey(profile: ConnectionProfile, path: String,
                                intent: ConnectIntent, tab: ConnectionTab?) async {
        let pem: Data
        do {
            pem = try Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        } catch {
            errorMessage = "Could not read the key file at \(path). Check the path and permissions."
            if intent == .browser { tab?.phase = .idle }
            return
        }
        let storedPassphrase: String?
        do {
            storedPassphrase = try await vault.retrieveAsync(role: .keyPassphrase, profileID: profile.id)
        } catch {
            credentialReadFailed(error, secret: "passphrase", profile: profile,
                                 intent: intent, tab: tab)
            return
        }
        startResolved(profile: profile,
                      credential: .privateKey(pem: pem, passphrase: storedPassphrase),
                      intent: intent, tab: tab)
    }

    /// A secret is stored but reading it failed. The common case is the user
    /// denying the macOS Keychain authorization panel — say so instead of
    /// falling through to a prompt that looks like Ferry forgot the secret
    /// (ADR-034).
    private func credentialReadFailed(_ error: Error, secret: String,
                                      profile: ConnectionProfile,
                                      intent: ConnectIntent, tab: ConnectionTab?) {
        if case CredentialVaultError.userCanceled = error {
            errorMessage = "Ferry could not use the saved \(secret) for “\(profile.name)”: macOS denied " +
                           "access to your Keychain. Connect again and choose Allow, or re-enter the " +
                           "\(secret) in the connection’s settings."
        } else {
            errorMessage = "Ferry could not read the saved \(secret) for “\(profile.name)”: " +
                           "\(Self.describe(error))"
        }
        if intent == .browser { tab?.phase = .idle }
    }

    /// Stores a secret the user asked Ferry to remember. Off the main actor —
    /// writing an existing item is ACL-checked, so it can prompt (ADR-034) —
    /// and never blocking the connect it belongs to.
    private func rememberSecret(_ secret: String, role: CredentialRole, profileID: UUID) {
        let vault = vault
        Task {
            do {
                try await vault.storeAsync(secret, role: role, profileID: profileID)
            } catch {
                errorMessage = "Ferry connected, but could not save the \(role == .password ? "password" : "passphrase") " +
                               "in your Keychain: \(Self.describe(error))"
            }
        }
    }

    /// User-facing text for a Keychain failure. CredentialVaultError has no
    /// localizedDescription worth showing, so name the cases we know.
    static func describe(_ error: Error) -> String {
        guard let vaultError = error as? CredentialVaultError else {
            return error.localizedDescription
        }
        switch vaultError {
        case .userCanceled:
            return "macOS denied access to your Keychain."
        case .corruptedItem:
            return "the stored item is not readable text — delete and re-enter it."
        case .unexpectedStatus(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
            return detail
        }
    }

    /// Continuation after the user typed a key passphrase.
    func connectWithTypedPassphrase(_ passphrase: String,
                                    prompt: KeyPassphrasePrompt, remember: Bool) {
        guard let profile = library.profile(withID: prompt.profileID) else { return }
        if remember { rememberSecret(passphrase, role: .keyPassphrase, profileID: profile.id) }
        startResolved(profile: profile,
                      credential: .privateKey(pem: prompt.pem, passphrase: passphrase),
                      intent: prompt.intent, tab: tab(withID: prompt.tabID))
    }

    /// The user approved an unknown host key (TOFU) — retry the connection. When
    /// `remember` is on the key is persisted to the store; otherwise it is
    /// trusted for this session only (DOMAIN.md → Host key trust).
    func trustHostKeyAndConnect(_ prompt: HostKeyPrompt, remember: Bool) {
        let targetTab = tab(withID: prompt.tabID)
        if remember {
            do {
                try hostKeyStore.trust(prompt.offered, host: prompt.profile.host, port: prompt.profile.port)
            } catch {
                errorMessage = "Could not save the host key: \(error.localizedDescription)"
                if prompt.intent == .browser { targetTab?.phase = .idle }
                return
            }
            startResolved(profile: prompt.profile, credential: prompt.credential,
                          intent: prompt.intent, tab: targetTab)
        } else {
            startResolved(profile: prompt.profile, credential: prompt.credential,
                          sessionTrusted: prompt.offered, intent: prompt.intent, tab: targetTab)
        }
    }

    /// The user chose to replace a CHANGED host key (second confirmation already
    /// given by the UI) — swap the trusted key and retry.
    func replaceHostKeyAndConnect(_ prompt: HostKeyPrompt) {
        let targetTab = tab(withID: prompt.tabID)
        do {
            try hostKeyStore.replace(with: prompt.offered, host: prompt.profile.host, port: prompt.profile.port)
        } catch {
            errorMessage = "Could not update the host key: \(error.localizedDescription)"
            if prompt.intent == .browser { targetTab?.phase = .idle }
            return
        }
        startResolved(profile: prompt.profile, credential: prompt.credential,
                      intent: prompt.intent, tab: targetTab)
    }

    /// The credential is resolved — open what the intent asked for.
    private func startResolved(profile: ConnectionProfile, credential: SSHAuthCredential,
                               sessionTrusted: HostKeyInfo? = nil, intent: ConnectIntent,
                               tab: ConnectionTab?) {
        switch intent {
        case .browser:
            guard let tab else { return }
            startConnection(profile: profile, credential: credential,
                            sessionTrusted: sessionTrusted, tab: tab)
        case .terminal:
            if #available(macOS 15.0, *) {
                startTerminalOnly(profile: profile, credential: credential, sessionTrusted: sessionTrusted)
            }
        }
    }

    private func startConnection(profile: ConnectionProfile, credential: SSHAuthCredential,
                                 sessionTrusted: HostKeyInfo? = nil, tab: ConnectionTab) {
        tab.phase = .connecting(profileName: profile.name)
        switch profile.scheme {
        case .ftp, .ftps:
            startFTPConnection(profile: profile, credential: credential, tab: tab)
        case .sftp:
            startSFTPConnection(profile: profile, credential: credential, sessionTrusted: sessionTrusted, tab: tab)
        case .scp:
            startSCPConnection(profile: profile, credential: credential, sessionTrusted: sessionTrusted, tab: tab)
        }
    }

    /// Publishes a freshly-connected session into its tab. If the tab was
    /// closed while connecting, the session is torn down instead of leaking.
    private func finishConnect(_ session: BrowserSession, into tab: ConnectionTab) {
        guard tabs.contains(tab.id) else {
            Task { await session.disconnect() }
            return
        }
        tab.phase = .connected(session)
        persistOpenConnections()
    }

    /// Terminal-only connect (screen 7 note 4): preflight trust + auth so the
    /// TOFU/credential prompts run BEFORE any window exists, then register a
    /// standalone controller and ask the UI to open its window. Deliberately
    /// touches no tab — a terminal-only window is independent of the tabs.
    @available(macOS 15.0, *)
    private func startTerminalOnly(profile: ConnectionProfile, credential: SSHAuthCredential,
                                   sessionTrusted: HostKeyInfo?) {
        Task {
            do {
                try await TerminalSession.preflight(host: profile.host,
                                                    port: profile.port,
                                                    username: profile.username,
                                                    credential: credential,
                                                    hostKeyStore: hostKeyStore,
                                                    systemKnownHosts: systemKnownHosts,
                                                    sessionTrusted: sessionTrusted)
                let controller = TerminalController(profile: profile,
                                                    credential: credential,
                                                    hostKeyStore: hostKeyStore,
                                                    systemKnownHosts: systemKnownHosts,
                                                    sessionTrusted: sessionTrusted,
                                                    standalone: true)
                controller.isWindowed = true
                registerTerminalWindow(controller)
                pendingTerminalWindowID = controller.id
                controller.ensureStarted()
            } catch let error as RemoteSourceError {
                handleConnectError(error, profile: profile, credential: credential, intent: .terminal)
            } catch let error as SSHKeyLoadError {
                handleKeyError(error, profile: profile, credential: credential, intent: .terminal)
            } catch {
                errorMessage = "Could not open a terminal on \(profile.host): \(error.localizedDescription)"
            }
        }
    }

    private func startSFTPConnection(profile: ConnectionProfile, credential: SSHAuthCredential,
                                     sessionTrusted: HostKeyInfo?, tab: ConnectionTab) {
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
                let tunnels = makeTunnelController(profile: profile, credential: credential,
                                                   sessionTrusted: sessionTrusted)
                let session = BrowserSession(profile: profile, remote: sftp, bookmarks: nil,
                                             tunnels: tunnels,
                                             terminal: makeDockedTerminal(profile: profile,
                                                                          credential: credential,
                                                                          sessionTrusted: sessionTrusted))
                await session.start()
                finishConnect(session, into: tab)
            } catch let error as RemoteSourceError {
                handleConnectError(error, profile: profile, credential: credential, tab: tab)
            } catch let error as SSHKeyLoadError {
                handleKeyError(error, profile: profile, credential: credential, tab: tab)
            } catch {
                tab.phase = .idle
                errorMessage = "Could not connect: \(error.localizedDescription)"
            }
        }
    }

    /// SCP connect (M13). Reuses the SSH stack exactly as SFTP does — same
    /// host-key TOFU + password/key auth — differing only in the backend
    /// (`SCPSource`, exec-channel metadata + scp wire-protocol transfers,
    /// ADR-020). Gated to macOS 15+ (Citadel's `withExec`); `connect` already
    /// blocked older systems, so the `#available` else-branch is belt-and-braces.
    private func startSCPConnection(profile: ConnectionProfile, credential: SSHAuthCredential,
                                    sessionTrusted: HostKeyInfo?, tab: ConnectionTab) {
        guard #available(macOS 15.0, *) else {
            tab.phase = .idle
            errorMessage = "SCP connections require macOS 15 or later."
            return
        }
        Task {
            do {
                let scp = try await SCPSource.connect(host: profile.host,
                                                      port: profile.port,
                                                      username: profile.username,
                                                      credential: credential,
                                                      hostKeyStore: hostKeyStore,
                                                      systemKnownHosts: systemKnownHosts,
                                                      sessionTrusted: sessionTrusted,
                                                      displayName: profile.name)
                let tunnels = makeTunnelController(profile: profile, credential: credential,
                                                   sessionTrusted: sessionTrusted)
                let session = BrowserSession(profile: profile, remote: scp, bookmarks: nil,
                                             tunnels: tunnels,
                                             terminal: makeDockedTerminal(profile: profile,
                                                                          credential: credential,
                                                                          sessionTrusted: sessionTrusted))
                await session.start()
                finishConnect(session, into: tab)
            } catch let error as RemoteSourceError {
                handleConnectError(error, profile: profile, credential: credential, tab: tab)
            } catch let error as SSHKeyLoadError {
                handleKeyError(error, profile: profile, credential: credential, tab: tab)
            } catch {
                tab.phase = .idle
                errorMessage = "Could not connect: \(error.localizedDescription)"
            }
        }
    }

    /// FTP / FTPS connect (M12). Password auth only; TLS posture is derived
    /// from the scheme + port: `.ftps` on 990 is implicit, otherwise explicit
    /// AUTH TLS (ADR-019). For FTPS, a certificate the user has pinned for this
    /// endpoint (CertificateTrustStore) is threaded through so the connection is
    /// verified against it; an untrusted / changed certificate surfaces the cert
    /// TOFU prompt (ADR-033). `sessionTrustedCert` carries a "don't remember"
    /// decision so it survives an in-flight retry without being persisted.
    private func startFTPConnection(profile: ConnectionProfile, credential: SSHAuthCredential,
                                    tab: ConnectionTab, sessionTrustedCert: CertificateInfo? = nil) {
        guard case .password(let password) = credential else {
            tab.phase = .idle
            errorMessage = "FTP connections authenticate with a password."
            return
        }
        let security: FTPSecurity
        switch profile.scheme {
        case .ftps: security = profile.port == 990 ? .implicit : .explicit
        default: security = .none
        }
        let pinned = sessionTrustedCert
            ?? (try? certificateTrustStore.trustedCertificate(host: profile.host, port: profile.port))
        Task {
            do {
                let ftp = try await FTPSource.connect(host: profile.host,
                                                      port: profile.port,
                                                      username: profile.username,
                                                      password: password,
                                                      security: security,
                                                      trustedCertificate: pinned,
                                                      displayName: profile.name)
                let session = BrowserSession(profile: profile, remote: ftp, bookmarks: nil)
                await session.start()
                finishConnect(session, into: tab)
            } catch let error as RemoteSourceError {
                handleFTPConnectError(error, profile: profile, password: password, tab: tab)
            } catch {
                tab.phase = .idle
                errorMessage = "Could not connect: \(error.localizedDescription)"
            }
        }
    }

    private func handleFTPConnectError(_ error: RemoteSourceError, profile: ConnectionProfile,
                                       password: String, tab: ConnectionTab) {
        switch error {
        case .certificateUntrusted(let offered):
            // Tab returns to idle behind the sheet (mirrors the host-key flow);
            // the retry re-enters `.connecting`. A cancelled sheet leaves it idle.
            tab.phase = .idle
            certificatePrompt = CertificatePrompt(profile: profile, offered: offered,
                                                  stored: [], password: password, tabID: tab.id)
        case .certificateChanged(let stored, let offered):
            tab.phase = .idle
            certificatePrompt = CertificatePrompt(profile: profile, offered: offered,
                                                  stored: [stored], password: password, tabID: tab.id)
        default:
            tab.phase = .idle
            switch error {
            case .authenticationFailed:
                errorMessage = "The server rejected the login for \(profile.username)@\(profile.host). Check the username and password."
            case .connectionFailed(let detail):
                errorMessage = "Could not connect to \(profile.host):\(String(profile.port)) — \(detail)"
            case .tlsFailed(let detail):
                errorMessage = "The secure (TLS) connection to \(profile.host) failed: \(detail). The TLS mode (implicit vs. explicit) may not match the port."
            case .hostKeyUnknown, .hostKeyChanged:
                errorMessage = "Unexpected host-key error on an FTP connection."
            case .certificateUntrusted, .certificateChanged:
                break   // handled above
            }
        }
    }

    /// The user approved an FTPS certificate (cert TOFU) — pin it (when
    /// `remember`) and retry, mirroring `trustHostKeyAndConnect`. A "don't
    /// remember" decision trusts the certificate for this session only: it is
    /// threaded into the retry (so an in-session reconnect honours it) but not
    /// persisted.
    func trustCertificateAndConnect(_ prompt: CertificatePrompt, remember: Bool) {
        guard let tab = tab(withID: prompt.tabID) else { return }
        if remember {
            do {
                try certificateTrustStore.trust(prompt.offered, host: prompt.profile.host, port: prompt.profile.port)
            } catch {
                errorMessage = "Could not save the certificate: \(error.localizedDescription)"
                tab.phase = .idle
                return
            }
            tab.phase = .connecting(profileName: prompt.profile.name)
            startFTPConnection(profile: prompt.profile, credential: .password(prompt.password), tab: tab)
        } else {
            tab.phase = .connecting(profileName: prompt.profile.name)
            startFTPConnection(profile: prompt.profile, credential: .password(prompt.password),
                               tab: tab, sessionTrustedCert: prompt.offered)
        }
    }

    /// The user chose to replace a CHANGED FTPS certificate (second confirmation
    /// already given by the UI) — repin and retry, mirroring
    /// `replaceHostKeyAndConnect`.
    func replaceCertificateAndConnect(_ prompt: CertificatePrompt) {
        guard let tab = tab(withID: prompt.tabID) else { return }
        do {
            try certificateTrustStore.replace(with: prompt.offered, host: prompt.profile.host, port: prompt.profile.port)
        } catch {
            errorMessage = "Could not update the certificate: \(error.localizedDescription)"
            tab.phase = .idle
            return
        }
        tab.phase = .connecting(profileName: prompt.profile.name)
        startFTPConnection(profile: prompt.profile, credential: .password(prompt.password), tab: tab)
    }

    private func handleConnectError(_ error: RemoteSourceError,
                                    profile: ConnectionProfile,
                                    credential: SSHAuthCredential,
                                    intent: ConnectIntent = .browser,
                                    tab: ConnectionTab? = nil) {
        // A failed terminal-only connect must not disturb a live browser tab.
        if intent == .browser { tab?.phase = .idle }
        switch error {
        case .authenticationFailed:
            errorMessage = authFailureMessage(profile: profile, credential: credential)
        case .connectionFailed(let detail):
            errorMessage = "Could not connect to \(profile.host):\(String(profile.port)) — \(detail)"
        case .hostKeyUnknown(let offered):
            hostKeyPrompt = HostKeyPrompt(profile: profile, offered: offered,
                                          stored: [], credential: credential,
                                          intent: intent, tabID: tab?.id)
        case .hostKeyChanged(let stored, let offered):
            hostKeyPrompt = HostKeyPrompt(profile: profile, offered: offered,
                                          stored: stored, credential: credential,
                                          intent: intent, tabID: tab?.id)
        case .tlsFailed(let detail):
            // TLS is an FTPS concern; an SSH connect shouldn't produce it.
            errorMessage = "Unexpected TLS error connecting to \(profile.host): \(detail)"
        case .certificateUntrusted, .certificateChanged:
            // Certificate trust is an FTPS concern (handled in
            // handleFTPConnectError); an SSH connect should never produce it.
            errorMessage = "Unexpected certificate error on an SSH connection to \(profile.host)."
        }
    }

    private func handleKeyError(_ error: SSHKeyLoadError,
                                profile: ConnectionProfile,
                                credential: SSHAuthCredential,
                                intent: ConnectIntent = .browser,
                                tab: ConnectionTab? = nil) {
        if intent == .browser { tab?.phase = .idle }
        guard case .privateKey(let pem, _) = credential else {
            errorMessage = "The key could not be used: \(error.localizedDescription)"
            return
        }
        switch error {
        case .passphraseRequired:
            keyPassphrasePrompt = KeyPassphrasePrompt(profileID: profile.id,
                                                      profileName: profile.name,
                                                      pem: pem, incorrect: false,
                                                      intent: intent, tabID: tab?.id)
        case .incorrectPassphrase:
            keyPassphrasePrompt = KeyPassphrasePrompt(profileID: profile.id,
                                                      profileName: profile.name,
                                                      pem: pem, incorrect: true,
                                                      intent: intent, tabID: tab?.id)
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

    /// The docked terminal for an SSH browser session (screen 7): built
    /// eagerly like the tunnel controller — its SSH session dials only when
    /// the panel first opens, so it's free until used. nil on macOS 14 (the
    /// PTY API's availability gate, ADR-023) and the toolbar explains why.
    private func makeDockedTerminal(profile: ConnectionProfile,
                                    credential: SSHAuthCredential,
                                    sessionTrusted: HostKeyInfo?) -> Any? {
        guard #available(macOS 15.0, *) else { return nil }
        return TerminalController(profile: profile,
                                  credential: credential,
                                  hostKeyStore: hostKeyStore,
                                  systemKnownHosts: systemKnownHosts,
                                  sessionTrusted: sessionTrusted,
                                  standalone: false)
    }

    // MARK: Tunnels (M14)

    /// Builds the port-forward manager for an SSH-based session. The engine
    /// opens its own SSH session lazily (only when a tunnel actually starts),
    /// reusing the resolved credential + trust exactly as the browser session
    /// did (ADR-021) — so no second prompt.
    private func makeTunnelController(profile: ConnectionProfile,
                                      credential: SSHAuthCredential,
                                      sessionTrusted: HostKeyInfo?) -> TunnelController {
        let engine = TunnelEngine(host: profile.host,
                                  port: profile.port,
                                  username: profile.username,
                                  credential: credential,
                                  hostKeyStore: hostKeyStore,
                                  systemKnownHosts: systemKnownHosts,
                                  sessionTrusted: sessionTrusted)
        return TunnelController(engine: engine)
    }

    func addTunnel(_ tunnel: TunnelConfiguration, toProfileID id: UUID) {
        updateTunnels(profileID: id) { $0.append(tunnel) }
    }

    func updateTunnel(_ tunnel: TunnelConfiguration, inProfileID id: UUID) {
        updateTunnels(profileID: id) { tunnels in
            if let index = tunnels.firstIndex(where: { $0.id == tunnel.id }) {
                tunnels[index] = tunnel
            }
        }
    }

    func removeTunnel(_ tunnelID: UUID, fromProfileID id: UUID) {
        updateTunnels(profileID: id) { $0.removeAll { $0.id == tunnelID } }
    }

    func setTunnelEnabled(_ tunnelID: UUID, _ enabled: Bool, inProfileID id: UUID) {
        updateTunnels(profileID: id) { tunnels in
            if let index = tunnels.firstIndex(where: { $0.id == tunnelID }) {
                tunnels[index].isEnabled = enabled
            }
        }
    }

    func setAutoStartTunnels(_ on: Bool, inProfileID id: UUID) {
        guard var profile = library.profile(withID: id) else { return }
        profile.autoStartTunnels = on
        mutate { $0.updateProfile(profile) }
    }

    private func updateTunnels(profileID id: UUID,
                               _ change: (inout [TunnelConfiguration]) -> Void) {
        guard var profile = library.profile(withID: id) else { return }
        change(&profile.tunnels)
        mutate { $0.updateProfile(profile) }
    }
}
