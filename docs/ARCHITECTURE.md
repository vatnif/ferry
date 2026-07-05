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
├── ConnectionManagerView      sidebar: folder tree, profiles, CRUD, drag-reorder
├── BrowserWindow              tabs; per tab: dual pane + queue + status bar
│   ├── FileBrowserView ×2     same component for local & remote panes
│   └── TransferQueueView
├── TunnelManagerView, SettingsScene, HostKeyPromptSheet
└── view models (ObservableObject/@Observable, main-actor)

FerryCore (FerryKit package)
├── FileSystemSource (protocol)          ← the heart; panes & engine are protocol-agnostic
│   ├── LocalFileSource                  FileManager + security-scoped bookmarks
│   ├── SFTPSource                       Citadel (M6 spike; fallback libssh2)
│   ├── FTPSource                        system libcurl (M12)
│   └── SCPSource                        SSH exec channel (M13)
├── TransferEngine (actor)               queue, concurrency caps, retry, resume
├── SSHSessionManager (actor)            one SSH session shared by SFTP + tunnels + exec
├── TunnelEngine                         local / remote / SOCKS forwards (M14)
├── ConnectionStore                      profiles + folder tree, JSON, NO secrets
├── CredentialVault                      Keychain wrapper (M3)
├── HostKeyStore                         Ferry known-hosts + TOFU decisions (M11)
├── SSHConfigImporter                    ~/.ssh/config, known_hosts (read-only) (M11)
└── FerryVersion, Logging
```

## Key design decisions

- **`FileSystemSource` protocol** exposes `list/stat/readStream/writeStream/delete/rename/
  mkdir/setPermissions` (exact shape defined in M5). Panes and the TransferEngine only see
  this protocol, so WebDAV/S3 later are new conformances, not rewrites, and the local pane
  is "just another source" (which also enables remote↔remote later).
- **Session sharing**: `SSHSessionManager` owns one authenticated SSH connection per
  profile; SFTP channels, exec channels (SCP, terminal prep) and tunnels multiplex over it.
- **Resume semantics** (details in DOMAIN.md): downloads write `name.ferrypart` and restart
  from its size (SFTP seek / FTP `REST`); uploads probe remote size and continue.
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
