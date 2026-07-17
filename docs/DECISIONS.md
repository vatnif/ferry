# Ferry — Decision log (ADRs)

*Append a dated entry for every significant technical or product decision. Newest last.*

## 2026-07-05 — ADR-001: Native Swift 6 + SwiftUI
User choice (over Kotlin/Compose and Electron/Tauri): premium native feel for a paid Mac
utility, Keychain/Touch ID access, small bundle. AppKit bridges allowed where SwiftUI
falls short. Min target macOS 14.

## 2026-07-05 — ADR-002: Dual distribution, sandbox-compatible from day one
Direct sale first (Developer ID + notarization), Mac App Store later. Consequence: 4 build
configurations (Debug/Release × Direct/AppStore), `APPSTORE` compile flag, all local FS
access through security-scoped-bookmark-aware code, agent/terminal features gated.

## 2026-07-05 — ADR-003: Permissive-licenses-only policy
Product will be sold; GPL/LGPL and friends are banned outright (details LICENSING.md).
SSH stack: Citadel (MIT) over swift-nio-ssh (Apache-2.0), fallback libssh2 (BSD-3) —
decided by M6 spike. FTP via macOS system libcurl (nothing bundled). Never libssh (LGPL).

## 2026-07-05 — ADR-004: Core logic in a local SwiftPM package (FerryKit)
All non-UI code lives in FerryKit/FerryCore: headless-testable (`swift test`), keeps the
hand-written pbxproj tiny, enforces UI/core separation. App target is a thin SwiftUI shell.

## 2026-07-05 — ADR-005: Hand-authored Xcode project, no generator
No Homebrew/XcodeGen on the dev machine; instead `project.pbxproj` (objectVersion 77)
uses synchronized folder groups, so file additions don't touch the project file.
Revisit only if target structure grows complex.

## 2026-07-05 — ADR-006: Docker-based integration test servers
`atmoz/sftp` (:2222) + `delfer/alpine-ftp-server` (:2121), creds ferry/ferrypass, seeded
fixtures. Integration tests skip when servers are down (FERRY_REQUIRE_TEST_SERVERS=1
forces failure). Rationale: real protocol servers over mocks — resume/tunnel behavior
can't be faked credibly.

