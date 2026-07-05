import Foundation
import FerryCore

/// Editable working copy behind the connection sheet (DESIGN.md screen 2).
/// Secrets live here only while the sheet is open; on save they go to the
/// Keychain via the model, never into the profile.
struct ProfileDraft {
    enum AuthChoice: String, CaseIterable, Identifiable {
        case password = "Password"
        case publicKey = "SSH Key"
        case agent = "SSH Agent"
        var id: String { rawValue }
    }

    var name = ""
    var scheme: TransferProtocol = .sftp
    var host = ""
    var port = TransferProtocol.sftp.defaultPort
    var username = ""
    var authChoice: AuthChoice = .password
    var password = ""
    var privateKeyPath = ""
    var keyPassphrase = ""
    var remoteStartPath = ""
    var localStartPath = ""
    var keepAlive = true
    var folderID: UUID?

    /// Auth methods offered for the current protocol (FTP/FTPS: password only).
    var availableAuthChoices: [AuthChoice] {
        guard scheme.usesSSH else { return [.password] }
        #if APPSTORE
        return [.password, .publicKey]   // no ssh-agent in the sandbox (DOMAIN.md)
        #else
        return [.password, .publicKey, .agent]
        #endif
    }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && (1...65535).contains(port)
            && (authChoice != .publicKey || !privateKeyPath.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// Mirrors the mockup: switching protocol updates the port only when the
    /// user hasn't customized it.
    mutating func switchScheme(to newScheme: TransferProtocol) {
        let oldDefault = scheme.defaultPort
        scheme = newScheme
        if port == oldDefault { port = newScheme.defaultPort }
        if !availableAuthChoices.contains(authChoice) { authChoice = .password }
    }

    static func forNewProfile(folderID: UUID?) -> ProfileDraft {
        var draft = ProfileDraft()
        draft.folderID = folderID
        return draft
    }

    @MainActor
    static func fromExisting(_ profile: ConnectionProfile, in model: ConnectionManagerModel) -> ProfileDraft {
        var draft = ProfileDraft()
        draft.name = profile.name
        draft.scheme = profile.scheme
        draft.host = profile.host
        draft.port = profile.port
        draft.username = profile.username
        draft.remoteStartPath = profile.remoteStartPath ?? ""
        draft.localStartPath = profile.localStartPath ?? ""
        draft.keepAlive = profile.keepAlive
        draft.folderID = model.library.parentFolderID(ofItem: profile.id)
        switch profile.authMethod {
        case .password:
            draft.authChoice = .password
            draft.password = (try? model.vault.retrieve(role: .password, profileID: profile.id)) ?? ""
        case .publicKey(let path):
            draft.authChoice = .publicKey
            draft.privateKeyPath = path
            draft.keyPassphrase = (try? model.vault.retrieve(role: .keyPassphrase, profileID: profile.id)) ?? ""
        case .agent:
            draft.authChoice = .agent
        }
        return draft
    }

    private var authMethod: AuthenticationMethod {
        switch authChoice {
        case .password: .password
        case .publicKey: .publicKey(privateKeyPath: privateKeyPath.trimmingCharacters(in: .whitespaces))
        case .agent: .agent
        }
    }

    func buildProfile() -> ConnectionProfile {
        ConnectionProfile(name: name.trimmingCharacters(in: .whitespaces),
                          scheme: scheme,
                          host: host.trimmingCharacters(in: .whitespaces),
                          port: port,
                          username: username.trimmingCharacters(in: .whitespaces),
                          authMethod: authMethod,
                          remoteStartPath: remoteStartPath.isEmpty ? nil : remoteStartPath,
                          localStartPath: localStartPath.isEmpty ? nil : localStartPath,
                          keepAlive: keepAlive)
    }

    /// Applies edits onto an existing profile, preserving identity, tunnels,
    /// and restoration state.
    func apply(to profile: inout ConnectionProfile) {
        profile.name = name.trimmingCharacters(in: .whitespaces)
        profile.scheme = scheme
        profile.host = host.trimmingCharacters(in: .whitespaces)
        profile.port = port
        profile.username = username.trimmingCharacters(in: .whitespaces)
        profile.authMethod = authMethod
        profile.remoteStartPath = remoteStartPath.isEmpty ? nil : remoteStartPath
        profile.localStartPath = localStartPath.isEmpty ? nil : localStartPath
        profile.keepAlive = keepAlive
    }
}
