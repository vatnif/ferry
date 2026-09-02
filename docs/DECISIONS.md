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

## 2026-07-20 — ADR-032: Secret-free profile export/import — Ferry's own format (M20 checkpoint B)

**Status: approved 2026-07-20** (second M20 checkpoint). Lets users move connections between
Macs (and back them up) with Ferry's own portable format. The connection store is already a
self-contained, schema-versioned, **secret-free** JSON tree (M2), so export is essentially
serializing a chosen slice of it and import is decoding + merging.

**Format** — a self-describing, independently-versioned envelope
(`FerryCore/Store/ConnectionExport.swift`): `{ format: "com.gfragos.ferry.connections",
formatVersion: 1, generator, exportedAt, items: [SidebarItem] }`. Reuses `ConnectionStore`'s
JSON conventions (ISO-8601 dates, pretty + sorted keys) so files diff and back up cleanly.
Decoding validates the `format` tag (rejects arbitrary JSON → `.notAFerryExport`) and refuses a
newer `formatVersion` (→ `.unsupportedFormatVersion`), mirroring the store's schema guard.

**No secrets** (rule 6) — `ConnectionProfile`/`ProfileFolder` carry none by construction; the
file never touches the Keychain. `ConnectionExport.sanitized` additionally strips per-machine
UI-restoration state (`lastLocalPath`/`lastRemotePath`) on export, while keeping user settings
like `localStartPath`/`remoteStartPath`. A unit test also asserts the serialized text contains no
`password`/`passphrase`/`secret` keys (defense in depth).

**Export (user decision): per-item + Export All.** Right-click a profile or folder ▸ **Export…**
saves that node's subtree; **File ▸ Export All Connections…** saves the whole library. `NSSavePanel`
(default `.json`); `FERRY_EXPORT_PATH` bypasses it for tests.

**Import merge (user decision): fresh "Imported" folder.** Chosen connections land under a new
uniquely-named `Imported` folder with their exported subfolder structure rebuilt, via the shared
`ConnectionLibrary.addImported` (also used by the checkpoint-A competitor importers). **Every
imported profile and folder gets a fresh UUID** — this *is* the id-collision policy: two items
sharing a UUID would break the tree (`profile(withID:)`/`move`/`remove` key off id), and re-iding
guarantees an import never overwrites, aliases, or corrupts existing items. Name collisions are
avoided by namespacing everything under the fresh folder (`uniqueFolderName`); duplicate display
names are otherwise allowed (as elsewhere in the app). Round-tripping an export therefore
duplicates rather than syncs — expected for an import, not a merge/sync engine (a real sync is
backlogged to M26).

**Checklist reuse (rule: reuse the import UI).** The checklist was generalized into
`ImportChecklistSheet` (title/subtitle/rows/id-prefix); `ProfileImportSheet` (checkpoint A) was
refactored onto it and the new `FerryImportSheet` uses it too. M11's `SSHImportSheet` stays as-is
(same call as ADR-031 — not worth the regression risk).

**Sandbox (rule 5):** export/import read/write user-chosen files via the security-scoped save/open
panels, so the feature ships in **both** flavors (no `#if APPSTORE`).

**No new dependency** — Foundation `JSONEncoder`/`Decoder` only (LICENSING.md unchanged).

**Net-new UI signed off** (rule 3): the Export… menu items + **Export All Connections…** + the
**From Ferry Export…** import entry + the shared checklist sheet are drawn into
`docs/design/ferry-mockups.html` and `docs/DESIGN.md`.

## 2026-07-20 — ADR-033: FTPS certificate trust-on-first-use (M20 checkpoint C)

**Status: approved 2026-07-20** (third and final M20 checkpoint; completes M20). Pays down the
M12/ADR-019 debt: an FTPS server whose certificate doesn't chain to a system-trusted root used to
fail with a dead-end `.tlsFailed`, escapable only by the test-only `allowInvalidCertificate` hook.
This builds a real trust path, modelled **exactly** on the SSH host-key TOFU (ADR-016): capture the
offered certificate, show its fingerprint, let the user trust (remember) or cancel, persist the
decision, and re-validate identically — pinned — on every later connect and auto-reconnect.

**Key technical risk — spiked first (retired).** How to capture the offered certificate + pin it on
reconnect using the **system libcurl** on macOS (curl 8.7.1, SecureTransport backend). Verified via
the libcurl C API against the self-signed test server (:2990) with the exact options Ferry uses:

- **Capture** — with `CURLOPT_SSL_VERIFYPEER=0` + `CURLOPT_CERTINFO=1`, `CURLINFO_CERTINFO` **is
  populated even on the SecureTransport backend** (contrary to older lore), and the leaf entry
  carries Subject/Issuer/Start date/Expire date **and the full PEM**. So Ferry captures the offered
  cert, decodes PEM→DER, and computes a stable SHA-256 — no backend switch, no bundled TLS lib.
- **Enforce before data** — `CURLOPT_PREREQFUNCTION` fires after the TLS handshake + FTP login but
  **before any transfer**, with `CURLINFO_CERTINFO` already available. Ferry's pre-request callback
  reads the presented leaf cert's DER SHA-256 and compares it to the pin, returning
  `CURL_PREREQFUNC_ABORT` on a mismatch. Enforcement is therefore at the library level, on **every**
  handle (control *and* data channel), before a single byte flows. (`CURLOPT_PINNEDPUBLICKEY` also
  works on this backend but pins the SPKI, not the whole cert; the whole-cert DER fingerprint was
  chosen so identity matches what the user sees and a re-issued cert re-prompts — mirroring how SSH
  fingerprints the whole host key.)

**Fingerprint = whole-cert DER SHA-256** (user decision), shown as uppercase colon-separated hex
(the openssl/browser convention, e.g. `E1:E5:43:…`). One uniform value is the identity, the display,
the pin, and the changed-cert discriminator.

**Store** — new `FerryCore/TLS/CertificateTrustStore` (the analogue of `HostKeyStore`, a separate
type): a `FERRY_DATA_DIR`-aware plaintext **JSON** persister (structured cert fields suit JSON better
than a `known_hosts` line), keyed `host:port` — one endpoint pins one certificate. API mirrors
HostKeyStore: `trust`/`replace`/`remove`/`trustedCertificate`/`storedInfos`/`contains`/
`allTrustedCertificates`. `CertificateInfo` (analogue of `HostKeyInfo`) is a pure value type built
from the CERTINFO fields; a certificate is public info, never a secret (rule 6), so plaintext is
correct and nothing touches the Keychain.

**Seam** — `FTPSource.connect` gains `trustedCertificate: CertificateInfo?` (the pin). No pin +
untrusted cert → capture-retry (verify off + CERTINFO) → new `RemoteSourceError.certificateUntrusted`.
Pinned + mismatch → `RemoteSourceError.certificateChanged(stored:offered:)`. The pin lives in the
source's in-memory `Parameters`, so `reestablish()` (ConnectionSupervisor) re-applies it identically
— **the security-critical invariant: a supervised reconnect never silently downgrades trust.** The
CFTP shim gained `ferry_getinfo_certinfo`, `ferry_set_prereq_cb`, and the prereq OK/ABORT constants.

**App** — `CertificatePrompt` + `CertificatePromptSheet` mirror `HostKeyPrompt`/`HostKeyPromptSheet`:
📜 first-contact (subject/issuer/validity + fingerprint, Remember toggle, Trust & Connect) and ⚠️
changed-cert alarm (Disconnect primary/recommended; Replace behind a second confirmation; was→now
fingerprints). The prompt threads a `tabID` like the host-key prompt (tabbed connections, ADR-027).
"Remember off" pins for the session only (threaded into the retry, not persisted). Settings ▸ Keys
gains a **Trusted certificates** section + `TrustedCertsManagerSheet` (parallel to Manage known
hosts) to review/forget pins.

**Both distributions** (rule 5): pure libcurl + a plaintext store under `FERRY_DATA_DIR`/the
container — sandbox-safe, no `#if APPSTORE` gating (unlike terminal/editor, this isn't an
app-launch feature). **No new dependency** — system libcurl + swift-crypto (already direct deps).

**Net-new UI signed off** (rule 3): the cert prompt (both states) + the Settings management section
are drawn into `docs/design/ferry-mockups.html` and `docs/DESIGN.md`.

**Tests**: `CertificateInfoTests` (fingerprint vs an openssl golden vector, display formatting) +
`CertificateTrustStoreTests` (round-trip, first-contact vs changed, per-endpoint scoping, replace/
remove, corrupt-file recovery); `FTPSCertTrustTests` against :2990 drives the **real** trust path
(no `allowInvalidCertificate`): first-contact capture + fingerprint, trust→connect+browse, reconnect
re-pins with no re-prompt, and a mismatched pin is rejected as `.certificateChanged`. HelpContent
guard for the new user-facing behavior.