## 2026-07-05 — ADR-007: Product decisions (M0)
Name **Ferry** (working; trademark check pending, user's task). One-time-purchase model.
Icon: concept A ("The Ferry", white boat on sea-teal squircle) — approved. UI mockups for
5 key screens approved, including user-requested **sync browsing** (linked panes toggle);
implementation must match `docs/design/ferry-mockups.html` (CLAUDE.md rule 3).

## 2026-07-05 — ADR-008: Credentials in Keychain only; JSON profile store carries no secrets
Profile store is versioned JSON in Application Support; secrets are Keychain generic
password items keyed by profile UUID. Works identically sandboxed and unsandboxed.

## 2026-07-05 — ADR-009: connections.json schema (v1)
Recursive tree: `ConnectionLibrary{schemaVersion, items:[SidebarItem]}` where SidebarItem
is `{"type":"folder"|"profile", ...}` via hand-written Codable (clean discriminator, no
synthesized `_0` keys — pinned by test). Dates ISO8601 (whole seconds); output
prettyPrinted+sortedKeys so identical content ⇒ identical bytes (backup/diff friendly).
Atomic writes. Loading probes schemaVersion first: newer-than-supported fails with a
precise error instead of decode garbage; older versions are the future migration hook.
Enum raw values (`TransferProtocol`, tunnel kinds) are part of the schema — never rename
without a migration.

## 2026-07-05 — ADR-010: Keychain via login keychain (not data-protection keychain)
CredentialVault uses classic SecItem generic-password items in the login keychain, WITHOUT
`kSecUseDataProtectionKeychain`. Rationale: the data-protection keychain requires a signed
app with an application-identifier entitlement, which would break `swift test` (unsigned
runner) and ad-hoc dev builds. Accessibility: `kSecAttrAccessibleWhenUnlocked`. Account
format `"<profileUUID>/<role>"` and service `com.gfragos.Ferry` are persistence contracts
(pinned by test). Revisit for the App Store build in M17 — switching stores will need a
one-time migration that reads old items and rewrites them.

## 2026-07-05 — ADR-011: SSH library spike verdict — Citadel (0.12.x) adopted
The M6 spike against the Docker OpenSSH server succeeded on every criterion: password
auth, directory listing with full attributes, stat, and chunked offset reads (byte-exact
1 MiB download). Citadel 0.12.1 (MIT) over swift-nio-ssh (Apache-2.0) is now the SSH
stack; the libssh2 fallback is retired to a contingency note in LICENSING.md.
Notes: (a) Citadel's client types predate strict concurrency — imported with
`@preconcurrency`; revisit when Citadel adopts Swift 6 Sendable. (b) Request-level SFTP
failures throw the raw `SFTPMessage.Status` (which itself conforms to Error), not always
`SFTPError.errorStatus` — `SFTPSource.mapError` normalizes both. (c) Host key validation
is `.acceptAnything()` until M11's TOFU flow — tracked as a TODO in SFTPSource, must not
ship past M11.

## 2026-07-05 — ADR-012: Browser session architecture (M7)
One `BrowserSession` per live connection holds two `PaneModel`s (local/remote) over
`FileSystemSource`s — panes are fully symmetric. All user navigation funnels through
`BrowserSession.navigate/goBack/goForward` so sync browsing can mirror it: anchors
captured when the link is enabled, relative paths recomputed via `PathUtilities`
(FerryCore, unit-tested), missing counterpart ⇒ flash + stay, navigation outside the
anchor ⇒ silently unmirrored, link kept. "Active pane" (last clicked) receives the
toolbar filter and back/forward. Single session per window until tabs (M16);
`ConnectionPhase` (idle/connecting/connected) drives the detail column. Connect is
password-auth only until M11; missing stored password prompts with remember-in-Keychain
opt-in per DOMAIN.md.

## 2026-07-05 — ADR-013: TransferEngine cancellation must not trust backend awaits (M8)
Design rule learned the hard way: a transfer task's awaits (e.g. Citadel SFTP writes) may
not be cancellation-aware, so `TransferEngine.cancel` (a) publishes the cancelled state
and frees the concurrency slot immediately, (b) cancels the task, and (c) a
`withTaskCancellationHandler` force-closes the destination write handle so pending I/O
resumes with an error instead of leaving a suspended zombie. Terminal snapshot phases are
immutable (late zombie updates ignored); write-handle `close()` is claim-once
thread-safe. Related M8 findings: AsyncStream `bufferingNewest` silently DROPS chunks —
never use it for transfer data; and Docker mountpoints inside a container path are
created root-owned, which made the SFTP upload dir unwritable (fixtures now mount at
`/fixtures`, not inside `upload/`). Also: whole-row `.draggable` swallows double-clicks
in SwiftUI Tables — the drag handle is the file icon only.

## 2026-07-05 — ADR-014: Resume & robustness design (M9)
**Resume.** Downloads always stage into `<destination>.ferrypart` and atomically rename
into place on completion (an existing, already-confirmed-for-replacement destination is
deleted just before the rename, since `rename` refuses overwrite by the M5 contract). A
partial resumes only when valid: automatic mode, non-stale (≤ 30 days — encountering a
stale partial IS the GC; openWrite truncates it away), and not larger than the source.
Uploads have no staging; a smaller existing remote file is treated as this transfer's
own interrupted partial and appended to (DOMAIN.md heuristic). Consequence: at staging
time Ferry cannot distinguish an interrupted upload from an unrelated remote file, so a
re-staged upload whose destination exists goes through the conflict Ask dialog; automatic
upload resume happens on engine retries and the queue's Resume button.
**Retry policy.** Failed items retry up to 3 attempts with 5 s spacing, resuming their
own partial data — but only for transient errors (`.io`/unknown). Deterministic errors
(notFound, permissionDenied, invalidOffset, …) fail immediately; retrying them wastes
15 s to reach the same result (and would have slowed every unit test).
**Pause.** `pause(id:)` follows the ADR-013 cancel discipline: publish `.paused` first,
then cancel the task and free the slot. A paused snapshot is *frozen* — zombie updates
from the interrupted task are ignored — and only `resume(id:)`/`cancel(id:)` transition
it (via direct publish). Resume re-queues with automatic mode, so an interrupted Replace
continues its own partial instead of starting over.
**Folder transfers.** A directory item expands lazily when it reaches the front of the
queue: create the destination directory (tolerating an existing one — a merge), list the
source, enqueue one child item per entry (files before subdirectories). Pausing a
directory row mid-enumeration and resuming re-enumerates; already-queued children may
then be transferred twice — idempotent, just wasteful, accepted for M9.
**Keep-alive/auto-reconnect.** `ConnectionSupervisor` actor: pings every 30 s
(`realpath .`), reconnects with exponential backoff (1/2/4 s, 3 attempts), streams state
to the UI (amber "Reconnecting…", red "Connection lost" + manual Reconnect). Both are
gated on the profile's single keep-alive flag per DOMAIN.md. A transfer that exhausts
its retries calls `noteFailure()` — transfer failures are the fastest drop detector.
`SFTPSource` keeps its connect parameters in memory (never persisted/logged) and
rebuilds its transport in place via `reestablish()`, so panes and queued transfers keep
working on the same source object after recovery.
**Test-infra learnings.** (a) NIOSSH `fatalError`s ("window adjust on channel in invalid
state") if the local SSHClient is closed while reads are in flight — kill-mid-transfer
tests must drop the connection server-side (`docker exec … pkill`), which is also the
realistic failure. (b) OpenSSH ≥ 9.8 session processes are named `sshd-session`, not
`sshd: user` — the pkill must match both. (c) `docker exec` costs ~300 ms, so the file
being killed mid-transfer must be big enough (32 MiB, seeded server-side with `dd`) that
the transfer is still running when the kill lands. (d) A `for await` deadline check never
fires on a silent stream — test timeouts must race a timer task, not test dates on
event arrival (the first M9 run hung forever on this).

## 2026-07-17 — ADR-015: File operations & Finder integration (M10)
**SFTP mutations completed.** `SFTPSource.rename` (Citadel `sftp.rename`) refuses to
clobber an existing destination (`.alreadyExists`, matching LocalFileSource) so the
conflict flow — not a silent overwrite — decides replacements; `setPermissions` sends a
SETSTAT with the lower-12 mode bits. The FileSystemSource mutation surface is now fully
live on both backends.
**Operations live on PaneModel**, not BrowserSession: rename/delete/applyPermissions/
previewURL act on one pane's own source and reload it, so the cross-pane concerns
(transfers, sync browsing) stay in BrowserSession. Delete continues past a per-item
failure and surfaces the last error, so one bad item doesn't strand a multi-select.
**Delete confirms, never trashes.** Both panes confirm before deleting (recursive folder
warning when a folder is in the set); the wording is explicit that items are removed on
this Mac / on the server, not moved to a Trash (there is none over SFTP).
**Quick Look.** Local files preview in place via `.quickLookPreview`; remote files are
streamed to a temp file (`FerryQuickLook/`) first, then previewed (DOMAIN.md
download-and-Quick-Look). Double-clicking a file previews it; folders still navigate.
**chmod editor** is a sheet with a 3×3 rwx grid kept in sync with an editable octal
field; available on both panes (local and remote both implement setPermissions).
**Finder drag & drop — the drag-payload split.** Local items now vend a file `URL`
(Transferable) instead of the M8 string payload, so they drag to Finder for free AND
drop onto the remote pane as an upload; remote items keep the `ferryitem|…` string
payload (no file URL exists for a remote path) and drop onto the local pane as a
download. Each pane therefore carries two `.dropDestination`s: `String` (inter-pane from
the remote side) and `URL` (Finder files + local-pane items). A URL whose parent is
already the destination directory is skipped (self-drop no-op). The icon-only drag handle
from ADR-013 is preserved. **Deferred:** dragging a *remote* item out to Finder needs an
`NSFilePromiseProvider` (download-on-drop) — backlogged, not in M10.
**Context-menu label "Delete…".** The single-item delete uses an ellipsis both because it
opens a confirmation (macOS convention) and because AppKit injects a standard Edit▸Delete
menu item — the ellipsis keeps the context item uniquely addressable for XCUITest.

## 2026-07-17 — ADR-016: Host-key TOFU via a rejecting validator + reconnect-on-trust (M11)
**The constraint.** NIO/Citadel validate the host key on the event loop *during* the
handshake (`NIOSSHClientServerAuthenticationDelegate.validateHostKey`), synchronously —
there is no way to pause for a UI prompt. So Ferry can't "ask, then continue the same
handshake."
**The design.** `TOFUHostKeyValidator` is built with the set of keys Ferry already trusts
for the endpoint (from `HostKeyStore` ∪ any session-only key). It succeeds if the offered
key is trusted, otherwise **captures the offered key and fails the handshake**.
`SFTPSource.connect` then inspects the validator: if a rejected, untrusted key was
captured it classifies the failure as `.hostKeyUnknown` (no keys stored → first contact)
or `.hostKeyChanged` (keys stored, none matched → MITM risk) and throws a `HostKeyInfo`
value. The app shows screen 3; on approval it writes the key to the store (or trusts it
for the session only) and **retries connect** — now the key is in the trusted set and the
handshake passes. This replaces the M6 `acceptAnything()` placeholder — the shipping
blocker called out since M6 is closed.
**HostKeyInfo is the currency**, not NIOSSH types: it carries the algorithm label, the
OpenSSH SHA256 fingerprint (computed like `ssh-keygen -lf`: SHA-256 over the base64-decoded
blob, base64 no-pad, via swift-crypto), and the OpenSSH one-line encoding used for storage.
The app layer never imports NIOSSH. `HostKeyStore` is a stateless persister (mirrors
ConnectionStore) over an OpenSSH-format `known_hosts` at `~/Library/Application
Support/Ferry/known_hosts`, keyed by `host`/`[host]:port`; Ferry writes only plaintext
entries. **No silent-accept path exists** (DOMAIN.md): the changed-key alarm's safe action
(Disconnect) is primary and Replace requires a second confirmation.
**Test-infra note.** OpenSSH 9.8+ `PerSourcePenalties` penalises "connections without
attempting authentication" — exactly what a TOFU rejection is (disconnect during KEX).
At the full suite's connection volume this wedged the source IP for ~15 s, so the test
container disables it via an `/etc/sftp.d` boot hook. Real servers are unaffected; a user
who repeatedly cancels a host-key prompt could in principle hit it, which is acceptable.

## 2026-07-17 — ADR-017: SSH key auth via Citadel typed keys; agent deferred (M11)
**Scope.** M11 ships password + **public-key** auth; **ssh-agent is deferred to the
post-v1 backlog** — Citadel has no agent support (it would need a custom
`NIOSSHClientUserAuthenticationDelegate` speaking the agent socket protocol), it is
sandbox-gated, and it was already backlogged. The UI's SSH-Agent option now says "planned
for a later release".
**Key formats.** Citadel parses OpenSSH-format (`-----BEGIN OPENSSH PRIVATE KEY-----`)
**ed25519 and RSA** private keys (encrypted keys via aes*-ctr + bcrypt). It has **no
OpenSSH private-key parser for ECDSA**, so `SSHKeyLoader` rejects ECDSA (and legacy PEM
containers) with a clear `unsupportedKeyType` error pointing at conversion, rather than
failing obscurely. `SSHKeyLoader` reads the (unencrypted) OpenSSH envelope header to detect
the key type and whether it's encrypted, then classifies load failures into
`passphraseRequired` / `incorrectPassphrase` / `unsupportedKeyType` / `malformed` so the
app can prompt vs. hard-fail.
**Layering.** The app reads the key file's bytes (owning sandbox / file access) and hands
`SSHAuthCredential.privateKey(pem:passphrase:)` to `SFTPSource.connect`; FerryCore does the
parsing. Passphrases follow the existing credential policy — Keychain `keyPassphrase` role,
prompt on connect when missing, remember opt-in. Key material is held in memory only, never
logged or persisted.
**Dependency.** swift-crypto (Apache-2.0) is promoted to a *direct* FerryCore dependency
(it was already transitive via Citadel) so `Curve25519`/`SHA256` name the same types
Citadel's OpenSSH initializers extend — using system CryptoKit would be a different,
incompatible type. LICENSING.md updated.
**Sandbox.** Reading `~/.ssh` key files (and, in checkpoint B, `known_hosts`/`config`) is
not permitted in the App Store sandbox by default; that access will route through the
security-scoped bookmark store / a file-import grant. The Direct build reads freely.

## 2026-07-17 — ADR-018: known_hosts pre-trust + `~/.ssh/config` import (M11 checkpoint B)
**known_hosts pre-trust.** The user's `~/.ssh/known_hosts` is read (never written) as an
extra trust source so hosts they already know skip the TOFU prompt. `KnownHostsFile` is a
**read-only** value type separate from `HostKeyStore` — this keeps `HostKeyStore`'s
invariant ("Ferry writes only its own plaintext file") intact. It parses both plaintext
specs (`host`, `[host]:port`, comma lists) and **hashed** entries
(`|1|<b64 salt>|<b64 hash>`), matching hashed hosts by recomputing
`HMAC-SHA1(key: salt, msg: hostspec)` via swift-crypto — pinned against `ssh-keygen -H`
vectors in tests. `SFTPSource.connect` unions its keys into the TOFU validator's trusted
set **and** into the changed-vs-unknown decision, so a system-known host offering a new key
is correctly flagged CHANGED, not unknown. The file text is frozen in `Parameters` at
connect so auto-reconnect re-validates identically. The app re-reads the file at each
connect (picks up hosts added via `ssh`); overridable via `FERRY_SYSTEM_KNOWN_HOSTS`.
**`~/.ssh/config` import.** `SSHConfigParser` lifts concrete `Host` blocks into
`ConnectionProfile`s (SFTP; `HostName`→host with alias fallback, `Port`, `User`,
`IdentityFile`→`.publicKey` tilde-expanded). Deliberately narrow: wildcard/negated patterns
are skipped (they're defaults, not endpoints), `Match` and other non-`Host` blocks end the
current host, and `ProxyJump`/`ProxyCommand` are ignored (imported without a tunnel). No
secrets are read from the config — passphrases/passwords follow the credential policy
(prompted on first connect). Imported hosts land under a fresh "Imported" folder.
Overridable via `FERRY_SSH_CONFIG`.
**UI sign-off (rule 3).** The import flow is **net-new UI, not in the approved mockups** —
signed off by the user (2026-07-17): a sidebar-toolbar Import menu → a checklist sheet
(`SSHImportSheet`). It is mirrored by a **File ▸ Import from SSH Config…** menu command
(⌘⇧I), which is the canonical entry — SwiftUI folds the sidebar toolbar's third control
into the standard toolbar overflow (››) on narrow windows, and every toolbar action should
have a menu-bar equivalent anyway. Success/empty outcomes surface via a neutral notice
alert (distinct from the "Not yet available" stub-feature alert).
**Sandbox.** Same as ADR-017: the Direct build reads `~/.ssh/known_hosts` and
`~/.ssh/config` freely; the App Store build resolves the sandbox container home (no
`~/.ssh` there), so both features **degrade gracefully to empty** — pre-trust simply
doesn't apply (TOFU behaves as before) and import reports nothing found. Routing `~/.ssh`
access through the bookmark store in the App Store build is deferred to the broader sandbox
work (M17).

## 2026-07-18 — ADR-019: FTP/FTPS via system libcurl (M12)
**Library.** FTP/FTPS is implemented over the **system libcurl** (`/usr/lib/libcurl`,
curl license — MIT-like), nothing bundled (ADR-003). macOS ships a capable libcurl
(8.7.1, `ftp ftps` + SSL). This closes the FTP half of the protocol matrix without a new
third-party dependency or a notarization/App-Store concern (system dylib).
**C binding.** A tiny SwiftPM C target **`CFTP`** wraps libcurl. Its only reason to exist:
`curl_easy_setopt`/`curl_easy_getinfo` are **C variadic** functions, which Swift cannot
call — so `CFTP` exposes typed, non-variadic `ferry_setopt_long/string/off/slist`,
callback setters (`ferry_set_write_cb`/`read`/`header`), and a few macro/enum values
(`CURL_ERROR_SIZE`, `CURLUSESSL_ALL`, `CURL_READFUNC_ABORT`, `curl_global_init`) as
functions. Everything else in libcurl (init/perform/cleanup/slist/strerror) is a normal
function Swift imports directly. `CFTP` links `curl` via `.linkedLibrary("curl")`;
FerryCore depends on it. `FTPSource` uses `@convention(c)` closures (no captures) for the
write/read/header callbacks, bridging to Swift context via `Unmanaged` `void*` userdata.
**No persistent session (per-operation handles).** FTP's control connection can't
multiplex, so unlike `SFTPSource` there is **no long-lived session object** — every
operation drives its own libcurl "easy" handle (its own control + data connection). This
makes concurrent transfers (3/connection) trivially correct: each runs on its own handle
and its own detached thread, with zero shared mutable curl state. The cost is a login per
operation; acceptable for v1. Connection pooling via a `CURLSH` share handle is a backlog
optimization. libcurl's blocking `curl_easy_perform` **always** runs on a detached
`Thread` so the actor's cooperative executor is never blocked; upload backpressure
(`FTPUploadHandle`) offloads its blocking wait to a thread too.
**Streaming bridges.** Download is push→push: libcurl's write callback (on the perform
thread) yields into an `AsyncThrowingStream` (unbounded, like the other backends);
cancellation returns a short count to abort. Upload is push→pull: the engine's
`write`/`close` feed a bounded (512 KiB) `NSCondition`-guarded buffer that libcurl's read
callback drains — this is the backpressure that stops a fast local read from ballooning
memory ahead of a slow upload. `close()` = EOF (flush remaining, then the read callback
returns 0); a transfer error unblocks a stalled writer.
**Absolute paths.** libcurl treats a URL path as *relative to the login directory*; the
documented way to anchor at the server root — where Ferry's absolute paths live — is to
encode the leading slash as `%2F`. So `FTPSource` builds `ftp://host:port/%2F<encoded
path>` (segments percent-encoded, `/` kept). `homeDirectory` parses the `257 "<path>"`
reply to a `PWD` quote command from the control channel (for FTP, libcurl routes control
responses to the header callback). There is **no `stat` in FTP**, so `FTPSource.stat`
lists the parent directory and matches by name (root is synthesized); the `LIST` line
carries type/size/perms/owner — everything `FileItem` needs.
**LIST parsing.** The fragile seam of any FTP client. `FTPListParser` parses the Unix
`ls -l` dialect (vsftpd/proftpd/pure-ftpd) into `FileItem`s — pure and unit-tested against
pinned samples (dirs, symlinks `name -> target`, names with spaces, setuid/setgid/sticky
bits, `total N` headers). Dates are **best-effort**: `LIST` timestamps are server-local, at
minute (recent) or year (old) resolution with no offset, so `modifiedAt` is approximate
(precise times would need per-file `MDTM` — backlog). Raw MS-DOS listings are not parsed
(the servers Ferry targets emit Unix).
**Mutations.** `MKD`/`DELE`/`RMD`/`RNFR`+`RNTO`/`SITE CHMOD` via `CURLOPT_QUOTE`;
`createDirectory` creates intermediates root-down and `rename` refuses to clobber, both
matching the SFTP contract. Resume: download uses `CURLOPT_RESUME_FROM_LARGE` (`REST`),
upload uses `CURLOPT_APPEND` (`APPE`) — since FTP can't truncate, upload resume **requires
the remote size to equal the offset** (the engine always computes offset = remote size, so
this holds), else `.invalidOffset`. `CURLOPT_FTP_SKIP_PASV_IP` reuses the control IP (NAT/
Docker advertise unroutable PASV addresses).
**FTPS / TLS.** Three postures (`FTPSecurity`): `.none`, `.explicit` (`AUTH TLS` via
`CURLUSESSL_ALL`, the modern default), `.implicit` (`ftps://` scheme, TLS from byte one).
The app derives the posture from scheme + port: `.ftps` on **990 = implicit**, any other
port = **explicit** (990 is the IANA implicit-FTPS port; a documented heuristic that needs
no model/UI change). Certificates are verified against the **system trust store by
default** (`allowInvalidCertificate` exists in FerryCore for the self-signed test server
only). A certificate-**trust prompt** (the TLS analogue of host-key TOFU, for self-signed/
private-CA FTPS servers) is deliberately **out of M12 scope** — the app surfaces a clear
`.tlsFailed` error and it is a backlog item, mirroring how ssh-agent was split off in M11.
**App layering.** `BrowserSession` was generalized from a concrete `SFTPSource` to
`any FileSystemSource & SupervisedConnection`, and `SupervisedConnection` gained
`disconnect()`, so the session is backend-agnostic. `SFTPSource` and `FTPSource` both
conform; SCP (M13) will slot in the same way.
**Test infra.** A **second** vsftpd service (`ftps`, :2990) with a self-signed cert added
to docker-compose — TLS-enabled vsftpd forces SSL for logins, so it can't also serve the
plaintext `ftp` (:2121) service. Its config sets `require_ssl_reuse=NO`: vsftpd defaults to
requiring the data channel to resume the control channel's TLS session, which TLS 1.3 and
macOS's SecureTransport libcurl don't do — turning it off makes the server lenient like a
well-configured real FTPS server. Cert generated by `start.sh` into `fixtures/certs`
(gitignored). **Re-run `testinfra/start.sh` after pulling M12.**
