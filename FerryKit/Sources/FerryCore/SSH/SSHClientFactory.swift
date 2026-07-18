@preconcurrency import Citadel
import Foundation
import NIOPosix
import NIOSSH

/// Everything needed to establish (and silently re-establish) an authenticated
/// SSH transport with TOFU host-key verification. Held in memory only — never
/// logged or persisted (DOMAIN.md): it carries the credential (incl. private
/// key material) and the trust store, so an auto-reconnect re-validates the
/// host key exactly as the first connect did.
///
/// Shared by every SSH-based backend (`SFTPSource` since M11, `SCPSource` since
/// M13) so the host-key trust decision lives in exactly one place.
struct SSHConnectionParameters: Sendable {
    var host: String
    var port: Int
    var username: String
    var credential: SSHAuthCredential
    var hostKeyStore: HostKeyStore
    /// The user's `~/.ssh/known_hosts`, read-only, as pre-trust: hosts they
    /// already know connect without a TOFU prompt (M11 checkpoint B). Frozen at
    /// connect so auto-reconnect re-validates identically. nil ⇒ no pre-trust.
    var systemKnownHosts: KnownHostsFile?
    /// A key trusted for this session only (the user declined "remember").
    /// Merged into the validator's trusted set and kept so a mid-session
    /// reconnect still succeeds, but never written to the store.
    var sessionTrusted: HostKeyInfo?
}

/// Builds authenticated `SSHClient`s with TOFU host-key verification. The single
/// source of truth for how Ferry trusts (or rejects) an SSH host key and maps a
/// failed connect into a typed `RemoteSourceError` — audited once, reused by
/// SFTP and SCP (ADR-016/017, ADR-020).
enum SSHClientFactory {
    /// Establishes an authenticated SSH transport, verifying the host key TOFU.
    ///
    /// Throws `RemoteSourceError.hostKeyUnknown`/`.hostKeyChanged` when the
    /// offered host key isn't trusted (the app resolves trust and retries),
    /// `.authenticationFailed` on bad credentials, `SSHKeyLoadError` when a key
    /// can't be parsed (e.g. a passphrase is needed), and `.connectionFailed`
    /// otherwise.
    ///
    /// `group` pins the client to a specific event-loop group. `SFTPSource`/
    /// `SCPSource` leave it at Citadel's shared singleton, but `TunnelEngine`
    /// (M14) passes a dedicated single-thread group so the SSH channel, its
    /// direct-tcpip forwards, and the local listener all share one event loop —
    /// which lets the port-forward glue touch both channels' contexts directly
    /// (ADR-021).
    static func connect(_ parameters: SSHConnectionParameters,
                        group: MultiThreadedEventLoopGroup = .singleton) async throws -> SSHClient {
        var trusted = (try? parameters.hostKeyStore.trustedKeys(host: parameters.host,
                                                                port: parameters.port)) ?? []
        if let systemKnownHosts = parameters.systemKnownHosts {
            trusted.formUnion(systemKnownHosts.trustedKeys(host: parameters.host,
                                                           port: parameters.port))
        }
        if let sessionTrusted = parameters.sessionTrusted,
           let key = try? NIOSSHPublicKey(openSSHPublicKey: sessionTrusted.openSSH) {
            trusted.insert(key)
        }
        let validator = TOFUHostKeyValidator(trusted: trusted)
        // Key parsing errors (incl. passphraseRequired) propagate untouched so
        // the app can prompt — they must not be swallowed as connection errors.
        let authMethod = try makeAuthMethod(parameters)

        do {
            return try await SSHClient.connect(
                host: parameters.host,
                port: parameters.port,
                authenticationMethod: authMethod,
                hostKeyValidator: .custom(validator),
                reconnect: .never,
                group: group)
        } catch {
            // A rejected, untrusted host key is the reason for the failure —
            // classify it as unknown (first contact) vs. changed (MITM risk).
            if validator.rejectedUntrustedKey, let offered = validator.offeredKey {
                let offeredInfo = HostKeyInfo(publicKey: offered)
                var stored = (try? parameters.hostKeyStore.storedInfos(host: parameters.host,
                                                                       port: parameters.port)) ?? []
                if let systemKnownHosts = parameters.systemKnownHosts {
                    stored += systemKnownHosts.storedInfos(host: parameters.host,
                                                           port: parameters.port)
                }
                // De-dup: the same key can appear in both stores; the changed-key
                // alarm should list each stored fingerprint once. Preserve order.
                var seen = Set<HostKeyInfo>()
                stored = stored.filter { seen.insert($0).inserted }
                throw stored.isEmpty
                    ? RemoteSourceError.hostKeyUnknown(offeredInfo)
                    : RemoteSourceError.hostKeyChanged(stored: stored, offered: offeredInfo)
            }
            throw mapConnectError(error)
        }
    }

    private static func makeAuthMethod(_ parameters: SSHConnectionParameters) throws -> SSHAuthenticationMethod {
        switch parameters.credential {
        case .password(let password):
            return .passwordBased(username: parameters.username, password: password)
        case .privateKey(let pem, let passphrase):
            return try SSHKeyLoader.authenticationMethod(username: parameters.username,
                                                         pem: pem, passphrase: passphrase)
        }
    }

    static func mapConnectError(_ error: Error) -> RemoteSourceError {
        if error is Citadel.AuthenticationFailed { return .authenticationFailed }
        if case SSHClientError.allAuthenticationOptionsFailed = error { return .authenticationFailed }
        return .connectionFailed(String(describing: error))
    }
}
