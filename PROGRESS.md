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
| M11 | Key auth & host trust | todo |
| M12 | FTP/FTPS via libcurl | todo |
| M13 | SCP | todo |
| M14 | Tunneling | todo |
| M15 | Open in Terminal | todo |
| M16 | Tabs & polish | todo |
| M17 | Packaging (sign/notarize/DMG/Sparkle) | todo |
| M18 | Sale readiness | todo |

Backlog (post-v1): see `docs/ROADMAP.md`.

## Current state of the code (after M10)

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

1. M11: key auth + host-key TOFU UI (screen 3), known_hosts + `~/.ssh/config` import.
   Note: `SFTPSource` still uses `hostKeyValidator: .acceptAnything()` (TODO in the
   source) — M11 must replace it before shipping.
2. Backlog surfaced in M10: remote→Finder file-promise drag (`NSFilePromiseProvider`).

## Session log

- **2026-07-05** — Project inception. Requirements gathered; plan approved (18 milestones). M0: mockups of 5 screens + icon concepts built and iterated (sync browsing added on user request); user approved mockups + icon A. M1: repo initialized, Xcode project + FerryKit package + test targets created, Docker test infra up, icon generated, all docs written. All suites green: 1 unit + 2 integration + 1 UI test (user enabled DevToolsSecurity). M1 approved & committed (97fccf4).
- **2026-07-05 (cont.)** — M2 built: domain models (profile/folder tree/tunnels/auth), ConnectionLibrary operations with cycle-protected move, ConnectionStore JSON persistence (ADR-009). 24 tests green (one test-side fix: stability check had regenerated UUIDs). App builds. M2 approved & committed (18d38e5).
- **2026-07-05 (cont.)** — M3 built: CredentialVault Keychain wrapper (ADR-010: login keychain so `swift test` works unsigned; revisit at M17 for App Store). 35 tests green incl. 8 real-Keychain integration tests. M3 approved & committed (dff4ded).
- **2026-07-05 (cont.)** — M4 built: connection manager UI (sidebar tree, editor sheet, detail summary, folder prompts, drag-to-folder, Move-to menu), ConnectionManagerModel with vault-aware save/delete/duplicate, ReachabilityProbe + hierarchy queries in FerryCore. 40 kit tests + 3 UI tests green. M4 approved & committed (3d17f7c).
- **2026-07-05 (cont.)** — M5 built: FileSystemSource protocol + FileItem/FilePermissions/FileWriteHandle, LocalFileSource (streaming I/O with resume offset contract), SecurityScopedBookmarkStore composed in. 59 tests green. M5 approved & committed (27e1dfe).
- **2026-07-05 (cont.)** — M6 spike: Citadel 0.12.1 added (licenses recorded first), SFTPSource read-only implemented and validated against Docker sshd. Verdict: adopt Citadel, libssh2 fallback retired (ADR-011). Two fixes during spike: error normalization (raw Status thrown), @preconcurrency import for Swift 6. 69 tests green. M6 approved & committed (3c9567a).
- **2026-07-05 (cont.)** — M7 built: BrowserSession/PaneModel (ADR-012), FileBrowserPane + BrowserView per mockup screen 1, connect lifecycle with password prompt, sync browsing (PathUtilities moved to FerryCore for unit-testability). 73 kit tests + 4 UI tests green incl. e2e connect-and-browse. M7 approved & committed (c23cf04).
- **2026-07-05 (cont.)** — M8 built: TransferEngine + queue dock + SFTP uploads/delete + drag between panes. Debugging saga (all fixed, ADR-013): SFTP writes "hung" → root cause was Docker's root-owned mountpoint making /upload unwritable, masked by a happy-path-only test loop; hardened engine cancellation anyway (immediate cancelled state, force-close handle); fixed chunk-dropping stream buffering; fixed whole-row draggable breaking double-click. 84 kit + 4 UI tests green incl. e2e download through the queue. M8 approved & committed (b1c9394).
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
