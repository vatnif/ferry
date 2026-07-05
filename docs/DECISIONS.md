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