## 2026-07-25 — ADR-034: Keychain access never blocks the main actor

**Status: approved 2026-07-25** (bug fix, no milestone). Found while the user was stuck in a
looping macOS Keychain dialog that ended with an apparently dead app.

**What actually happened.** Login-keychain items carry an ACL, so macOS can put its authorization
panel ("Ferry wants to use your confidential information stored in …") in front of *any*
`SecItem*` call. `ConnectionManagerModel.resolveCredential` called `CredentialVault.retrieve`
synchronously on the main actor, so the whole UI froze for as long as that panel stayed up — 16 s
in the reported case, and indefinitely while the panel was left open. The app never crashed; it
was frozen, then quit with ⌘Q ("Termination complete" in the log, no crash report).

**Decision.** No UI code path may call the synchronous `CredentialVault` methods. The vault gains
`retrieveAsync` / `storeAsync` / `deleteAllAsync`, which hop to a detached task before touching
`SecItem*`; the synchronous forms stay for tests and for code already off the main actor. Converted
call sites: `resolveCredential`, `connectWithKey`, `saveDraft`→`storeSecrets`, `deleteItem`,
`duplicateProfile`, `connectWithTypedPassword`/`connectWithTypedPassphrase` (via `rememberSecret`),
and `ProfileDraft.fromExisting` (the editor sheet now fills in asynchronously). `connect` prepares
its tab synchronously before awaiting, so restoring several connections keeps its tab order.

**Second decision — a denied panel is not a missing secret.** `retrieve` used to be called as
`try? … ?? nil`, collapsing every failure into "nothing stored", which then showed Ferry's own
password sheet as if it had forgotten the credential. `errSecUserCanceled` now maps to
`CredentialVaultError.userCanceled`, and the connect aborts with an explanation
(`credentialReadFailed`) instead of re-prompting. Other statuses surface via
`SecCopyErrorMessageString`.

**Not decided here.** Ad-hoc-signed builds cannot hold a durable trusted-application ACL entry, so
locally-built Ferry re-prompts on every access to a stored secret no matter what the user clicks —
"Always Allow" cannot stick without a stable code-signing identity. That is a development-
environment problem (see BUILDING.md → Keychain prompts), not something the app can fix, and it
does not change ADR-010's choice of the login keychain over the data-protection keychain.

**Tests**: `CredentialVaultTests` covers the status→error mapping (`errSecUserCanceled` vs raw
statuses); `CredentialVaultKeychainTests` round-trips the async variants against the real Keychain
and asserts they are callable from the main actor without deadlocking.

## 2026-08-02 — ADR-035: Per-controller SwiftUI identity for the embedded terminal

**Status: approved 2026-08-02** (bug fix, no milestone). Reported by the user: with two connected
tabs, the terminal opened in the first tab kept showing up under the second tab's file panes, and
opening a terminal in both made the UI incoherent.

**What actually happened.** The models were never at fault: since M15.5 each tab owns its own
`TerminalController` → `TerminalSession` → `TerminalSessionBridge` (ADR-023/ADR-027). The defect
was SwiftUI **view identity**. `DetailPlaceholderView` builds `BrowserView` inside a `switch`
branch with no `.id(...)`, so every connected tab renders its browser at the *same structural
position* — one identity. SwiftUI therefore updates that tree on a tab switch instead of rebuilding
it, which is harmless for data-driven views but not for `SSHTerminalView`, the app's only
`NSViewRepresentable`: `makeNSView` runs **once per identity**, so a tab switch called only
`updateNSView`, handing back the first tab's live `SwiftTerm.TerminalView` while the struct's
`bridge` now pointed at another tab's session. The wrong screen was shown, the reused view's
delegate was still the first bridge (so keystrokes ran on the *other* server), and the second
tab's bridge never attached — its pump never started, so that shell's output accumulated
unconsumed in an unbounded `AsyncStream` and its PTY stayed 80×24.

The bleed needed both panels open: switching to a tab whose panel is closed flips the `if` in
`BrowserView`, which destroys the subtree and gives the next panel a fresh identity. Detaching
(pop-out) also hid it, because `WindowGroup("Terminal", …)` gives each popped-out terminal its own
scene and view tree. The worst variant was re-docking: "Dock in Window" pressed while *another*
tab's panel is open returns a terminal to a tab that isn't on screen, and the switch back reused
the other tab's emulator — leaving the re-docked shell alive but invisible and unreachable.

