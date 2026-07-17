@preconcurrency import Citadel
import Foundation
import NIOCore
import NIOSSH

/// Trust-On-First-Use host-key validation for Citadel (DOMAIN.md → Host key
/// trust). NIO validates the host key on the event loop *during* the
/// handshake and cannot pause for a UI prompt, so this validator makes a
/// synchronous decision against the keys Ferry already trusts:
///
/// - offered key is trusted → succeed, handshake continues;
/// - offered key is not trusted → **capture it** and fail the handshake.
///
/// `SFTPSource.connect` inspects `offeredKey` after a failed connect to tell a
/// host-key rejection apart from other errors, classify it as unknown-vs-
/// changed, and surface the fingerprint for the screen-3 prompt. On the user's
/// approval the key is written to the HostKeyStore and the connect retried —
/// this time the offered key is in `trusted` and validation passes.
final class TOFUHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    struct Rejected: Error {}

    private let trusted: Set<NIOSSHPublicKey>
    private let lock = NSLock()
    private var captured: NIOSSHPublicKey?

    init(trusted: Set<NIOSSHPublicKey>) {
        self.trusted = trusted
    }

    /// The key the server actually offered, recorded even when rejected.
    var offeredKey: NIOSSHPublicKey? {
        lock.lock(); defer { lock.unlock() }
        return captured
    }

    /// True once a key was offered that Ferry does not (yet) trust.
    var rejectedUntrustedKey: Bool {
        guard let offeredKey else { return false }
        return !trusted.contains(offeredKey)
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        lock.lock()
        captured = hostKey
        lock.unlock()

        if trusted.contains(hostKey) {
            validationCompletePromise.succeed(())
        } else {
            validationCompletePromise.fail(Rejected())
        }
    }
}
