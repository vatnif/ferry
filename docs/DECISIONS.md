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

## 2026-07-18 — ADR-020: SCP over an SSH exec channel (M13)
**Backend.** SCP is implemented as `SCPSource` (a `FileSystemSource` + `SupervisedConnection`
actor) over the M11 SSH stack (Citadel), reusing the exact host-key TOFU + password/key auth
as SFTP. No new third-party dependency.
**Split surface (the core mapping problem).** The classic scp wire protocol transfers only
file bytes — it has no listing, stat, mkdir, delete, rename, or chmod. So `SCPSource` runs
two mechanisms: **metadata via POSIX commands over an SSH exec channel** (`pwd`, `ls -la`,
`ls -ld`, `mkdir -p`, `rm -rf`, `mv`, `chmod`) and **bytes via the real scp protocol**
(`scp -f` for download, `scp -t` for upload). `ls` output is parsed by the existing Unix
`ls -l` parser (`FTPListParser` — the FTP `LIST` dialect is the same; reused as-is despite
the FTP-prefixed name). Every path is single-quoted + `--` to block shell/option injection
(sshd runs exec through the login shell).
**Bidirectional exec ⇒ macOS 15.** The scp protocol is a lock-step exchange over stdin+stdout,
which needs Citadel's `withExec` (bidirectional exec channel). That API is **`@available(macOS
15.0, *)`**, and Citadel's channel/session internals aren't public, so there is no macOS-14
path. Per the user's decision (2026-07-18), SCP is **gated to macOS 15+** rather than bumping
the whole app's deployment target off macOS 14: `SCPSource` is `@available(macOS 15)`, the app
blocks an SCP connect on macOS 14 with a clear message, and SFTP/FTP/FTPS are unaffected. SCP
is the least-used protocol, so the limitation is narrow. Metadata commands
(`executeCommandStream`) are macOS-14-capable; only transfers force the gate.
**Capability compromises (documented in DOMAIN.md → SCP).** SCP has no seek and cannot
append, so **there is no transfer resume**: a resumed download re-reads from the start
(byte-exact, but the stream discards the pre-offset bytes so it still begins at `offset`), and
a resumed upload is rejected (non-zero offset → the engine restarts). Upload needs the size
declared up front, which the streaming `openWrite` contract doesn't give, so the write handle
**buffers to a local temp file** and transfers on `close()`, **staging to a remote
`.ferry-scp-part` file renamed into place on success** — so an interrupted upload never leaves
a partial at the destination (which would make the engine's retry request a non-zero offset
SCP can't honour).
**withExec error masking.** Citadel's `withExec` runs `channel.close()` in its cleanup; when
the remote scp has already exited, that throws "Already closed" and **masks** an error thrown
from inside the closure. So neither protocol driver throws through `withExec`: the download
driver reports its outcome through the stream continuation, the upload driver through an
out-of-band `UploadOutcome` (with an explicit `completed` flag so a clean close after a
*successful* upload isn't mistaken for a failure). Errors are classified from the scp status
bytes (`\x01`/`\x02` messages) and, as a fallback, drained `stderr`.
**Shared SSH connect.** The host-key TOFU + auth + error-classification logic was extracted
from `SFTPSource` into `SSHClientFactory` (+ a shared `SSHConnectionParameters`), now used by
both SFTP and SCP — one audited place for the security-critical trust decision.
**Test infra (deviation from the milestone brief).** The brief assumed SCP could be tested
against the existing atmoz/sftp server; it can't — atmoz forces `internal-sftp` (blocks exec)
**and ships no scp binary**. So a purpose-built exec-capable OpenSSH container was added
(`testinfra/ssh-exec`, :2223) with the **same** ferry/ferrypass creds + client key, so the
app's auth paths are identical. It also serves future exec-based features (M15). **Re-run
`testinfra/start.sh` after pulling M13** (it builds the new image).

## 2026-07-18 — ADR-021: Tunneling — TunnelEngine, forwarding modes, sandbox (M14)
**Citadel forwarding capabilities (the milestone's main risk — investigated first).** In
Citadel 0.12.1 the only client-side forwarding primitive that's public is
`SSHClient.createDirectTCPIPChannel` (a `direct-tcpip` channel — outbound TCP through the
server). **Remote forwarding** (the `tcpip-forward` global request + server-opened
`forwarded-tcpip` channels) is not reachable: `SSHClient.session` is `private(set)`/internal,
so the underlying `NIOSSHHandler.sendTCPForwardingRequest` (which exists in swift-nio-ssh) can't
be called, and the inbound-channel registration is internal too. **SOCKS** isn't in Citadel at
all.
**Modes shipped (user decision 2026-07-18).**
- **Local** — a loopback `ServerBootstrap` listener; each accepted connection opens a
  `direct-tcpip` channel to a fixed destination reachable from the server.
- **SOCKS** — same listener, but a per-connection SOCKS5 (RFC 1928, CONNECT only, no-auth)
  handshake picks the target, which is then reached via `direct-tcpip`. Ferry implements the
  SOCKS server itself (`SOCKSProxy` pure parser + `SOCKSServerHandler`).
- **Remote — deferred to backlog.** With no public Citadel API and no macOS-14-safe way to drop
  to NIOSSH without vendoring a Citadel patch, remote forwarding is deferred with the user's
  sign-off. It stays a **savable/editable** tunnel type (the mockup shows a Remote row), but
  starting one reports `failed("Remote port forwarding isn't supported yet.")`. This is a
  deviation from mockup screen 4's live Remote row — recorded here per rule 3.
**Not macOS-15-gated (unlike SCP).** `direct-tcpip` needs no `withExec`, so `TunnelEngine`
works on macOS 14. Only SCP byte transfers force the macOS 15 gate (ADR-020).
**Single event loop + glue.** The engine, its SSH channel, every `direct-tcpip` forward, and
the listener sockets all run on **one dedicated single-thread `MultiThreadedEventLoopGroup`**
(threaded through a new optional `group:` param on `SSHClientFactory.connect`). That co-location
is what lets a `GlueHandler` pair splice a local connection to its SSH channel by touching both
`ChannelHandlerContext`s directly (the canonical swift-nio glue: backpressure via read-gating,
half-closure, teardown). **Ordering matters:** the local-side glue is installed *before* the SSH
channel is created so the server's opening bytes aren't dropped; for SOCKS the SSH channel's
reads are held (autoRead off) until the success reply is sent, then both sides are primed.
**Dedicated tunnel session (not shared with the browser).** `TunnelEngine` opens its **own** SSH
session via `SSHClientFactory` — identical host-key TOFU + auth, reusing the already-resolved
credential so there's no second prompt — rather than sharing `SFTPSource`/`SCPSource`'s private
`SSHClient`. Rationale: decoupled lifecycle (tunnels don't depend on what's being browsed, or on
SFTP-vs-SCP), and it matches how each SSH backend already owns its client. The connection is
lazy — the session is only opened when a tunnel actually starts, so it's free when a profile has
no enabled tunnels. A full multiplexed `SSHSessionManager` (one session for SFTP + tunnels +
exec, as ARCHITECTURE.md aspires to) is left as future work.
**Sandbox — network.server added (user decision 2026-07-18).** Local & SOCKS forwards bind a
loopback listener socket and *accept* connections, which the App Sandbox permits only with
`com.apple.security.network.server`. It was added to `Ferry-AppStore.entitlements`; the Direct
build is unsandboxed. Remote forwards would listen on the server, needing nothing here (moot
while deferred). DOMAIN.md → Sandbox strategy updated (it previously reasoned only about remote
tunnels).
**Schema — one additive, backward-compatible profile field.** `TunnelConfiguration` (fixed in
M2) needed no change. `ConnectionProfile` gained `autoStartTunnels: Bool?` (nil ⇒ treated as
true) to back screen 4's "start automatically on connect" checkbox. It's optional, so profiles
written before M14 still decode — **no `connections.json` schemaVersion bump**.
**New UI beyond the mockups (signed off).** Screen 4's manager table is implemented as drawn;
the **tunnel add/edit form** (`TunnelEditorSheet`) behind its Add/Edit buttons isn't in the
mockups — approved as the natural editor, recorded here per rule 3.
**Test infra.** No new container: the M13 exec server (`testinfra/ssh-exec`, :2223) already has
`AllowTcpForwarding yes`. Integration tests prove a real round trip by forwarding to the
server's own sshd (`127.0.0.1:22`) and reading the SSH banner back through the tunnel (local +
SOCKS), plus port-in-use, stop-releases-port, auto-start, and remote-unsupported.

## 2026-07-18 — ADR-022: Remote port forwarding via Citadel's public API (M14.5)

**Supersedes the "Remote — deferred to backlog" portion of ADR-021.**

**Premise correction.** ADR-021 recorded that Citadel 0.12.1 exposes no client
`tcpip-forward`. That was wrong for the exact revision pinned in `FerryKit/Package.resolved`
(`ae8562f`): Citadel 0.12.1 merged a full public remote-port-forward client API (its PR #127)
— `SSHClient.withRemotePortForward(host:port:onOpen:handleChannel:)` and higher-level
variants — riding the **Wellz26/swift-nio-ssh 0.3.6 fork** that `Package.resolved` already
pins (Citadel switched to the fork for Mac Catalyst compatibility). LICENSING.md previously
recorded the transport as "swift-nio-ssh (apple)" — corrected; the fork's LICENSE.txt is
still Apache-2.0. No vendoring, forking, or dropping to raw NIOSSH was needed.

**Supply-chain note.** The capability (`NIOSSHHandler.sendTCPForwardingRequest` + the typed
`GlobalRequest` API) lives in the non-Apple fork. If Citadel ever re-pins Apple upstream,
verify the API shape survives before taking the update.

**Entry point: the low-level closure form.** Rejected alternatives: the `NIOAsyncChannel`
variant wraps the raw channel as `ByteBuffer` without installing any codec (unsound by
default), and `runRemotePortForward` pipes connections internally, hiding the per-connection
channels the status column's live count needs. The low-level form hands each server-opened
`forwarded-tcpip` channel to the engine, which reuses the M14 `GlueHandler` splice and
connection counting unchanged.

**Own codec.** `forwarded-tcpip` channels arrive speaking `SSHChannelData`; Citadel installs
its `DataToBufferCodec` only on `direct-tcpip` channels and keeps it internal, so FerryCore
carries `SSHChannelDataCodec` (~30 lines, same translation).

**Registry matching ⇒ fixed listen port.** Citadel dispatches inbound `forwarded-tcpip`
channels by matching the server-reported `(listeningHost, listeningPort)` against the
*requested* pair. OpenSSH echoes the requested host string verbatim and reports the actual
bound port — so `listenPort == 0` ("let the server choose") could never dispatch and is
rejected as invalid configuration. A non-OpenSSH server that rewrites the host string would
fail to dispatch (connections rejected, count stuck at 0) — accepted limitation.

**Lifecycle.** `withRemotePortForward` blocks until its task is cancelled; cancellation
sends the protocol-level cancel request before the task finishes. The engine stores a
`Task` per remote tunnel; `stop()` cancels and awaits it — bounded at 3 s, because a
half-dead session could stall the cancel round-trip — so the server-side port is
deterministically released on the happy path. A denied `tcpip-forward` (port busy on the
server, forwarding disabled) throws `NIOSSHError` (`.globalRequestRefused`) before `onOpen`
and maps to a clear "server refused" status message.

**Session drop.** A remote forward otherwise sleeps obliviously if the SSH session dies,
leaving a misleading "forwarding" status, so `ensureConnected` now registers
`SSHClient.onDisconnect`: remote tunnels fail immediately ("The SSH session dropped.").
Local/SOCKS listeners deliberately keep their existing behavior (listener stays up; bridges
fail per-connection and a fresh session is dialed lazily) — recorded asymmetry.

**Test infra.** `testinfra/ssh-exec/sshd_config` gains `GatewayPorts clientspecified` and
compose maps `127.0.0.1:2224 → container :18080`, so the round-trip test reaches the
forwarded listener from the host: host :2224 → sshd's `0.0.0.0:18080` listener →
`forwarded-tcpip` → engine → host-mapped sshd :2223 → `SSH-2.0` banner. Rebuild the image
with `docker compose up -d --build ssh`.

**UI.** The editor's "Remote isn't supported yet" warning — ADR-021's recorded deviation
from mockup screen 4 — is removed; Remote rows now behave exactly as mocked (this closes
the deviation rather than adding one). Still not macOS-15-gated (no `withExec` involved).

## 2026-07-18 — ADR-023: Embedded terminal — SwiftTerm, `withPTY`, dedicated session (M15.5)

**Status: approved 2026-07-18** (checkpoint A review, two rounds — the second added the
pop-out window, terminal-only connections, and the scope fence, all recorded below).
Mockup tab 7 / DESIGN.md screen 7 are part of the binding UI contract (rule 3).

**Milestone placement.** Backlog item 6 pulled forward as **M15.5** (after M15, before
M16), per the approved planning session (2026-07-18): both technical risks were retired
during planning, it shares seams with M15 (same Terminal button + dispatch setting) and
M16 (the Settings ▸ Terminal tab renders one picker, once), and it is the App Store
build's only possible terminal story (M15's hand-off is Direct-only).

**Emulator: SwiftTerm (MIT), verified.** LICENSE file checked (MIT); its Package.swift
dependencies (swift-argument-parser, swift-docc-plugin, package-benchmark) attach only
to executable/doc/benchmark targets, not the `SwiftTerm` library product Ferry links —
LICENSING.md updated when the dependency lands (pin ≥ 1.14.0). The core emulator is
pure — `TerminalView` (NSView) + `TerminalViewDelegate` (`send` = keystrokes out,
`sizeChanged` = resize out, `feed` = bytes in); `LocalProcess` (pty fork/exec) is an
optional class Ferry never uses, so the App Store sandbox is unaffected (proven by
sandboxed SwiftTerm apps: Secure ShellFish, La Terminal). Tools-version 5.9 ⇒ compiles
in Swift 5 mode under Ferry's Swift 6 app. It attaches via a new FerryKit library
product **`FerryTerminalUI`** (NSViewRepresentable host + delegate bridge), keeping
`FerryCore` UI-free; one pbxproj product-dependency addition.

**Shell channel: Citadel's public `withPTY` — macOS 15 gate accepted (ADR-020
precedent).** The pinned Citadel 0.12.1 (rev ae8562f) ships
`SSHClient.withPTY(request:environment:perform:)` (pty-req + shell; `TTYStdinWriter`
carries `write` and `changeSize` → `WindowChangeRequest`, so resize works natively).
Like `withExec`, it is `@available(macOS 15, *)` — the gate sits on
`TTYOutput: AsyncSequence`, and no public macOS-14 path exists (`SSHClient.session` is
internal; `executeCommandStream` has no stdin/resize). Forking Citadel to lower the
gate was rejected (it is upstream orlandos-nl — unlike the already-forked
swift-nio-ssh, ADR-022's supply-chain note). So the **embedded terminal requires
macOS 15**, surfaced in Settings/UI with a clear explainer; SFTP/FTP/FTPS and the
macOS 14 deployment target are unaffected. The `withPTY` cleanup inherits `withExec`'s
"Already closed" error masking — the terminal driver reports its end state out-of-band
(the SCPSource `UploadOutcome` pattern), never through `withPTY`'s throw.

**Session strategy: dedicated SSH session per terminal** via `SSHClientFactory`
(ADR-021 pattern): identical host-key TOFU + auth, reuses the connection's resolved
credential (no second prompt, rule 6), decoupled lifecycle; Citadel's `.singleton`
event-loop group (no cross-channel splicing, unlike tunnels). The multiplexed
`SSHSessionManager` stays backlogged. Terminal bytes are never logged; scrollback is
in-memory only (SwiftTerm's buffer).

**Embedded vs OS terminal — one setting, one button** (user proposal, adopted): the
screen-1 Terminal toolbar button dispatches on Settings ▸ Terminal — "Ferry's built-in
terminal" (default on macOS 15+) opens the embedded panel; Terminal.app / iTerm2 /
custom command keep M15's external hand-off. APPSTORE builds hide the external options
(`#if !APPSTORE`, DOMAIN.md); on macOS 14 built-in is disabled with "Requires macOS 15"
(Direct falls back to Terminal.app). Scope: SSH profiles only (SFTP/SCP) — FTP/FTPS
show no Terminal button (like Tunnels); remote shells only, no local-shell mode.