**Decision — identity where the emulator lives, not on the whole browser.**
`TerminalPanelView` tags its `SSHTerminalView` with `.id(controller.id)`, so every host of the
panel (docked, pop-out window, terminal-only window) gets one emulator per controller; the docked
`TerminalPanelView` in `BrowserView` also carries `.id(terminal.id)` for its own local state.
Deliberately **not** `.id(tab.id)` on `BrowserView`: that rebuilds the whole subtree on every tab
switch and resets the `HSplitView` divider each time. Because nothing calls `detach()`, a departing
tab's `TerminalView` stays retained by its bridge with scrollback and pump intact and is re-hosted
on return — the same mechanism pop-out/re-dock already relies on.

**Second decision — a tab's modal state belongs to its session.** `BrowserView`'s `@State` was
shared across tabs for the same reason. Staged conflicts, resume decisions, the New Folder name and
the tunnel sheet flag moved onto `BrowserSession` (`pendingConflicts`, `pendingResumeDecisions`,
`newFolderName`, `showTunnels`). These present modal UI, so the leak was mostly latent — but
staging is async: dropping files in one tab and switching before it finished surfaced the
"already exists" alert over another tab, where **Replace** enqueued into *that* tab's session, i.e.
a transfer to the wrong server. `terminalDragBase` stays `@State` (it lives for one drag).

**Tripwire.** `SSHTerminalView.updateNSView` now asserts `view === bridge.view`. Nothing there can
re-host an NSView, so a debug build fails loudly instead of silently driving the wrong server.

