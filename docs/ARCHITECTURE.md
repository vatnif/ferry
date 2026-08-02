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
├── SidebarView (M4)           folder tree, profiles, CRUD, drag-to-folder +
│                              within-folder drag reorder (M16, ADR-027)
├── ConnectionEditorSheet (M4) protocol-adaptive form + Test Connection
├── TabStripView (M16)         one chip per ConnectionTab (green/grey dot),
│                              ＋/✕; selected chip drives the detail column
├── BrowserView (M7)           dual pane + toolbar + status bar (per selected tab)
│   └── FileBrowserPane ×2     same component for local & remote panes
├── TransferQueueView (M8), TunnelManagerView (M14), Settings (M16)
├── HelpGuideWindowView + AcknowledgementsWindowView (M16 C, ADR-028)
│                              standalone Help-menu Window scenes rendering the
│                              pure HelpContent + Acknowledgements FerryCore models
└── view models (@Observable, main-actor):
    ├── ConnectionManagerModel  library persistence, vault mediation,
    │                           connect lifecycle; owns tabs:
    │                           OrderedTabs<ConnectionTab> (M16, ADR-027) —
    │                           each ConnectionTab has its own ConnectionPhase
    │                           (.idle/.connecting/.connected(BrowserSession)).
    │                           OrderedTabs (add/select/close/move) is a pure,
    │                           unit-tested FerryCore value type.
    └── BrowserSession + PaneModel (M7/M9) — one per connected tab
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
│   ├── FTPSource                        system libcurl via the CFTP shim (M12,
│   │                                    ADR-019); FTP + explicit/implicit FTPS,
│   │                                    per-operation easy handles (no session)
│   └── SCPSource                        SSH exec channel (M13, ADR-020); metadata via
│                                        POSIX commands (ls/mkdir/rm/mv/chmod), bytes via
│                                        the scp wire protocol; macOS 15+ (withExec)
├── TransferEngine (actor, M8/M9)        FIFO queue, concurrency cap (3/connection),
│                                        snapshot stream w/ replay, robust cancel
│                                        (ADR-013); M9: .ferrypart staging + resume,
│                                        pause/resume, transient-error retry (3×/5 s),
│                                        lazy directory expansion (ADR-014)
├── ConnectionSupervisor (actor, M9)     keep-alive ping (30 s) + auto-reconnect with
│                                        backoff over a SupervisedConnection
│                                        (ping/reestablish — SFTPSource conforms)
├── TunnelEngine                         local / remote / SOCKS forwards (M14)
├── TerminalSession (actor, M15.5)       interactive PTY shell over Citadel withPTY
│                                        (macOS 15+ like SCP, ADR-023); dedicated SSH
│                                        session via SSHClientFactory; out-of-band
│                                        end-reason classification (TerminalEndClassifier)
├── ConnectionStore                      profiles + folder tree, JSON, NO secrets
├── CredentialVault                      Keychain wrapper (M3)
├── SSH/ (M11)                           HostKeyStore (Ferry known_hosts, plaintext),
│                                        HostKeyInfo (algo + SHA256 fingerprint + OpenSSH
│                                        line), TOFUHostKeyValidator (rejects untrusted
│                                        keys mid-handshake), SSHKeyLoader (ed25519/RSA
│                                        OpenSSH keys + passphrase) — ADR-016/017;
│                                        SSHClientFactory (M13) — shared host-key TOFU +
│                                        auth connect used by SFTPSource and SCPSource
├── SSHConfigImporter                    ~/.ssh/config, known_hosts (read-only) (M11-B)
├── FTPListParser                         Unix `ls -l` LIST → FileItem (pure, M12; also
│                                        parses SCP's `ls -la`/`ls -ld`, M13)
├── Help/ (M16 C, ADR-028)               pure content for the Help-menu windows:
│                                        HelpContent (topics + shortcut reference) and
│                                        Acknowledgements (license notices) — unit-tested
└── FerryVersion, Logging

CFTP (separate SwiftPM C target)          thin non-variadic shim over the system
                                          libcurl so Swift can call setopt/getinfo;
                                          links `curl`. FerryCore depends on it (M12).

FerryTerminalUI (second FerryKit product, M15.5)
├── TerminalSessionBridge                 SwiftTerm TerminalViewDelegate ⇄ TerminalSession
│                                         (keystrokes → send, resize → window-change,
│                                         output stream → feed on the main actor)
└── SSHTerminalView                       NSViewRepresentable host for SwiftTerm's
                                          TerminalView (theme-following native colors)
                                          — kept out of FerryCore so the core stays
                                          UI-free; depends on SwiftTerm (MIT, ADR-023)
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
- **Session per subsystem** (ADR-021/023): each SSH subsystem — `SFTPSource`/`SCPSource`
  (browser), `TunnelEngine`, `TerminalSession` — owns its own authenticated session,
  all built by `SSHClientFactory` (one audited home for host-key TOFU + auth) and
  reusing the profile's already-resolved credential, so nothing re-prompts. A
  multiplexed `SSHSessionManager` (one session shared by all of them) is a backlog
  item, not current architecture.
- **Resume semantics** (implemented M9; details in DOMAIN.md + ADR-014): downloads write
  `name.ferrypart` and restart from its size (SFTP seek / FTP `REST`), atomically renamed
  into place on completion; uploads probe remote size and continue. The engine owns all
  of it — backends only implement the M5 offset contract.
- **Connection robustness** (M9): `ConnectionSupervisor` pings and reconnects any
  `SupervisedConnection`; `SFTPSource.reestablish()` rebuilds its transport in place so
  panes/transfers keep their source reference across drops.
- **UI fidelity**: views implement `docs/DESIGN.md` / the approved mockups 1:1.
- **Per-tab view identity** (ADR-035): every connected tab renders `BrowserView` at the
  same structural position, so anything that must not be shared between tabs needs an
  explicit `.id(...)` or a home on `BrowserSession`. This is load-bearing for AppKit-backed
  views — an `NSViewRepresentable`'s `makeNSView` runs once per identity, so a shared slot
  silently re-hosts one tab's live NSView for another's model (`SSHTerminalView` carries
  `.id(controller.id)`; a debug assert catches regressions). Per-tab modal state
  (staged conflicts/resume decisions, New Folder, tunnel sheet) lives on the session.

## Concurrency model (Swift 6, strict)

- UI layer is `@MainActor`. View models are main-actor and talk to FerryCore via `async`.
- Long-lived mutable state (sessions, queue) lives in **actors** (`TransferEngine`,
  `SSHSessionManager`). Value types (`ConnectionProfile`, `FileItem`) are `Sendable`.
- No completion handlers in new code; `async/await` + `AsyncSequence` for progress streams.
- Blocking C calls (libcurl's `curl_easy_perform`, M12) never run on the cooperative
  executor: `FTPSource` dispatches every perform onto a detached `Thread` and bridges back
  via a continuation / `AsyncThrowingStream`. C callbacks use `@convention(c)` closures with
  `Unmanaged` context pointers; their boxes are the only shared state and are self-locked.

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