**Pop-out window + terminal-only connections** (user additions at checkpoint A review,
2026-07-18): the panel header gains ⧉, which re-hosts the *same live* SwiftTerm view in
a per-connection window (session + scrollback intact — the `TerminalSession`/view split
makes this cheap); "⇤ Dock in Window" reverses it; a popped-out window survives its
browser tab (it owns its dedicated session). Building on that window, a profile
context-menu item **Open Terminal** (SSH profiles only) opens a shell *without*
connecting the browser — honoring the same dispatch setting (built-in → the standalone
window with re-dock hidden; external → M15 hand-off) and reusing the normal connect
flow's TOFU + credential resolution. Ferry's profiles thereby double as terminal
bookmarks without a second connect UI.

**Scope fence** (recorded to keep the terminal from creeping into an iTerm2 competitor):
deliberately **no** terminal tabs, split panes, color themes, or keybinding editors —
font and scrollback settings only. Revisiting this fence requires a new ADR.

**Sequencing note (checkpoint C, M15.5 shipped before M15/M16).** Because the external
hand-off (M15) and the settings window (M16) don't exist yet, the built-in terminal is
the **only** dispatch target for now: the toolbar button and Open Terminal menu item
open it directly, and on macOS 14 they explain "requires macOS 15" with no external
fallback until M15 lands. The Settings ▸ Terminal picker (built-in/external) and the
scrollback-lines setting arrive with M16 (scrollback needs care: SwiftTerm recomputes
`TerminalOptions` on every resize, discarding a custom value). Terminal-only connects
run `TerminalSession.preflight` (public FerryCore API added for this) so TOFU/auth
prompts fire through the normal connect flow BEFORE a window opens. One deviation from
mockup note 7: closing a terminal *window* ends the shell without a confirm — SwiftUI
provides no clean window-should-close hook; the docked panel's ✕ does confirm while the
shell is live. **Build prerequisite**: SwiftTerm's Metal shader needs the Xcode Metal
toolchain component (BUILDING.md).