**Tests**: `FerryUITests.testTerminalsInTwoTabsStayIndependent` (two tabs, two shells told apart by
a variable set in the first — the second tab's `touch` must land in its own shell, and the first
tab's panel must still reach its own after switching back) and
`testRedockedTerminalReturnsToItsOwnTab` (pop out, re-dock from the other tab, switch back). Both
were confirmed to fail before the fix. `TerminalSessionBridgeTests.testEachBridgeOwnsItsOwnViewAndOutput`
pins the bridge half: distinct views, no crossed output, no crossed keystrokes.

## 2026-08-02 — ADR-036: The sidebar is shown explicitly; UI tests ignore restored window state

**Status: approved 2026-08-02** (bug fix, no milestone). Found while investigating four XCUITests
that failed on a clean tree.

**What actually happened.** `MainWindow` used `NavigationSplitView { … } detail: { … }` without a
`columnVisibility`, i.e. `.automatic` — and on this macOS the window opened with the **sidebar
hidden**. Ferry's sidebar *is* the connection manager, so the app launched showing nothing but the
"No Connection Selected" placeholder, with the connection list reachable only through the
system-supplied "Show Sidebar" toolbar button (whose presence is what finally identified the
state — the accessibility tree reported the split view with a single, full-width column). It was
not stale preferences: clearing the `com.gfragos.Ferry` defaults domain, including the
`NSSplitView Subview Frames …` key, changed nothing, and the same failure reproduces at
`ec114e2` — before the tab strip existed, when the split view was still the window root.

**Decision.** Drive the visibility: `@State private var columnVisibility: NavigationSplitViewVisibility = .all`
bound into `NavigationSplitView(columnVisibility:)`. The sidebar is on screen at launch (DESIGN.md
screen 1) and the user's Hide/Show toggle still works for the session. Deliberately not persisted
across launches — the failure mode being fixed is "the connection manager is invisible", and a
remembered `.detailOnly` would bring it straight back.

**Second decision — UI tests isolate window state.** `launchIsolatedApp` now passes
`-ApplePersistenceIgnoreState YES` alongside the `FERRY_DATA_DIR` / Keychain isolation. macOS was
restoring the previous Ferry's windows into each freshly-launched test app: runs that popped a
terminal out left **"Terminal" windows with dead sessions** hanging around in later tests'
`app.windows`. Window state is now as isolated as the data directory. This also cut the failing
tests' runtimes (they had been waiting out `waitForExistence` timeouts).

**Known, not fixed here.** Outside the tests, macOS still restores those dead terminal windows on a
relaunch — an empty window reading "This terminal session has ended." **Fixed in ADR-037.**

**Tests**: no new tests — `testAppLaunchesWithSidebarAndEmptyState` already asserted the sidebar's
"Connections" header and was one of the four tests failing; the other three
(`testHelpMenuOpensGuideWindow`, `testHelpMenuOpensAcknowledgementsWindow`,
`testImportFromSSHConfigAddsProfiles`) pass again with window state isolated. Full suite: 429 kit +
19 XCUITests, all green.

## 2026-08-02 — ADR-037: Terminal windows are never restored

**Status: approved 2026-08-02** (bug fix, no milestone). The open item left by ADR-036.

**What actually happened.** A standalone terminal window (pop-out or terminal-only) is a view onto a
live in-memory `TerminalController`; its SSH session cannot outlive the process. macOS does not know
that, so after an abnormal termination it restored those windows into the next launch, where
`TerminalWindowView` failed to resolve the id and rendered its "This terminal session has ended."
placeholder — an empty, dead-end window, and up to three of them were observed at once. Confirmed as
restoration by launching with `-ApplePersistenceIgnoreState YES`, which made them disappear.

**Decision.** Opt the scene out: `WindowGroup("Terminal", …).restorationBehavior(.disabled)`. The
modifier is macOS 15+, and `if #available` in a `@SceneBuilder` has no `else` branch — which is
correct here rather than a compromise: **every** path that opens this window is already macOS-15
gated (both `BrowserView` call sites sit inside `#available` checks, and `pendingTerminalWindowID`
is only set by the `@available(macOS 15.0, *)` `startTerminalOnly`), because the built-in terminal
needs Citadel's `withPTY` (ADR-023). On macOS 14 the scene has nothing to open, so it does not exist.

**Second decision — a window with no controller closes itself.** `TerminalWindowView`'s fallback
branch used to display the "session has ended" text; it now dismisses instead. A missing controller
means the window outlived what it was a view onto (a restored window, or a re-dock that deregistered
before the dismiss landed) — there is nothing to show and nothing to reconnect to. This also covers
any restoration path the scene modifier does not.

**Verification — and its limit, stated plainly.** The live paths were re-checked by hand against the
Docker server (connect → open terminal → pop out → re-dock: the window opens, the shell keeps
running, re-docking returns it to its tab) and by the two ADR-035 XCUITests; full suite green (429
kit + 19 XCUITests). But the restoration *itself* could not be re-triggered on demand once the
system's saved state had been cleared: neither ⌘Q nor SIGKILL with a popped-out window reproduced
it afterwards. So the fix rests on the observed failure plus the documented API for exactly this
case, **not** on a live before/after. A regression test is not practical either — cross-launch OS
restoration is not something XCUITest can drive, and the suite now explicitly disables it (ADR-036).

## 2026-08-15 — ADR-038: Remote→Finder drag-out (`NSFilePromiseProvider`) with a truthful completion

**Status: behaviour choices approved 2026-08-14 (plan); shipped across M21 checkpoints A
(735b955), B (1420349), and C.** Pulled forward out of the M21 bundle. Closes the ADR-015
backlog item: remote rows now drag out to a Finder window and download there through the real
transfer queue, giving parity across all four drag directions. The user decision that drives
the whole design: **Finder's completion must be truthful** — the promise is signalled only
after every byte has landed, never before.

### The drag shape — measured, do not re-litigate

`NSFilePromiseProvider` is `NSPasteboardWriting`, not `NSItemProvider`, so SwiftUI's
`.draggable` cannot carry a file promise; the remote icon hosts a transparent AppKit overlay
(`RemoteDragHandle`) and a session-scoped `NSDraggingSource` (`RemoteDragBridge`). The final
shape, arrived at by a five-configuration measurement matrix (checkpoint A, both flavors,
user-verified):

- **One dragging item per row: the file promise.** Finder's count badge counts *dragging
  items* regardless of whether it can consume their types (a second, non-Finder-consumable
  item still badged "2" per row), so a truthful badge demands exactly one item per row.
- **The M8 `ferryitem|…` inter-pane payload is appended straight to
  `session.draggingPasteboard`** after `beginDraggingSession` — on the pasteboard (so the
  other pane's drop decodes it) without being a countable dragging item. The mid-session
  append does not disturb the promise.
- The payload travels under Ferry's **declared** UTI `com.gfragos.ferry.drag-item`
  (`Ferry/Info.plist` `UTExportedTypeDeclarations`, merged with the generated plist): an
  undeclared identifier decodes zero items, and the private type cannot paste raw
  `ferryitem|…` text into TextEdit/Mail the way `.string` did.
- **SwiftUI's Transferable decoding reads NOTHING off a pasteboard item that also carries
  file-promise types** — measured for `.string` and again for the declared type; AppKit
  reads the same item fine. This is why the payload needs its own pasteboard item at all.
- **Published `NSProgress` produces no Finder indicator whatsoever** — not even
  indeterminate. Dropped from scope (it was flagged best-effort; Ferry's queue dock shows
  real progress). With it went `cancelDragOut` — Finder's cancel button was its only caller.

### Truthful completion: the transfer group

`TransferEngine.performDirectory` marks a directory request `.completed` when its children
are merely *enqueued* — awaiting the root would tell Finder "done" before a byte of a child
has been copied. So drag-out items carry a `groupID` (children inherit it) and
`TransferGroupTracker` (an actor constructed WITH the engine, so it can never miss a member)
folds member snapshots into one `AsyncStream<TransferGroupEvent>`: `.progress` (aggregate;
`totalBytes` nil until enumeration closes, then the exact sum), `.stalled`, `.finished`
(failed ▸ cancelled ▸ completed precedence).

The stopping rule *"every known member is finished"* is sound because children publish
`.queued` synchronously inside the engine actor, before their parent's terminal event, and
`publish` yields to subscribers in order — a new member's first event always precedes its
parent's terminal event, at any depth. It needs three guards, each pinned by a test:
**seed the group with the root id** (otherwise the rule is vacuously true for an empty
group, e.g. after `clearFinished()`); **treat `.paused` explicitly** (it is not
`isFinished`, so it would otherwise hang the group forever — it yields `.stalled`); and
**freeze a concluded group** (`resume` on a failed directory re-enqueues members; they must
not produce a second `.finished`).

### Staging: always `.restart`, direct to the destination

The promise delegate (`PromisedRemoteDownload`) hands Finder's chosen path to
`BrowserSession.beginDragOut`, which opens the group **before** enqueueing (on the engine
directly — `queue.enqueue` spawns an unordered Task that could race the registration) and
builds a `DragOutPlan`:

- **Mode is always `.restart`**, not merely tidy: the engine's resume heuristic would
  silently append to any fresh, similar-sized `.ferrypart` left at the drop location by an
  earlier drag of a *different* file, and a drag has no conflict prompt to reason about it.
  Children inherit the mode, so a whole dropped tree restarts.
- **Direct-to-destination** (a visible `.ferrypart` sibling during the download — already a
  documented, user-facing concept in Ferry's help) rather than temp-then-move: a temp dir
  may sit on a different volume than the drop target, degrading the move into a second full
  copy with 2× peak space.
- **Finder owns the destination path**: the `NSFilePromiseReceiver` resolves name conflicts
  in the drop folder before handing over the promise, so none of the pane's
  exists/dedup/resume policy applies — `stageTransfers` and `TransferNaming` are
  deliberately not reused. Measured (user, 2026-08-15, closing matrix #7): on a same-name
  drop Finder **renames silently** to a numbered name — no Keep Both/Replace prompt, which
  Finder only shows for real-file copies. Standard platform behaviour for promise drags
  (Safari images, Mail attachments behave the same); documented in the in-app help.
- **Litter policy** (`litter(after:)`/`cleanUp`): nothing on `.completed`; a file's litter
  is only its `.ferrypart` (never the destination URL — Finder's); a directory the drag
  created is removed whole on failure/cancel; a **pre-existing directory is never deleted**
  (we cannot tell our bytes from the user's). Cleanup runs only on `.finished`, never on
  `.stalled`.

### Outcome → promise mapping

`.completed` → success. `.failed(msg)` → `NSFileWriteUnknownError` carrying Ferry's message
(Finder shows it). `.cancelled` → `NSUserCancelledError` (silent abort). **Pause** →
`.stalled`: the promise is released as a user-cancel (no alert) but the Ferry row and its
partial data stay, the group stream stays open, and Resume still lands the file — cleanup
never runs on a stall. Known, documented weirdness rather than fixed: Finder has stopped
watching by then, and resuming a *failed* group after cleanup restarts from byte 0. A
drag-out also waits behind already-queued transfers (priority insertion is backlog).

### Boundary and lifetime rules

- **The completion handler is a sanctioned exception** to ARCHITECTURE.md's "no completion
  handlers in new code": that rule governs Ferry's own APIs; `NSFilePromiseProviderDelegate`
  is an OS-imposed boundary and the handler's only job is to relay what an `AsyncStream`
  already decided. The delegate class is deliberately **not** `@MainActor` — the protocol is
  @objc, so witnesses cannot be actor-isolated; discipline is `operationQueue(for:) = .main`
  plus a `@MainActor` Task, the same shape the checkpoint-A stub proved.
- **Delegates are session-scoped and retained by the bridge** (`NSFilePromiseProvider`'s
  delegate is weak, and a `Table` cell view can be recycled mid-drag — a row-owned delegate
  would hang the promise silently). A drag that ends with **no drop** releases its
  delegates immediately (`draggingSession(_:endedAt:)`); on a real drop they stay until
  their own `onFinish` (Finder can fulfil a promise after the session ends). The delegate
  holds a `@MainActor` closure, not the session: re-resolving the weak session when Finder
  actually requests the promise means a closed tab **fails** the promise instead of hanging
  Finder.
- **Refuse to vend** (the drag never starts) when the pane isn't remote or the connection
  is `.lost`. `.reconnecting` is *not* refused — the engine retries transient failures, so
  a queued row is the honest behaviour.
- **Sandbox (rule 5)**: the promise holds `startAccessingSecurityScopedResource()` on the
  drop directory for its whole lifetime (a no-op returning false in the Direct build).
  Checkpoint A measured the sandboxed write works across a 30 s promise; multi-minute
  grants are covered by the held scope.

### UI notes (rule 3)

The mockups don't draw a drag affordance; the drag image is the row's own icon (today's
feel, approved 2026-08-14). Two behaviour refinements ride along: **icon double-click now
navigates / Quick Looks** (partially retiring the ADR-013 wart — the old `.draggable`
swallowed it), and — decided in checkpoint C, matching Finder's mouse-down — **dragging an
unselected row makes it the selection** (a row inside the selection still drags the whole
selection in listing order, via `DragOutPolicy.itemsToDrag`).

## 2026-09-02 — ADR-039: Local symlinks to directories are navigable (Foundation lstat/follow gotchas)

**Status: bug fix, shipped (user-verified 2026-09-02).** User-reported: clicking a link in the
local pane did not follow it. A local symlink to a directory would neither navigate nor behave
like a folder.

**Two Foundation gotchas, both proven empirically before the fix:**

1. **`.isDirectoryKey` from a directory listing uses lstat semantics.** For a symlink it
   describes the *link* (never a directory), so `LocalFileSource.fileItem(at:)` set
   `isDirectory = false` on a symlink-to-directory. `FileBrowserPane.primaryAction` keys off
   `item.isDirectory`, so the row was routed to Quick Look, not `session.navigate` — the row
   just sat there. Fix: when the entry is a symlink, resolve the target's type with
   `FileManager.fileExists(atPath:isDirectory:)` (which follows the link; false for a broken
   link, correctly left non-navigable) instead of trusting `.isDirectoryKey`.

2. **`contentsOfDirectory(at:)` will not follow a symlinked leaf directory.** Even with the
   type fixed, listing the link's own path threw `NSCocoaError 256 / POSIX ENOTDIR` — the
   URL-based API does not resolve a symlink that *is* the directory being enumerated (both the
   trailing-slash and plain URL forms fail; only `resolvingSymlinksInPath()` or the `atPath:`
   variant follow it). Fix: in `list`, when the requested path is itself a symlink, enumerate
   `requestedURL.resolvingSymlinksInPath()`. A plain directory keeps its exact path and code
   path — the resolve cost is paid only for the rare symlinked-directory navigation.

**Scope kept deliberately small.** The entry still shows the alias icon and "Alias" kind
(`isSymlink` is unchanged and truthful); only the *navigability* was wrong. Remote symlinks
are untouched (SCP/SFTP listing behaviour, ADR unchanged). A symlink to a file still Quick
Looks; a broken symlink is treated as a file. Covered by
`LocalFileSourceTests.testSymlinkToDirectoryIsListedAsNavigableDirectory` (dir link → navigable
+ enumerable, file link → not a directory, broken link → not a directory). 453 kit tests green;
both flavors build.
