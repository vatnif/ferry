# Ferry — Architecture

*Update this document whenever module structure, layering, or concurrency rules change.*

## Overview

Two build products, one codebase:

- **Ferry.app** (Xcode target `Ferry`) — thin SwiftUI shell: windows, views, view models.
- **FerryKit** (local SwiftPM package, library `FerryCore`) — everything else: protocol
  backends, transfer engine, stores, tunneling. Headless-testable via `swift test`.

Rule of thumb: if it can be tested without a window, it lives in FerryKit.

```
Ferry.app (SwiftUI, @MainActor)
├── SidebarView (M4)           folder tree, profiles, CRUD, drag-to-folder
├── ConnectionEditorSheet (M4) protocol-adaptive form + Test Connection
├── BrowserView (M7)           dual pane + toolbar + status bar (tabs: M16)
│   └── FileBrowserPane ×2     same component for local & remote panes
├── TransferQueueView (M8), TunnelManagerView (M14), Settings (M16)
└── view models (@Observable, main-actor):
    ├── ConnectionManagerModel  library persistence, vault mediation,
    │                           connect lifecycle (ConnectionPhase state)
    └── BrowserSession + PaneModel (M7/M9)
        one session = two PaneModels over FileSystemSources; navigation with
        history, sync-browsing anchors/mirroring (PathUtilities in FerryCore),
        active-pane tracking for the toolbar filter/nav; owns the per-
        connection TransferQueueModel + ConnectionSupervisor (health for the
        status bar, pane reload after reconnect)

FerryCore (FerryKit package)
├── FileSystemSource (protocol)          ← the heart; panes & engine are protocol-agnostic
│   ├── LocalFileSource                  FileManager + security-scoped bookmarks
│   ├── SFTPSource                       Citadel (ADR-011); TOFU host-key verify +
│   │                                    password/key auth (M11, ADR-016/017)
│   ├── FTPSource                        system libcurl (M12)
│   └── SCPSource                        SSH exec channel (M13)
├── TransferEngine (actor, M8/M9)        FIFO queue, concurrency cap (3/connection),
│                                        snapshot stream w/ replay, robust cancel
│                                        (ADR-013); M9: .ferrypart staging + resume,
│                                        pause/resume, transient-error retry (3×/5 s),
│                                        lazy directory expansion (ADR-014)
├── ConnectionSupervisor (actor, M9)     keep-alive ping (30 s) + auto-reconnect with
│                                        backoff over a SupervisedConnection
│                                        (ping/reestablish — SFTPSource conforms)
├── SSHSessionManager (actor)            one SSH session shared by SFTP + tunnels + exec
├── TunnelEngine                         local / remote / SOCKS forwards (M14)
├── ConnectionStore                      profiles + folder tree, JSON, NO secrets
├── CredentialVault                      Keychain wrapper (M3)
├── SSH/ (M11)                           HostKeyStore (Ferry known_hosts, plaintext),
│                                        HostKeyInfo (algo + SHA256 fingerprint + OpenSSH
│                                        line), TOFUHostKeyValidator (rejects untrusted
│                                        keys mid-handshake), SSHKeyLoader (ed25519/RSA
│                                        OpenSSH keys + passphrase) — ADR-016/017
├── SSHConfigImporter                    ~/.ssh/config, known_hosts (read-only) (M11-B)
└── FerryVersion, Logging
```

## Key design decisions

- **`FileSystemSource` protocol** (defined M5, `FerryCore/FileSystem/`): `homeDirectory`,
  `list(directory:includeHidden:)`, `stat`, `createDirectory`, `delete` (recursive),
  `rename`, `setPermissions`, and streaming I/O — `openRead(at:offset:)` returns an
  `AsyncThrowingStream<Data,_>`, `openWrite(at:offset:)` returns a sequential
  `FileWriteHandle`. **Offset contract** (the resume seam): read starts at byte `offset`;
  write truncates the target to `offset` then appends (offset 0 = overwrite). Items are
  `FileItem` (+ `FilePermissions` with octal/symbolic helpers); errors are the typed
  `FileSystemSourceError`. Panes and the TransferEngine only see this protocol, so
  WebDAV/S3 later are new conformances, not rewrites, and the local pane is "just another
  source" (which also enables remote↔remote later).
- **Session sharing**: `SSHSessionManager` owns one authenticated SSH connection per
  profile; SFTP channels, exec channels (SCP, terminal prep) and tunnels multiplex over it.
- **Resume semantics** (implemented M9; details in DOMAIN.md + ADR-014): downloads write
  `name.ferrypart` and restart from its size (SFTP seek / FTP `REST`), atomically renamed
  into place on completion; uploads probe remote size and continue. The engine owns all
  of it — backends only implement the M5 offset contract.
- **Connection robustness** (M9): `ConnectionSupervisor` pings and reconnects any
  `SupervisedConnection`; `SFTPSource.reestablish()` rebuilds its transport in place so
  panes/transfers keep their source reference across drops.
- **UI fidelity**: views implement `docs/DESIGN.md` / the approved mockups 1:1.

## Concurrency model (Swift 6, strict)

- UI layer is `@MainActor`. View models are main-actor and talk to FerryCore via `async`.
- Long-lived mutable state (sessions, queue) lives in **actors** (`TransferEngine`,
  `SSHSessionManager`). Value types (`ConnectionProfile`, `FileItem`) are `Sendable`.
- No completion handlers in new code; `async/await` + `AsyncSequence` for progress streams.

## Build configurations

4 configurations = Debug/Release × Direct/AppStore; schemes `Ferry-Direct`, `Ferry-AppStore`.

| | Direct | AppStore |
|---|---|---|
| Entitlements | `Ferry-Direct.entitlements` (no sandbox) | `Ferry-AppStore.entitlements` (sandbox + network client + user-selected files + bookmarks) |
| Compilation condition | — | `APPSTORE` |
| Extras | Hardened runtime, later Sparkle | later App Store receipt |

Feature gating: `#if APPSTORE` only at capability seams (ssh-agent, launch-Terminal,
Sparkle); everything else must work identically in both flavors.

## Xcode project mechanics

`Ferry.xcodeproj` is hand-authored (objectVersion 77). Targets use
**PBXFileSystemSynchronizedRootGroup** — the `Ferry/` and `FerryUITests/` folders are
synchronized, so adding/removing source files needs **no pbxproj edits**. The two
entitlements files are excluded from target membership via an exception set. FerryKit is
attached as `XCLocalSwiftPackageReference` with product dependency `FerryCore`.