## 2026-07-19 — ADR-024: Open in Terminal — external hand-off, launch mechanism, storage-only setting (M15)

**Placement in the ADR-023 dispatch.** M15.5 shipped before M15 (ADR-023's sequencing
note) and left the built-in terminal as the *only* dispatch target. M15 adds the external
branch behind the terminal-choice setting, closing that gap: the one Terminal toolbar
toggle and the one sidebar "Open Terminal" item now dispatch on the setting — built-in →
the embedded panel/window (M15.5); Terminal.app / iTerm2 / custom command → an external
hand-off (this ADR). One button, one setting, exactly as ADR-023 designed.

**The command is built, not the credential resolved.** The external path never touches
`resolveCredential` / the Keychain / the host-key prompts. It builds an `ssh` command from
the profile (host, port, user, `-i <keyfile>` for key auth) and launches it — **passwords
are never passed** (rule 6): a password profile relies on ssh prompting in the terminal.
And **ssh does its own host-key TOFU against the user's `~/.ssh/known_hosts`**, independent
of Ferry's `known_hosts` store — documented in DOMAIN.md so the two trust stores aren't
conflated. Honors the profile's remote start path via `-t 'cd '<path>'; exec $SHELL -l'`.

**Pure/impure split (what's tested).** All the injection-critical string work is pure
FerryCore and unit-tested (`SSHCommandBuilder`): shlex-style shell quoting (the SCPSource
precedent, ADR-020 — quote only when a conservative safe set is exceeded; embedded single
quotes via the `'\''` idiom), tilde expansion against an injected home, and AppleScript
string-literal escaping. The dispatch *decision* is also pure and exhaustively tested
(`TerminalDispatch.resolve` — the built-in/external/unavailable matrix across macOS 14/15
× Direct/App Store). Only the actual app-launching (`ExternalTerminalLauncher`, app target)
is not headless-testable (TESTING.md) — it is a thin shell over the tested builders.

**Launch mechanism (the decision).** Terminal.app and iTerm2 are driven by **AppleScript
via `NSAppleScript`** (`Terminal`: `do script`; `iTerm`: `create window … / write text`);
the custom command runs via **`Process` → `/bin/zsh -lc "<launcher> <ssh command>"`**.
- *Rejected — temp `.command` file + `open`*: works for Terminal.app but `open -a iTerm
  foo.command` does not make iTerm *run* the command, so it can't cover both named apps;
  and it litters a temp file. AppleScript is the one mechanism that uniformly makes both
  named terminals **execute** the ssh command (not merely open the app).
- *Rejected — `NSWorkspace.openApplication`*: launches the app but can't tell it to run a
  command.
- The Direct build is unsandboxed, so all of these are viable; AppleScript's first send
  triggers a one-time TCC "control Terminal/iTerm" consent prompt — acceptable for a
  Direct-only capability. (A future notarized hardened-runtime build will want the
  `com.apple.security.automation.apple-events` entitlement + `NSAppleEventsUsageDescription`
  — noted for M17; not needed for ad-hoc dev builds.)
- **Custom command semantics** (mockup tab 7: "receives the ssh command"): the built,
  shell-quoted ssh command is **appended** to the user's launcher and run through a login
  shell (`-lc`, so PATH resolves Homebrew-installed terminals). Simple, predictable,
  unit-testable; power users craft a launcher that consumes the appended args.

**Setting is storage-only for M15 (user decision 2026-07-19).** The Settings window is an
M16 deliverable and the Settings ▸ Terminal picker is already mocked (tab 7) — building an
interim Settings UI now would either be throwaway or pre-empt M16's window, and needs
fresh mockup sign-off (rule 3). So M15 persists the choice in `UserDefaults`
(`terminalPreference` + `terminalCustomCommand`, raw values pinned by a test), changeable
via `defaults write com.gfragos.Ferry …` until M16 renders the approved picker over the
same storage. **No new UI** ⇒ no mockup deviation.

**Defaults from one static value.** The stored default is always `builtIn`; the resolver
maps `builtIn` + macOS 14 + Direct → Terminal.app and `builtIn` + macOS 15 → the embedded
terminal, so the ADR-023 defaults hold with no version-dependent stored default. On macOS
14 the App Store build (no external option) still reports "requires macOS 15"; the Direct
build now falls back to Terminal.app instead of erroring — this is the ADR-023 "no fallback
until M15" gap closing.

**App Store safety (rule 5).** `ExternalTerminalLauncher` is entirely `#if !APPSTORE`;
`TerminalLaunchService.dispatch()` passes `externalAllowed = false` in the App Store build,
so every external preference degrades to the built-in terminal (or the macOS-15 explainer)
— the external options never reach a launcher that isn't compiled in.

## 2026-07-19 — ADR-025: Settings window, net-new tabs, scrollback, appearance (M16 checkpoint A)

**Status: approved 2026-07-19** (checkpoint split + tab designs signed off). This ADR
covers the Settings window shell and the settings whose *UI* is net-new (rule 3);
ADR-026 covers the transfer-policy semantics.

**Settings scene.** A standard SwiftUI `Settings { }` scene (app menu / ⌘,) renders the
icon tab strip General · Transfers · Keys · Terminal · Advanced (DESIGN.md screen 5). Every
control is `@AppStorage`-backed over keys centralized in FerryCore `AppSettings` (raw key
strings + defaults + typed enums, pinned by `AppSettingsTests`), so the app's bindings and
the models that read settings at runtime share one contract. The two terminal keys keep the
exact strings M15 shipped (`ADR-024`).

**Terminal tab (approved mockup tab 7) wired reactively.** The built-in/Terminal.app/iTerm2/
custom picker binds to the existing `terminalPreference`/`terminalCustomCommand` storage; the
browser toolbar's Terminal control now reads the same keys via `@AppStorage` so it
re-resolves its dispatch the instant the picker changes (M15 left it storage-only/
non-reactive). macOS 14 disables built-in with the "Requires macOS 15" explainer; the three
external options are hidden in APPSTORE builds (`TerminalLaunchService.externalAllowed`).
Added **font (family + size)** and **scrollback**, applied live to open terminals.

**Scrollback — the ADR-023 caveat is retired.** ADR-023's checkpoint-C note warned that
SwiftTerm recomputes `TerminalOptions` on every resize, discarding a custom scrollback. That
is **outdated for the pinned SwiftTerm 1.14.0**: `Terminal.resize` only updates `options.cols/
rows` and never resets `options.scrollback`, and 1.14.0 exposes a public `changeScrollback(_:)`
(updates `options.scrollback` + resizes the normal buffer). So the built-in terminal sets
scrollback via `TerminalSessionBridge.applyScrollback` on view creation and **re-asserts it in
the bridge's existing `sizeChanged` hook** — making the guarantee Ferry's own, not the
library's, robust to any future regression. Pinned by a `TerminalSessionBridgeTests` case
(set → resize → still set). Font resolves through `TerminalAppearance.font` (family manager →
system monospaced fallback) so an unknown family never yields a proportional font.

**Appearance via `NSApp.appearance`, not `preferredColorScheme`.** Light/Dark/System is
applied app-wide through AppKit (`NSApp.appearance = .aqua / .darkAqua / nil`) from the main
window's `onAppear`/`onChange`. SwiftUI's `preferredColorScheme` applied at the WindowGroup
root **re-creates the window and breaks XCUITest's launch snapshot** (the previously-green
`testAppLaunchesWithSidebarAndEmptyState` failed until this was changed) — AppKit is the
robust whole-app override and sidesteps that.

