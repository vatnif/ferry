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
| M5 | FileSystemSource protocol + LocalFileSource | **awaiting review** |
| M6 | SFTP spike → SFTPSource (read-only) | todo |
| M7 | Dual-pane browser UI | todo |
| M8 | TransferEngine + queue UI | todo |
| M9 | Resume & robustness | todo |
| M10 | File operations | todo |
| M11 | Key auth & host trust | todo |
| M12 | FTP/FTPS via libcurl | todo |
| M13 | SCP | todo |
| M14 | Tunneling | todo |
| M15 | Open in Terminal | todo |
| M16 | Tabs & polish | todo |
| M17 | Packaging (sign/notarize/DMG/Sparkle) | todo |
| M18 | Sale readiness | todo |

Backlog (post-v1): see `docs/ROADMAP.md`.

## Current state of the code (after M5)

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

1. User reviews M5 → on approval: commit.
2. M6: SSH library spike — add Citadel (MIT, over swift-nio-ssh Apache-2.0) as the first
   third-party dependency (record in LICENSING.md BEFORE adding, CLAUDE.md rule 4);
   validate connect/auth/list/download against the Docker SSH server; pivot to libssh2
   if it fails; read-only `SFTPSource` conformance + integration tests + ADR.

## Session log

- **2026-07-05** — Project inception. Requirements gathered; plan approved (18 milestones). M0: mockups of 5 screens + icon concepts built and iterated (sync browsing added on user request); user approved mockups + icon A. M1: repo initialized, Xcode project + FerryKit package + test targets created, Docker test infra up, icon generated, all docs written. All suites green: 1 unit + 2 integration + 1 UI test (user enabled DevToolsSecurity). M1 approved & committed (97fccf4).
- **2026-07-05 (cont.)** — M2 built: domain models (profile/folder tree/tunnels/auth), ConnectionLibrary operations with cycle-protected move, ConnectionStore JSON persistence (ADR-009). 24 tests green (one test-side fix: stability check had regenerated UUIDs). App builds. M2 approved & committed (18d38e5).
- **2026-07-05 (cont.)** — M3 built: CredentialVault Keychain wrapper (ADR-010: login keychain so `swift test` works unsigned; revisit at M17 for App Store). 35 tests green incl. 8 real-Keychain integration tests. M3 approved & committed (dff4ded).
- **2026-07-05 (cont.)** — M4 built: connection manager UI (sidebar tree, editor sheet, detail summary, folder prompts, drag-to-folder, Move-to menu), ConnectionManagerModel with vault-aware save/delete/duplicate, ReachabilityProbe + hierarchy queries in FerryCore. 40 kit tests + 3 UI tests green. M4 approved & committed (3d17f7c).
- **2026-07-05 (cont.)** — M5 built: FileSystemSource protocol + FileItem/FilePermissions/FileWriteHandle, LocalFileSource (streaming I/O with resume offset contract), SecurityScopedBookmarkStore composed in. 59 tests green. M5 awaiting review.
