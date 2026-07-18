# Ferry — progress tracker

> Update this file at the end of **every working session** and **every milestone**
> (rule 1 in CLAUDE.md). States: `todo` · `in progress` · `awaiting review` · `done`.

## Milestones

| # | Milestone | State |
|---|---|---|
| M0 | UI mockups & approval | **done** (approved 2026-07-05, incl. icon concept A + sync browsing) |
| M1 | Scaffolding, docs & test infra | done (committed 97fccf4) |
| M2 | Domain models & profile store | done (committed 18d38e5) |
| M3 | CredentialVault (Keychain) | done (committed dff4ded) |
| M4 | Connection Manager UI | done (committed 3d17f7c) |
| M5 | FileSystemSource protocol + LocalFileSource | done (committed 27e1dfe) |
| M6 | SFTP spike → SFTPSource (read-only) | done (committed 3c9567a) |
| M7 | Dual-pane browser UI | done (committed c23cf04) |
| M8 | TransferEngine + queue UI | done (committed b1c9394) |
| M9 | Resume & robustness | done (committed 388de0d) |
| M10 | File operations | done (committed 9cfe66a) |
| M11 | Key auth & host trust | done (checkpoint A ffd7233, checkpoint B a008639) |
| M12 | FTP/FTPS via libcurl | done (committed 7223169) |
| M13 | SCP | done (committed 6b1e981) |
| M14 | Tunneling | todo |
| M15 | Open in Terminal | todo |
| M16 | Tabs & polish | todo |
| M17 | Packaging (sign/notarize/DMG/Sparkle) | todo |
| M18 | Sale readiness | todo |

Backlog (post-v1): see `docs/ROADMAP.md`.

## Current state of the code (M13 — done, committed 6b1e981)

- **SCP works end-to-end** over an **SSH exec channel**, reusing the M11 SSH stack
  (Citadel; host-key TOFU + password/key auth) — ADR-020. New FerryCore `SCPSource`
  (actor, `FileSystemSource` + `SupervisedConnection`) slots into the generalized
  `BrowserSession` exactly like `FTPSource` did (M12).
- **Split surface** (the core mapping problem — the scp wire protocol carries only bytes):
  **metadata runs POSIX commands over exec** (`pwd`/`ls -la`/`ls -ld`/`mkdir -p`/`rm -rf`/
  `mv`/`chmod`, all paths single-quoted + `--` against injection; `ls` parsed by the shared
  Unix `ls -l` parser reused from FTP), and **bytes stream over the classic scp protocol**
  (`scp -f` download, `scp -t` upload) driven through Citadel's bidirectional `withExec`.
- **Capability compromises vs SFTP** (documented in DOMAIN.md → SCP): **no transfer resume**
  — a resumed download re-reads from the start but the stream still begins at `offset`
  (byte-exact, no bandwidth saving); a resumed upload is rejected (offset > 0 →
  `.invalidOffset`, so the engine restarts). Upload **buffers to a local temp file** (scp
  needs the size up front) and **stages to a remote `.ferry-scp-part` renamed into place on
  success**, so an interrupted upload never poisons the engine's resume. A server that
  forbids exec (SFTP-only) is detected at connect with a clear message.