**Net-new tabs (rule 3 — signed off, drawn into `ferry-mockups.html` screen 5).**
- *General*: default local folder (feeds `BrowserSession`'s local start-path fallback),
  appearance, and **reopen last connections** — the open-connection profile IDs are persisted
  on `connectionPhase` transitions and restored from the main window's `onAppear` (skipped
  under `FERRY_DATA_DIR` test isolation). Stored as an *array* so tabs (checkpoint B) restore
  several; today at most one.
- *Keys*: lists `~/.ssh` public keys (read-only; empty in the sandbox, like M11's known_hosts/
  config reads — ADR-017); **Generate…**/**Import…** are Direct-only (`#if !APPSTORE`,
  `ssh-keygen` / copy-into-`~/.ssh`) and shown disabled in APPSTORE; ssh-agent stays disabled
  ("planned", ADR-017); **Manage known hosts** lists/forgets entries in Ferry's own store via
  a new `HostKeyStore.allTrustedHosts()`.
- *Advanced*: logging level over a small `FerryLog` (`os.Logger` gated by the level; secrets/
  terminal bytes never logged, rule 6) with "Reveal Logs…" → Console; an experimental-features
  flag (persisted; gates nothing yet).

**Settings-window automation.** The SwiftUI `Settings` scene does not open under XCUITest in
this harness (neither ⌘, nor the app-menu item routes to it via automation, though both work
for real users). Following the M15 precedent for non-automatable UI, the Settings window is
covered by a **manual checklist in TESTING.md**; the settings *logic* is unit-tested
(`AppSettingsTests`, `HostKeyStoreTests`, `TerminalSessionBridgeTests`).

## 2026-07-19 — ADR-026: Transfer settings become user-configurable; conflict/interrupted policies (M16 checkpoint A)

**What was hard-coded, now a setting.** `BrowserSession` created `TransferEngine(maxConcurrent:
3)` with the engine's other tunables at their defaults. It now reads a `TransferSettingsSnapshot`
(from `UserDefaults` via the `AppSettings` keys) at connection time for **simultaneous transfers**
and **retry count**, and at each *staging* call for the **exists** and **interrupted** policies
(so a policy change applies to the next transfer immediately — "Changes apply immediately").
`retryCount = N` maps to `maxAttempts = N + 1` ("retry N times" = N retries after the first
attempt); the 5 s spacing stays fixed copy (not user-facing in v1).

**Exists policy (Overwrite / Ask / Skip / Rename).** M8/M9 only implemented **Ask** (the per-file
conflict dialog) with the presets deferred to here (DOMAIN.md). `stageTransfers`/`importFiles` now
resolve the policy: Overwrite enqueues with `.restart`; Ask returns the conflicts for the existing
dialog; Skip drops them; **Rename** enqueues a `name 2.ext` copy via the pure, unit-tested
`TransferNaming.deduplicatedName` (Finder-style: suffix before the last extension; dotfiles and
extension-less names get a trailing " N").

**Interrupted policy (Resume / Ask / Restart).** Governs a download with a resumable `.ferrypart`
and no final file (uploads with a smaller remote file are a *conflict*, handled by the exists
policy). Resume → `.automatic` (M9 behavior); Restart → `.restart`; **Ask** → the item is returned
as a `ResumeDecision` and the browser prompts Resume / Resume All / Start Over / Skip. The
resume-decision alert is presented only after any conflict alert is cleared, so one alert shows at
a time. `resumablePartialBytes` mirrors the engine's validity rule (fresh ≤ 30 days, non-empty, not
larger than source).

**Queue-done notification.** When the queue drains after a completion and the setting is on,
`QueueNotifier` posts a `UNUserNotification` (authorization requested lazily; denied ⇒ silently
skipped). Bandwidth limit and checksum verification remain **v1.x** — shown **visible-but-disabled**
(not hidden) so the tab matches the mockup and the roadmap is legible.

## 2026-07-19 — ADR-027: Connection tabs — a per-tab session collection (M16 checkpoint B)

**Status: approved 2026-07-19** (early decisions signed off before build). Implements the
screen-1 connection tab strip from the approved mockups (`.wintabs`); the tab-management
affordances not drawn in the mockup are recorded here per rule 3. **Supersedes ADR-012's
"single session per window until tabs (M16)".**

**The refactor.** `ConnectionManagerModel` held one `connectionPhase`
(`.idle`/`.connecting`/`.connected(BrowserSession)`) and every connect *replaced* it. It now
holds `tabs: OrderedTabs<ConnectionTab>` — an ordered collection with a single selection —
where each `ConnectionTab` carries its **own** `ConnectionPhase`. A `.connected` tab owns a full
`BrowserSession`, which since M7–M15.5 already isolates the two panes, the transfer queue, the
`TunnelController`, the embedded `TerminalController`, and per-session "Linked" sync-browsing —
so tabs are independent for free. The detail column renders the **selected** tab; the sidebar is
shared across all tabs (DESIGN.md screen 1).

**Pure core, testable in isolation.** The add/select/close/reorder rules live in a generic
`OrderedTabs<Element: Identifiable>` value type in FerryCore (unit-tested via a stub element:
closing the selected tab selects the same-index neighbour, else the new last; index-preserving
`move`; empty-collection edges). It is deliberately app-type-free (and non-`Sendable` — the
app's `ConnectionTab` is a main-actor class used only on the main actor).

**Threading the target tab through the async connect flow (the risk).** A connect resolves its
credential through the password / key-passphrase / host-key prompts — async round-trips through
the UI. Each prompt now carries the target `tabID` alongside the existing `ConnectIntent`; the
continuation resolves it back to a live tab and, if that tab was closed meanwhile, **tears the
freshly-built session down** instead of leaking it (`finishConnect(_:into:)`). The
terminal-only intent carries no tab and is unchanged.

**Connect placement.** Plain double-click / the detail **Connect** button connect **in the
selected tab** (disconnecting whatever it held first — "connects in current tab");
⌘-double-click opens a **new tab** (DESIGN.md). `primaryAction` carries no modifier flags, so
the ⌘ is read from `NSEvent.modifierFlags` at click time.

**Disconnect vs. close (the mockup's grey-dot state).** The mockup shows a disconnected-but-open
tab (grey dot). So **Disconnect** (toolbar) puts a tab back to `.idle` *keeping its profile* — it
renders the profile summary + a Connect button and can reconnect in place. **Closing** a tab
(per-tab ✕ / ⌘W) disconnects *and* removes it (DOMAIN.md "disconnect on tab close"). Closing a
tab whose queue still has running/queued transfers **confirms first** ("Close Anyway" / "Keep
Tab") — the tab-granularity analogue of DOMAIN.md's quit-with-transfers warning. Closing the
**last** tab keeps the window with one fresh empty tab (so the shared sidebar/window stay) rather
than closing the window — user decisions 2026-07-19.

**Terminal window plumbing survives a tab.** `terminalWindowStorage` / `pendingTerminalWindowID`
stay **model-global**, keyed by controller UUID, so the `openWindow` hand-off is independent of
which tab is active. A popped-out terminal is owned by its tab's `BrowserSession`; on disconnect
*or* tab close a windowed terminal survives with `canRedock = false` (its tab is gone) while a
docked one shuts down — the exact rule the old single `disconnect()` applied, now per tab.

**Reopen last connections → N tabs.** Checkpoint A already persisted an *array* of open-connection
profile IDs (on phase transitions). Restore now reopens **every** saved connection — the first
reuses the initial empty tab, the rest each open a new tab — reconnecting each exactly as a manual
connect does (prompting for any non-Keychain credential). Persistence lists the **connected** tabs'
profile IDs. *Known limitation:* several restored connections that each need an interactive prompt
share the single prompt slot, so their prompts can coalesce; connections with Keychain-stored
credentials (the common case) reconnect cleanly in parallel.

**New-tab affordances (rule 3 — signed off, not in the mockup):** the ＋ in the strip, ⌘T (File ▸
New Tab), and ⌘-double-click from the sidebar. **Close affordances:** a per-tab ✕ (shown on the
active/hovered chip) and ⌘W (closes the active tab, never the window — the window always keeps ≥1
tab). ⌘W is owned by a zero-size hidden button carrying the shortcut inside the key window, which
intercepts before AppKit's window-close.

**Within-folder sidebar drag reorder** (deferred from M4, DESIGN.md). Dropping an item onto a
**profile row** inserts it just before that row, reusing the existing `.draggable` UUID payload
and `ConnectionLibrary.move(itemID:toFolder:at:)` (which removes-then-inserts, so a same-parent
drag from above the target inserts one slot lower). Folder rows keep their move-into-folder drop
(unchanged); this only adds row-level drop targets, so the existing drop-on-folder / Move-to menu
paths are untouched.

**Tab-chip accessibility (XCUITest lesson).** A tab chip is two side-by-side `Button`s (select +
✕) sharing one rounded background, indexed as `tabStrip.tab.<i>` / `tabStrip.close.<i>`. An earlier
attempt with the ✕ as an `.overlay` button **on top of** the chip button failed: overlapping
buttons get merged in accessibility and the ✕ couldn't be found. The ✕ is conditionally present
only on the active/hovered chip (a `Color.clear` placeholder reserves its width), so exactly one ✕
is queryable at a time.

**Addendum 2026-07-19 — strip placement fix.** As shipped in checkpoint B the strip was mounted
inside the split view's *detail column* and, being a height-greedy horizontal `ScrollView`, split
the column's height with the detail view — the chips rendered in the vertical middle of the
window. Fixed to match the mockup: `TabStripView` now sizes to its content height
(`.fixedSize(horizontal: false, vertical: true)`) and sits **above** the `NavigationSplitView` in
`MainWindow`, a thin full-width bar directly under the title bar spanning sidebar and detail
(`.wintabs`, DESIGN.md screen 1 structure).

## 2026-07-19 — ADR-028: In-app help & acknowledgements (M16 checkpoint C)

**Status: approved 2026-07-19** (placement/format signed off before build). Adds the two
Help-menu windows that M16 called for — a minimal user guide and the license-notices screen —
neither of which is in the M0 mockups, so they are recorded here per rule 3.

**Placement — standalone Help-menu windows, not Settings tabs.** Both are `Window` scenes
opened from the Help menu (which `CommandGroup(replacing: .help)` takes over from the default
help item). The deciding factor was testability: the SwiftUI `Settings` scene does not open
under XCUITest in this harness (ADR-025), whereas a standalone window is fully drivable — so
the new UI gets real automated coverage instead of a manual-only checklist. It is also the more
macOS-conventional home for help/acknowledgements. (Options weighed: a 6th Settings tab, or
both; user chose the Help-menu window.)

**Format — native SwiftUI, not a bundled doc.** The guide is a static SwiftUI window rather
than a bundled Markdown/HTML file opened in Help Viewer or a browser: it is theme-aware,
XCUITest-drivable, and carries no doc-packaging or sandbox-file-open concerns. Scope is
deliberately minimal (ROADMAP.md M16): prose topics incl. the `.ferrypart`/resume explainer,
plus a keyboard-shortcut reference. A searchable/contextual help system stays backlog item 9.

**Pure, testable content.** The windows only render value models in FerryCore —
`HelpContent` (topics + `HelpShortcut` reference) and `Acknowledgements`
(`Acknowledgement` + `DependencyLicense`, with reproducible license bodies). `HelpContentTests`
pins integrity: every acknowledgement has a copyright line and a commercially-redistributable
license (rule 4 — a GPL/LGPL/etc. entry would fail the build), the list covers LICENSING.md's
inventory, and the shortcut list documents the M16-B tab affordances. This keeps the notice
screen honest against `docs/LICENSING.md` without a human diff.

**One ADR, not two.** Help and acknowledgements are a single polish workstream landing
together (user decision), so they share this entry.

**Error-message consistency (same checkpoint, no separate ADR).** User-facing error/info/notice
strings were swept for one voice: apostrophes normalized to typographic curly `’` (matching the
curly quotes already used for interpolated paths/names; the shell-quoting literals in
`TerminalLaunch.swift` were left untouched), and the four `Couldn’t …` strings folded into the
dominant `Could not …` form. The three alert channels (`errorMessage` / `infoMessage` "Not yet
available" / `noticeMessage`) stay distinct. No secrets are ever interpolated (rule 6).

**Dark-mode audit (same checkpoint).** Audited screen-by-screen against the mockups in both
themes; **no code changes were needed** — the UI already uses semantic/adaptive colors and the
one fixed-RGB color (the SOCKS pill `#7a5fd0`) matches the mockup CSS, which also pins it in
both themes. Appearance stays applied via `NSApp.appearance` (ADR-025).

## 2026-07-19 — ADR-029: Post-v1 roadmap — Phases G–K (M19–M31)

**Status: approved 2026-07-19.** With M16 complete, the user deferred Phase F (M17 packaging /
M18 sale readiness — still mandatory before any sale) and asked to plan the post-v1 backlog
instead. The old rough-priority backlog in ROADMAP.md is superseded by five release-themed
phases, G–K (v1.1–v1.5), scoped there; states will be tracked in PROGRESS.md as usual.

**Eight new features accepted** (Claude-proposed, user-approved): remote file search,
terminal-follows-pane auto-`cd`, server-side archive (compress/extract via exec), activity log
window, batch rename, secret-free profile export/import, localization groundwork (String
Catalogs), and Touch ID lock for marked profiles.

**v1.1 theme = "workflow quick wins"** (user choice over pro-SSH-core-first, sync-first, or
cloud-backends-first): editor round-trip, competitor importers + profile export, FTPS cert
trust, and pane power features ship first; the multiplexed-session refactor waits for v1.2.

**Sequencing rules** (dependency-driven, from the 2026-07-19 architecture review):
- **Multiplex before ProxyJump** (M22 → M23): today SFTP/exec/tunnels/terminal each own an
  independent `SSHClient` built by `SSHClientFactory` — that factory seam is where one shared
  session (and later a jump chain, built once) slots in. Constraint: the tunnel engine's
  dedicated single-thread event-loop group (ADR-021) must survive multiplexing.
- **Transfer filters before folder sync** (M25 → M26): sync needs excludes; the diff engine is
  net-new (only recursive enumeration + conflict machinery exist today).
- **`FileSystemSource` capability flags before cloud backends and checksum/preserve** (M25 →
  M27/M28): the protocol's only feature signal today is throwing `.unsupported`.
- Remote↔remote (M29) is UI/wiring only — `TransferEngine` already streams between two
  arbitrary sources.

**Recorded debts slotted in**: FTPS self-signed-cert TOFU prompt (M20, DOMAIN.md), ECDSA keys
(M23, ADR-017), `ProxyJump` honored on ssh-config import (M23, currently skipped),
remote→Finder `NSFilePromiseProvider` drag-out (M21, deferred from M10), bandwidth + checksum
(M25, settings ship visible-but-disabled per DOMAIN.md).

## 2026-07-20 — ADR-030: Editor round-trip (M19)

**Status: approved 2026-07-20** (first Phase G / v1.1 feature). "Open in Editor" a remote file
in an external editor; Ferry watches the downloaded temp copy and **auto-uploads it back on
every save**. Reuses existing machinery (Quick Look-style streaming download + a normal upload
`TransferRequest`); the only net-new mechanism is a `DispatchSource` file watcher. **No new
dependency** — `DispatchSource` and `NSWorkspace` are system frameworks (LICENSING.md/
acknowledgements unchanged).

**Editor selection (user decision):** a **default editor** set in Settings ▸ General (an app
file-URL path; empty ⇒ the system default app for the file's type), an **"Open in Editor"**
row-menu item that uses it, and an **"Open With ▸"** submenu (installed apps via
`NSWorkspace.urlsForApplications(toOpen:)` + "Other…") to pick a different app per file.
Matches Transmit's "Edit" / Cyberduck's editor round-trip. `⌘E` opens the selection.

**Editing UI (user decision): minimal.** Ferry watches silently; each save auto-uploads and
appears as an ordinary transfer-queue row (`queue.onCompleted` already reloads the remote pane).
A session ends on disconnect / tab close, when watchers are cancelled and temp copies deleted.
No active-edits panel.

**Direct-only (rule 5), like the external terminal (ADR-024):** launching another app can't
work in the App Store sandbox, so the launcher, the menu items, the `⌘E` command and the
Settings picker are all `#if !APPSTORE`; `EditorDispatch.resolve` returns `.unavailable` when
`externalAllowed == false`. The App Store build simply doesn't show the feature.

**Layering** mirrors M15's terminal split: a pure, unit-tested decision layer in FerryCore
(`Editor/EditorLaunch.swift` — `EditorTarget` + `EditorDispatch.resolve`) and a pure watcher
(`Editor/FileWatcher.swift`, `DispatchSource` → coalesced `AsyncStream`), with the
non-headless-testable `NSWorkspace` launch in the app target (`ExternalEditorLauncher`). The
**editing-sessions tracker lives on `BrowserSession`** (it needs the remote source, the queue,
and must survive pane navigation) keyed by remote path; the upload is `.restart` to the
**original** remote path regardless of where the pane has since navigated.

**FileWatcher subtleties** (unit-tested): a save's burst of vnode events is **debounced** into
one upload; an **atomic save** (write-sibling-then-`rename(2)`, used by BBEdit/VS Code/vim)
replaces the watched inode, so on `.delete`/`.rename` the watcher re-opens the path and re-arms,
still emitting one change. Known limitation (DOMAIN.md): rapid successive saves each enqueue a
`.restart` upload; the debounce plus normal save cadence makes overlap rare.

**Net-new UI signed off** (rule 3): the two menu items + the Settings ▸ General "Editing"
default-editor picker are drawn into `docs/design/ferry-mockups.html` and `docs/DESIGN.md`.

## 2026-07-20 — ADR-031: Competitor importers — FileZilla, Cyberduck, WinSCP (M20 checkpoint A)

**Status: approved 2026-07-20** (first M20 checkpoint of Phase G / v1.1 "switchers & trust").
Lets users migrating from other clients bring their saved sites into Ferry. Mirrors the M11
`~/.ssh/config` import pipeline (ADR-018): a pure FerryCore parser per format → a checklist
sheet → import into a fresh folder. **No secrets** are read (rule 6) — passwords/passphrases
are prompted on first connect.

**Three source formats** (the third, WinSCP, added at the user's request during planning):
- **FileZilla** — Site Manager `sitemanager.xml` (also the live `~/.config/filezilla/` layout),
  parsed with an event-based `XMLParser`. `<Protocol>` 0→FTP, 1→SFTP, 3/4→FTPS; unknown
  (HTTP/S3/…) skipped. `<Logontype>` 0 → user `anonymous`; `<KeyFile>` → key auth (SSH only);
  `<Pass>` never read.
- **Cyberduck** — the `.duck` XML-plist bookmarks in
  `~/Library/Application Support/Cyberduck/Bookmarks/`, parsed via `PropertyListSerialization`.
  `Protocol` `sftp`/`ftp`/`ftps`; unknown providers (s3, dav, …) skipped. **Bookmarks folder
  only, not History** (user decision — History is transient recently-visited servers).
- **WinSCP** — an **exported `WinSCP.ini`** (WinSCP is Windows-only, so there is no macOS
  install/registry to read), parsed with a small self-contained INI reader. `[Sessions\<name>]`
  sections; `FSProtocol` 0→SCP, 1/2→SFTP, 5→FTP (+`Ftps`≠0 ⇒ FTPS); WebDAV/S3 and the
  `Default Settings` template skipped; obfuscated `Password` never read.

**Folder hierarchy is preserved** (user decision) for FileZilla (`<Folder>` nesting) and WinSCP
(session names are `/`-separated, percent-encoded). Each imported connection carries its
ancestor folder names; on import Ferry rebuilds only the folders the selection needs under a
fresh, uniquely-named `<Source> Import` folder. Cyberduck bookmarks are flat.

**Shared value type + sheet, but M11 left untouched.** The three new parsers emit a unified
`ImportedConnection` (FerryCore) presented by one generalized `ProfileImportSheet` (app). M11's
`ImportedSSHHost`/`SSHImportSheet` are **deliberately not unified** — they are tested and
working, and folding them in would risk a regression for no user-visible gain. Unifying the
SSH-config path onto `ImportedConnection` is a possible later cleanup.

**Entry points:** the sidebar **Import** menu (next to "From SSH Config…") and a **File ▸ Import
Connections** submenu, each with From FileZilla… / From Cyberduck… / From WinSCP…. Source files
are chosen with `NSOpenPanel` (default locations pre-filled; `FERRY_FILEZILLA_SITEMANAGER` /
`FERRY_CYBERDUCK_BOOKMARKS` / `FERRY_WINSCP_INI` env overrides drive tests headlessly).

**Sandbox (rule 5):** reading a user-chosen file/folder is sandbox-legal via the
security-scoped open panel, so — unlike the app-launching terminal/editor features — the
importers need **no `#if APPSTORE` gating**; both flavors build and ship the feature.

**Known caveat (DOMAIN.md/help):** WinSCP private keys are PuTTY `.ppk`, which Ferry's
`SSHKeyLoader` can't load (ADR-017). The `PublicKeyFile` path imports as-is (public-key auth) so
the site is visible; the user must convert the key to OpenSSH format and repoint it.

**No new dependency** — `XMLParser`, `PropertyListSerialization`, and the INI reader are all
Foundation/hand-rolled (LICENSING.md unchanged).

**Net-new UI signed off** (rule 3): the Import menu entries + the shared `ProfileImportSheet` are
drawn into `docs/design/ferry-mockups.html` and `docs/DESIGN.md`.