- **withExec error masking** handled: Citadel's `withExec` cleanup (`channel.close()`) throws
  "Already closed" once the remote scp has exited, masking a thrown error — so neither
  protocol driver throws through it. The download driver reports via the stream continuation;
  the upload driver via an out-of-band `UploadOutcome` (explicit `completed` flag so a clean
  close after success isn't read as failure). Errors are classified from scp `\x01`/`\x02`
  status messages and drained `stderr`.
- **Shared SSH connect**: host-key TOFU + auth + error-classification extracted from
  `SFTPSource` into **`SSHClientFactory`** (+ shared `SSHConnectionParameters`), now used by
  both SFTP and SCP — one audited home for the security-critical trust decision.
- **macOS 15+ gate** (user decision 2026-07-18, ADR-020): SCP needs `withExec`
  (`@available(macOS 15)`) and Citadel exposes no macOS-14 path, so `SCPSource` is
  `@available(macOS 15)` and the app blocks an SCP connect on macOS 14 with a clear message.
  **SFTP/FTP/FTPS are unaffected**; the app stays macOS 14. Metadata commands are
  macOS-14-capable — only byte transfers force the gate.
- **App**: `ConnectionManagerModel.connect` no longer info-alerts `.scp` — it runs the real
  SCP path (`startSCPConnection`, same host-key TOFU + password/key credential resolution as
  SFTP). The editor already offered SCP (SSH auth, port 22), so **no UI changes** — rule 3
  satisfied without a mockup deviation. Both flavors build (Direct + AppStore).
- **Test infra**: the milestone brief's assumption (test SCP against atmoz/sftp) was wrong —
  atmoz forces `internal-sftp` (blocks exec) **and has no scp binary**. Added a purpose-built
  exec-capable OpenSSH container (`testinfra/ssh-exec`, :2223) with the same creds + client
  key; `start.sh` now `--build`s it. **Re-run `testinfra/start.sh` after pulling M13.**
- Tests: **223 kit tests + 9 XCUITests, all green** (+35 kit / +1 UI over M12) — SCP shell-
  quote/error-mapping unit vectors; a full SCP op suite (list/stat/home/byte-exact 1 MiB
  download/600 KB round-trip/offset-skip/mkdir/delete/rename/chmod/wrong-password/missing/
  exec-blocked-server) + engine round-trip, 5-way concurrent uploads, and folder upload
  against :2223; and a UI e2e connecting via SCP and downloading through the queue.
- Self-review applied: removed a dead `import NIOSSH` from `SFTPSource` after the factory
  extraction. **M13 approved & committed (6b1e981).**

## Current state of the code (M12 — done, committed 7223169)

- **FTP and FTPS work end-to-end** over the **system libcurl** — nothing bundled (ADR-019).
  New FerryCore `FTPSource` (actor, `FileSystemSource` + `SupervisedConnection`) covers the
  full surface: home (`PWD`), list (Unix `LIST` → `FTPListParser`), stat (parent-listing
  match), chunked offset download (`REST`), sequential upload with resume (`APPE`),
  mkdir+intermediates (`MKD`), recursive delete (`DELE`/`RMD`), rename refuse-clobber
  (`RNFR`/`RNTO`), chmod (`SITE CHMOD`), ping/reestablish.
- **libcurl binding** via a tiny C target **`CFTP`** that exposes libcurl's *variadic*
  `setopt`/`getinfo` as typed functions (Swift can't call C variadics) + callback setters.
  `FTPSource` runs every blocking `curl_easy_perform` on a **detached thread** (the actor's
  executor is never blocked); C write/read/header callbacks are `@convention(c)` closures
  bridging via `Unmanaged` context. **No persistent session** — each op drives its own easy
  handle (own control+data connection), so concurrent transfers are trivially correct.
- **FTPS**: explicit `AUTH TLS` (`CURLUSESSL_ALL`) and implicit (`ftps://`). The app derives
  the mode from scheme+port (`.ftps` on 990 = implicit, else explicit). Certificates verify
  against the system trust store by default; a **cert-trust prompt** for self-signed/private-
  CA servers is deferred to the backlog (clear `.tlsFailed` error for now) — mirrors the M11
  ssh-agent split. `allowInvalidCertificate` exists in FerryCore for the test server only.
- **App**: `BrowserSession` generalized from concrete `SFTPSource` to
  `any FileSystemSource & SupervisedConnection` (which gained `disconnect()`); both backends
  conform, SCP will slot in the same way. `ConnectionManagerModel.connect` builds an
  `FTPSource` for `.ftp`/`.ftps` (password auth, prompt when none, TLS/auth error messages);
  the editor already offered FTP/FTPS + password-only auth. Both flavors build (Direct +
  App Store — libcurl is a system dylib, sandbox-safe).
- **Test infra**: a **second** vsftpd service (`ftps`, :2990, self-signed cert) added —
  a TLS vsftpd forces SSL so it can't also serve the plaintext `ftp` (:2121). Its config
  sets `require_ssl_reuse=NO` (TLS 1.3 / SecureTransport can't resume the data channel).
  **Re-run `testinfra/start.sh` after pulling** to generate the cert + start the container.
- Tests: **188 kit tests + 8 XCUITests, all green** (+33 kit / +1 UI over M11) — LIST-parser
  unit vectors; a full FTP op suite + engine round-trip + 5-way concurrent uploads against
  the Docker FTP server; explicit-FTPS connect/list/download/upload/round-trip over TLS; and
  a UI e2e that connects to the FTP server and downloads through the queue.
- Self-review applied 4 fixes (dead-connection low-speed timeout, upload read-callback
  zero-length guard, CR/LF control-channel-injection rejection in quote commands, per-chunk
  thread churn → serial queue). Cert-trust prompt deferred to backlog (user sign-off
  2026-07-18). **M12 approved & committed (7223169).**

## Earlier state (M11 — done, committed a008639)

- **`~/.ssh/known_hosts` is now read as pre-trust** (ADR-018). New read-only FerryCore
  `KnownHostsFile` parses plaintext **and** hashed (HMAC-SHA1) entries; `SFTPSource.connect`
  takes an optional `systemKnownHosts` and unions its keys into both the TOFU validator's
  trusted set and the changed-vs-unknown decision — so a host the user already knows skips
  the prompt, while a system-known host offering a *different* key still raises the
  changed-key alarm. `HostKeyStore`'s "Ferry writes only its own plaintext file" invariant
  is untouched (the reader is a separate type). Frozen at connect so auto-reconnect
  re-validates identically; the app re-reads at each connect (`FERRY_SYSTEM_KNOWN_HOSTS`
  override for tests).
- **`~/.ssh/config` Import…** (ADR-018). New FerryCore `SSHConfigParser` lifts concrete
  `Host` blocks into SFTP profiles (`HostName`/alias, `Port`, `User`, `IdentityFile`→
  public-key, tilde-expanded); wildcard/negated patterns and `Match`/`ProxyJump` are
  skipped/ignored. App: **File ▸ Import from SSH Config…** (⌘⇧I) — the canonical entry —
  plus a sidebar-toolbar Import menu, both opening `SSHImportSheet` (a checklist). Chosen
  hosts land under a new "Imported" folder; no secrets are read from the config. UI signed
  off (not in mockups, rule 3 → ADR-018). `FERRY_SSH_CONFIG` override for tests.
- **Sandbox**: both features read `~/.ssh` freely in the Direct build and **degrade
  gracefully to empty** in the App Store build (container home has no `~/.ssh`) — pre-trust
  simply doesn't apply, import reports nothing found. Bookmark-store routing deferred to M17.
- Both flavors build (Direct + AppStore). Tests: **155 kit tests + 7 XCUITests, all green**
  (+20 kit / +1 UI over checkpoint A) — incl. hashed-known_hosts vectors vs `ssh-keygen -H`,
  ssh_config field mapping + wildcard/`Match` skipping, a real-server pre-trust connect (no
  TOFU prompt) + conflicting-key CHANGED detection, and a UI walk-through of the config
  import.
- **M11 is complete** — approved & committed (a008639).

## Earlier state (M11 checkpoint A — committed ffd7233)

- **The `acceptAnything()` host-key placeholder is gone** — the shipping blocker flagged
  since M6 is closed. `SFTPSource.connect` now takes an `SSHAuthCredential` (password or
  private key) + a `HostKeyStore`, verifies the host key TOFU, and throws
  `hostKeyUnknown`/`hostKeyChanged` for the app to resolve (ADR-016). A `sessionTrusted`
  key supports "trust for this session only" (remember off) and survives auto-reconnect.
- **New FerryCore `SSH/` module**: `HostKeyInfo` (algorithm + OpenSSH SHA256 fingerprint +
  storage line, via swift-crypto — now a direct dependency), `HostKeyStore` (plaintext
  known_hosts persister, FERRY_DATA_DIR-aware), `TOFUHostKeyValidator` (rejects untrusted
  keys mid-handshake and captures the offered one), `SSHKeyLoader` (OpenSSH ed25519/RSA
  keys, encrypted or not; ECDSA + legacy PEM rejected with clear errors — ADR-017).
- **App**: `ConnectionManagerModel` drives the whole flow — key-file read + passphrase
  (Keychain `keyPassphrase`, prompt on encrypted/missing/wrong), catches host-key errors,
  and presents screen 3. New views: `HostKeyPromptSheet` (TOFU 🔑 + changed-key ⚠️ alarm
  with second-confirmation Replace) and a key-passphrase prompt. ssh-agent now reports
  "planned for a later release" instead of "M11".
- **testinfra**: `start.sh` generates a client keypair (gitignored) mounted for pubkey
  auth; `sftp.d/00-relax-sshd.sh` sets `PerSourcePenalties no` so TOFU-rejection handshakes
  don't wedge the source IP (ADR-016). **Re-run `testinfra/start.sh` after pulling.**
- Tests: **135 kit tests + 6 XCUITests, all green** (+21 kit, +1 UI over M10) — incl.
  fingerprint vectors vs `ssh-keygen`, HostKeyStore round-trip, key-loader passphrase
  branches, real ed25519 key login, TOFU unknown→trust→reconnect, session-only trust,
  changed-key detection, and a UI walk-through of the TOFU sheet.
- **Still todo in M11 (checkpoint B)**: read `~/.ssh/known_hosts` (plaintext + hashed) as
  pre-trust, and the sidebar `~/.ssh/config` Import….

## Earlier state (after M10)

- **The file-operation surface is complete.** `SFTPSource` gained `rename` (refuses to
  clobber an existing destination → `.alreadyExists`, matching LocalFileSource) and
  `setPermissions` (SETSTAT) — the FileSystemSource mutation contract is now fully live on
  both backends (ADR-015).
- App: each pane row has a context menu (Quick Look · Upload/Download · Rename… ·
  Permissions… · Delete…). Rename is an inline alert; Delete confirms with a recursive
  folder warning and states items are removed on this Mac / on the server (no Trash over
  SFTP). Operations live on `PaneModel` (rename/delete/applyPermissions/previewURL) and
  reload the pane; multi-select delete continues past a per-item failure.
- **Quick Look**: local files preview in place (`.quickLookPreview`); remote files stream
  to a temp file then preview (double-click a file previews, folders navigate).
- **chmod editor** (`PermissionsEditorSheet`): 3×3 rwx grid synced to an editable octal
  field; available on both panes.
- **Finder drag & drop**: local items now vend a file `URL` (drag to Finder + drop onto
  the remote pane = upload); remote items keep the string payload (drop onto local =
  download); Finder files dropped onto a pane enqueue a transfer (upload/copy). Each pane
  carries a `String` and a `URL` drop destination. Remote→Finder promise drag is
  backlogged (ADR-015).
- Tests: 114 kit tests + 5 XCUITests, all green — incl. SFTP rename (move, refuse-clobber,
  missing-source) + chmod round-trip against Docker sshd, and a UI rename+delete walk-
  through via the row context menu.

## Earlier state (after M9)

- **Transfers are robust.** `TransferEngine` (ADR-014): downloads stage into
  `<name>.ferrypart` and atomically rename on completion; valid partials resume
  (stale > 30 days or oversized ⇒ discarded — that's the GC); uploads resume from a
  smaller remote size. Transient failures retry 3× / 5 s resuming their own partial;
  deterministic errors fail immediately. `pause`/`resume` (paused snapshots frozen
  against zombie updates, ADR-013 discipline). Folder transfers expand lazily at the
  queue front (SFTP `createDirectory` with intermediates pulled forward from M10).
- **Connections self-heal.** `ConnectionSupervisor` actor: keep-alive ping every 30 s +
  auto-reconnect with backoff (1/2/4 s, 3 attempts) over `SupervisedConnection`;
  `SFTPSource.reestablish()` rebuilds the transport in place. Wired when the profile's
  keep-alive flag is on; a transfer exhausting retries kicks `noteFailure()`.
- App: queue rows gained pause/resume buttons + RESUMED/PAUSED badges (UPLOADING/
  DOWNLOADING replace TRANSFERRING per mockup); per-file conflict alert with
  Replace/Replace All/Skip/Skip All; folders now stage for real (skip notice removed);
  status bar shows Reconnecting (amber) / Connection lost + Reconnect (red); panes
  reload after recovery.
- Tests: 112 kit tests + 4 XCUITests, all green — incl. the kill-mid-transfer suite
  (server-side session kill, 32 MiB dd-seeded file, md5-verified resume) and supervisor
  reconnect against the real Docker sshd. Test-infra learnings recorded in ADR-014.

## Earlier state (after M8)

- **Transfers work end-to-end.** `TransferEngine` (FerryCore actor): FIFO queue,
  3-concurrent cap per connection, snapshot stream with replay, robust cancellation
  (ADR-013 — publishes cancelled + frees slot immediately, force-closes the write handle).
  `SFTPSource` gained `openWrite` (incl. truncate-to-offset resume contract) and
  recursive `delete`.
- App: `TransferQueueModel` (speed EMA + ETA) + `TransferQueueView` dock per mockup
  (progress, badges, cancel, clear, collapse). Upload/Download toolbar buttons act on
  selections; drag between panes (handle = file icon); per-batch Replace/Cancel conflict
  dialog; folders skipped with notice (M9); destination pane auto-refreshes on completion.
- M8 war stories (see ADR-013): Docker root-owned mountpoint made the SFTP upload dir
  unwritable (fixtures moved to `/fixtures`); AsyncStream bufferingNewest dropped chunks;
  whole-row `.draggable` broke double-click navigation; a happy-path-only test loop hid
  the failure as a hang.
- Tests: 84 kit tests + 4 XCUITests, all green — incl. the e2e UI flow that connects,
  browses, downloads through the queue, and verifies the file on disk.

## Earlier state (after M7)

- **Ferry now connects and browses for real.** Detail column switches on
  `ConnectionPhase`: profile summary → connecting spinner → `BrowserView` (dual panes,
  toolbar, status bar). Connect via double-click or button; password from Keychain or a
  prompt sheet with remember opt-in; typed errors for auth vs unreachable.
- `BrowserSession` + `PaneModel` (ADR-012): symmetric panes over FileSystemSources —
  sortable Table (dirs first; Name/Size/Modified/Kind-or-Perms/Owner), clickable
  breadcrumbs, per-pane hidden toggle + error alerts, back/forward history, double-click
  navigation, New Folder (works local; remote reports unsupported until M10), Refresh,
  toolbar filter on the active pane, Disconnect. **Sync browsing** per DESIGN.md: linked
  toggle, anchor mirroring (PathUtilities, unit-tested), flash-and-stay on missing
  counterpart.
- Upload/Download buttons present but inform "M8"; queue dock, tabs, Quick Look pending
  (see DESIGN.md → Implementation status).
- Tests: 73 in FerryKit + 4 XCUITests, all green — incl. the M7 e2e walk-through
  (create → connect via password prompt → browse the Docker server → disconnect).

## Earlier state (after M6)

- **Citadel 0.12.1 adopted as the SSH stack** (ADR-011) — spike succeeded; first
  third-party dependency, licenses recorded in LICENSING.md before adding.
- `FerryCore/FileSystem/SFTPSource`: actor conforming to FileSystemSource. Read side
  complete: connect (password auth; typed RemoteSourceError), homeDirectory (realpath),
  list with attributes + owner/group from longname, stat, chunked offset openRead
  (128 KiB, EOF = empty buffer). Mutations/openWrite throw `.unsupported(operation:)`
  until M8/M10. Host keys: acceptAnything with TODO(M11) — must not ship past M11.
- Error normalization: raw `SFTPMessage.Status` AND `SFTPError.errorStatus` both map to
  typed FileSystemSourceError (noSuchFile→notFound, permissionDenied→permissionDenied).
- Tests: 69 total, all green (10 SFTP integration tests against the Docker server incl.
  wrong-password auth failure and byte-exact 1 MiB multi-chunk download).

## Earlier state (after M5)

- `FerryCore/FileSystem/`: `FileSystemSource` protocol (the core abstraction, ARCHITECTURE.md
  updated with the exact shape incl. the offset-based resume contract), `FileItem` +
  `FilePermissions` (octal/symbolic), `FileWriteHandle`, typed `FileSystemSourceError`.
- `LocalFileSource`: full conformance over FileManager/FileHandle — listing with hidden
  filter + owner/perms metadata, stat with symlink detection, mkdir (intermediates),
  recursive delete, rename (refuses overwrite), chmod, chunked streaming read (256 KB,
  offset-aware), sequential write handle honoring truncate-to-offset-then-append.
- `SecurityScopedBookmarkStore`: persisted folder grants, deepest-match resolution,
  stale-bookmark refresh, pass-through without grants; composed into LocalFileSource
  (one code path for Direct and App Store builds).
- Tests: 59 total, all green (new: 4 unit FilePermissions; 11 LocalFileSource + 4 bookmark
  integration tests on the real filesystem).

## Earlier state (after M4)

- App UI (per DESIGN.md screens 1–2): `MainWindow` (NavigationSplitView),
  `SidebarView` (folder tree with disclosure state persisted, protocol badges, context
  menus incl. Move-to, drag onto folders / "Connections" header, delete confirmations
  that mention Keychain cleanup, "This Mac" stub section), `ConnectionEditorSheet`
  (protocol-adaptive form, password/key/agent auth with Keychain hint, Advanced group,
  live Test Connection via TCP probe), `DetailPlaceholderView` (summary + stubbed Connect).
- `ConnectionManagerModel` (@Observable, main-actor): persists every mutation, mediates
  vault (secrets follow auth-method changes; duplicate copies secrets; delete cleans up,
  including nested profiles when deleting a folder). Test isolation via FERRY_DATA_DIR /
  FERRY_KEYCHAIN_SERVICE env vars.
- FerryCore additions: `parentFolderID(ofItem:)`, `allFolders`, `ReachabilityProbe` (TCP).
- Known scope notes: within-folder index reordering by drag is deferred to M16 (drop-on-
  folder + Move-to menu work now); Test Connection is TCP reachability until M6's real
  protocol handshake; "This Mac" items are non-functional until M5/M7.
- Tests: 40 in FerryKit (all green) + 3 XCUITests (all green, isolated store).

## Earlier state (after M3)

- `FerryCore/Store/CredentialVault`: Keychain wrapper — roles `password`/`keyPassphrase`
  per profile UUID, upsert store, nil-on-absent retrieve, idempotent delete, `deleteAll`
  for profile removal. Login keychain, WhenUnlocked accessibility (ADR-010).
- Tests: 35 total, all green (unit: account-format contract; integration: 8 real-Keychain
  tests with self-cleaning test service).

## Earlier state (after M2)

- `FerryCore/Models`: `ConnectionProfile` (no secrets; port defaults per protocol),
  `TransferProtocol` (sftp/ftp/ftps/scp), `AuthenticationMethod` (password/publicKey/agent),
  `TunnelConfiguration` (schema fixed early for M14), `ProfileFolder` + `SidebarItem`
  (recursive tree, clean JSON discriminator), `ConnectionLibrary` (queries + add/remove/
  update/rename/move with cycle protection).
- `FerryCore/Store/ConnectionStore`: stateless JSON persister — atomic writes, intermediate
  dirs, ISO8601 dates, sortedKeys stability, schemaVersion probe with precise
  newer-version error (ADR-009). Default path: `~/Library/Application Support/Ferry/connections.json`.
- Tests: 24 total (16 unit + 8 integration incl. 6 real-filesystem persistence tests), all green.

## Earlier state (after M1)

- Xcode project `Ferry.xcodeproj` (hand-authored, objectVersion 77) with app target `Ferry` + `FerryUITests`; 4 build configurations (Debug/Release × Direct/AppStore) and 2 shared schemes (`Ferry-Direct`, `Ferry-AppStore`). Builds clean.
- `FerryKit` local SwiftPM package holds all future core logic. Currently: `FerryVersion` placeholder + 1 unit test + 2 integration smoke tests (SSH banner / FTP greeting) — all passing.
- Docker test infra (`testinfra/`): SFTP on 127.0.0.1:2222, FTP on 2121 (`ferry`/`ferrypass`), seeded fixtures; `start.sh`/`stop.sh` verified working.
- App shows a branded placeholder window; approved icon (concept A) generated into the asset catalog by `tools/generate-appicon.swift`.
- All docs written (see CLAUDE.md doc map). Nothing committed yet — first commit happens on M1 approval.

## Known issues / open items

- Bundle id `com.gfragos.Ferry` and ad-hoc signing are placeholders until the user has an Apple Developer account (BUILDING.md).
- Trademark/domain check for the name "Ferry" is the user's task before sale.

## Next steps

1. **Review M13**, then commit on approval (two-commit pattern: work commit, then a "Mark
   M13 done in PROGRESS.md" commit recording the hash).
2. **M14 — Tunneling** (`TunnelEngine` + tunnel manager UI, screen 4: local/remote/SOCKS,
   auto-start). The new exec-capable :2223 SSH server also supports future exec-based
   features (M15 Open in Terminal).
3. Backlog: FTPS **certificate-trust prompt** (TLS analogue of host-key TOFU, for self-
   signed/private-CA servers — deferred from M12, ADR-019); FTP connection pooling
   (`CURLSH`) to avoid a login per op; per-file `MDTM` for precise FTP mtimes; remote→Finder
   file-promise drag (`NSFilePromiseProvider`, M10); route `~/.ssh` reads through the
   bookmark store for the App Store sandbox (M17, ADR-018).

## Session log

- **2026-07-18** — M13 built (SCP over an SSH exec channel, ADR-020). New FerryCore
  `SCPSource` (actor) reuses the M11 SSH stack via a new **`SSHClientFactory`** (host-key
  TOFU + password/key auth extracted from `SFTPSource` so both share one audited connect).
  Split surface: **metadata via POSIX commands over exec** (`pwd`/`ls -la`/`ls -ld`/`mkdir`/
  `rm -rf`/`mv`/`chmod`, shell-quoted + `--`, `ls` parsed by the reused Unix parser) and
  **bytes via the classic scp protocol** (`scp -f`/`scp -t`) over Citadel's `withExec`.
  Compromises (DOMAIN.md): no resume (download re-reads from start but stream begins at
  offset; upload rejects offset > 0), upload buffers to a local temp + stages to a remote
  `.ferry-scp-part` renamed on success (avoids poisoning the engine's retry). Handled
  `withExec`'s "Already closed" cleanup masking (drivers report out-of-band via the stream
  continuation / an `UploadOutcome`). **macOS 15+ gate** (user decision): `withExec` is
  macOS 15 and Citadel has no macOS-14 path, so `SCPSource` is `@available(macOS 15)` and the
  app blocks SCP on macOS 14 with a clear message; SFTP/FTP/FTPS + the macOS-14 target are
  unaffected. App runs the real SCP connect (`startSCPConnection`); editor already offered
  SCP so **no UI change** (rule 3 met). **Test-infra deviation**: atmoz/sftp can't serve SCP
  (forces `internal-sftp`, no scp binary), so a purpose-built exec-capable OpenSSH container
  (`testinfra/ssh-exec`, :2223, same creds + key) was added; `start.sh` now `--build`s it.
  223 kit + 9 UI tests green (+35/+1); both flavors build. Self-review removed a dead
  `import NIOSSH`. **M13 approved & committed (6b1e981).**
- **2026-07-18** — M12 built (FTP/FTPS via system libcurl, ADR-019). New `CFTP` C target
  wraps libcurl's variadic `setopt`/`getinfo` (Swift can't call C variadics) + callback
  setters; `FTPSource` (actor) implements the whole `FileSystemSource`+`SupervisedConnection`
  surface with **per-operation easy handles** (no persistent session → concurrent transfers
  are trivially safe), running every blocking `curl_easy_perform` on a detached thread and
  bridging download (push→`AsyncThrowingStream`) and upload (push→pull, bounded-buffer
  backpressure) via `@convention(c)` callbacks. Absolute paths via libcurl's `%2F` root
  anchor; home via `PWD`; stat via parent listing; `FTPListParser` for Unix `LIST` (pure,
  unit-tested). FTPS explicit/implicit (`CURLUSESSL_ALL` / `ftps://`), system-trust
  verification, cert-trust prompt deferred to backlog. `BrowserSession` generalized to
  `any FileSystemSource & SupervisedConnection` (added `disconnect()`); app connects
  `.ftp`/`.ftps` with password auth + TLS/auth error mapping. Test infra gained a second
  TLS vsftpd (`ftps`:2990, self-signed cert, `require_ssl_reuse=NO`). 188 kit + 8 UI tests
  green (+33/+1); both flavors build. Self-review applied 4 hardening fixes; cert-trust
  prompt deferred to backlog (user sign-off). **M12 approved & committed.**
- **2026-07-05** — Project inception. Requirements gathered; plan approved (18 milestones). M0: mockups of 5 screens + icon concepts built and iterated (sync browsing added on user request); user approved mockups + icon A. M1: repo initialized, Xcode project + FerryKit package + test targets created, Docker test infra up, icon generated, all docs written. All suites green: 1 unit + 2 integration + 1 UI test (user enabled DevToolsSecurity). M1 approved & committed (97fccf4).
- **2026-07-05 (cont.)** — M2 built: domain models (profile/folder tree/tunnels/auth), ConnectionLibrary operations with cycle-protected move, ConnectionStore JSON persistence (ADR-009). 24 tests green (one test-side fix: stability check had regenerated UUIDs). App builds. M2 approved & committed (18d38e5).
- **2026-07-05 (cont.)** — M3 built: CredentialVault Keychain wrapper (ADR-010: login keychain so `swift test` works unsigned; revisit at M17 for App Store). 35 tests green incl. 8 real-Keychain integration tests. M3 approved & committed (dff4ded).
- **2026-07-05 (cont.)** — M4 built: connection manager UI (sidebar tree, editor sheet, detail summary, folder prompts, drag-to-folder, Move-to menu), ConnectionManagerModel with vault-aware save/delete/duplicate, ReachabilityProbe + hierarchy queries in FerryCore. 40 kit tests + 3 UI tests green. M4 approved & committed (3d17f7c).
- **2026-07-05 (cont.)** — M5 built: FileSystemSource protocol + FileItem/FilePermissions/FileWriteHandle, LocalFileSource (streaming I/O with resume offset contract), SecurityScopedBookmarkStore composed in. 59 tests green. M5 approved & committed (27e1dfe).
- **2026-07-05 (cont.)** — M6 spike: Citadel 0.12.1 added (licenses recorded first), SFTPSource read-only implemented and validated against Docker sshd. Verdict: adopt Citadel, libssh2 fallback retired (ADR-011). Two fixes during spike: error normalization (raw Status thrown), @preconcurrency import for Swift 6. 69 tests green. M6 approved & committed (3c9567a).
- **2026-07-05 (cont.)** — M7 built: BrowserSession/PaneModel (ADR-012), FileBrowserPane + BrowserView per mockup screen 1, connect lifecycle with password prompt, sync browsing (PathUtilities moved to FerryCore for unit-testability). 73 kit tests + 4 UI tests green incl. e2e connect-and-browse. M7 approved & committed (c23cf04).
- **2026-07-05 (cont.)** — M8 built: TransferEngine + queue dock + SFTP uploads/delete + drag between panes. Debugging saga (all fixed, ADR-013): SFTP writes "hung" → root cause was Docker's root-owned mountpoint making /upload unwritable, masked by a happy-path-only test loop; hardened engine cancellation anyway (immediate cancelled state, force-close handle); fixed chunk-dropping stream buffering; fixed whole-row draggable breaking double-click. 84 kit + 4 UI tests green incl. e2e download through the queue. M8 approved & committed (b1c9394).
- **2026-07-17** — M11 checkpoint B built (known_hosts pre-trust + `~/.ssh/config` import,
  ADR-018): read-only `KnownHostsFile` (plaintext + hashed HMAC-SHA1, pinned to `ssh-keygen
  -H`) folded into `SFTPSource`'s TOFU trusted set + changed/unknown decision, wired via a
  new `systemKnownHosts` connect param (frozen for reconnect; `FERRY_SYSTEM_KNOWN_HOSTS`
  override). `SSHConfigParser` → `SSHImportSheet` checklist reached from **File ▸ Import from
  SSH Config…** (⌘⇧I; the sidebar toolbar's third control folds into the toolbar overflow on
  narrow windows, so the menu command is canonical — UI signed off, not in mockups → ADR-018).
  Imports land under an "Imported" folder; no secrets read from config. Both features degrade
  to empty in the App Store sandbox. 155 kit + 7 UI tests green (+20/+1). Both flavors build.
  Code review applied two fixes (imported profiles default the username to the local login
  name à la OpenSSH; changed-key alarm de-dups stored fingerprints). Security review: clean.
- **M11 is complete** (approved & committed a008639).
- **2026-07-17** — M11 checkpoint A built (key auth + host-key TOFU): removed the
  `acceptAnything()` host-key placeholder (M6 shipping blocker closed). New FerryCore `SSH/`
  module — `HostKeyInfo`/`HostKeyStore`/`TOFUHostKeyValidator`/`SSHKeyLoader`; `SFTPSource`
  now verifies host keys TOFU and takes password-or-key credentials; app drives screen 3
  (TOFU + changed-key alarm) + key-passphrase prompt; ssh-agent deferred to backlog
  (ADR-016/017). swift-crypto promoted to a direct dependency. testinfra gained a client
  keypair mount + `PerSourcePenalties no` boot hook (OpenSSH 9.8 penalises TOFU-rejection
  handshakes). 135 kit + 6 UI tests green. **Awaiting review; checkpoint B (known_hosts
  pre-trust + ssh/config import) still to do before M11 is complete.**
- **2026-07-17** — M10 built: SFTP `rename` + `setPermissions` (completing the mutation
  surface on both backends); per-row context menu (Quick Look/Upload·Download/Rename/
  Permissions/Delete); rename alert + delete confirmation (recursive folder warning, no
  Trash); `PermissionsEditorSheet` chmod grid; Quick Look (local in place, remote via temp
  download); Finder drag & drop via a drag-payload split (local items vend file URLs, remote
  items keep the string payload) + a URL drop destination per pane (ADR-015). Remote→Finder
  promise drag backlogged. Test notes: alert TextFields don't expose identifiers (type into
  the auto-focused field); alert buttons live under `windows`, not `dialogs` (Touch Bar dup);
  the context Delete uses "Delete…" to stay unique vs AppKit's Edit▸Delete. 114 kit + 5
  XCUITests green. M10 approved & committed (9cfe66a).
- **2026-07-05 (cont.)** — M9 built: `.ferrypart` staging + resume, pause/resume, transient-error retry policy, lazy folder transfers (SFTP mkdir pulled forward), ConnectionSupervisor keep-alive/auto-reconnect, per-file conflict dialog with apply-to-all, reconnect status bar (ADR-014). Test saga: closing the local SSHClient mid-read fatalErrors NIOSSH → kill-mid-transfer tests drop the session server-side (`docker exec pkill`, matching OpenSSH ≥ 9.8 `sshd-session` naming) on a 32 MiB dd-seeded file; first run hung forever because `for await` deadline checks never fire on silent streams → test waits now race a timer. 112 kit + 4 UI tests green. M9 approved & committed (388de0d).
