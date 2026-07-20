# Ferry — Roadmap

*Milestone states are tracked in PROGRESS.md; this file owns scope. Update on scope changes.*

Workflow per milestone: implement → unit + integration tests pass → docs updated →
**user review** → commit. UI milestones implement the approved mockups (docs/DESIGN.md).

## Phase 0 — UI design
- **M0** ✅ Mockups of 5 key screens + icon concepts; approved 2026-07-05 (icon A, sync browsing added).

## Phase A — Foundation
- **M1** Scaffolding: Xcode project (Direct/AppStore configs), FerryKit package, test
  targets, Docker test infra, all docs, placeholder app, dev icon.
- **M2** Domain models: `ConnectionProfile`, `ProfileFolder` tree, `ConnectionStore`
  (versioned JSON, atomic writes, no secrets) + persistence tests.
- **M3** `CredentialVault`: Keychain wrapper + real-Keychain integration tests.
- **M4** Connection Manager UI per mockup screen 1 sidebar + screen 2 sheet (connect stub).

## Phase B — Browsing
- **M5** `FileSystemSource` protocol + `LocalFileSource` (security-scoped bookmarks).
- **M6** SSH library spike (Citadel vs libssh2 → ADR) + read-only `SFTPSource`.
- **M7** Dual-pane browser per screen 1, wired end-to-end incl. sync browsing. *Big review.*

## Phase C — Transfers
- **M8** `TransferEngine` + queue UI: progress, cancel, concurrency, drag between panes.
- **M9** Resume (`.ferrypart`, offset/REST), pause, auto-reconnect, keep-alive, retries,
  folder transfers — kill-mid-transfer integration tests. (SFTP mkdir pulled forward
  from M10 — folder uploads need it.)
- **M10** File ops: rename, delete UI, chmod editor, Quick Look, Finder drag & drop.

## Phase D — Protocol breadth & SSH depth
- **M11** Key auth, host-key TOFU UI (screen 3), known_hosts + `~/.ssh/config` import.
- **M12** `FTPSource` via system libcurl (TLS modes, REST resume).
- **M13** `SCPSource` over SSH exec.

## Phase E — Power features
- **M14** `TunnelEngine` + tunnel manager UI (screen 4): **Local + SOCKS** forwards + auto-start.
  Remote forwarding was deferred here (ADR-021) and un-deferred in M14.5.
- **M14.5** **Remote** port forwarding — un-deferred: the pinned Citadel 0.12.1 does expose the
  client `tcpip-forward` API (via the Wellz26 swift-nio-ssh fork it rides on, ADR-022).
- **M15** Open in Terminal (Direct only) — **done** (ADR-024): the external branch of the
  ADR-023 dispatch. Pure `SSHCommandBuilder` (injection-safe, never a password) + hand-off
  to Terminal.app/iTerm2 (AppleScript) / custom command (Process); honors `-i` key + remote
  start path; ssh does its own `~/.ssh/known_hosts` TOFU. Setting is storage-only until the
  M16 Settings window (picker mocked in tab 7). Defaults per ADR-023 (built-in on macOS 15+,
  Terminal.app on macOS 14 Direct).
- **M15.5** Embedded terminal (SwiftTerm) — pulled forward from backlog item 6
  (planning session 2026-07-18, ADR-023): Citadel `withPTY` shell panel (macOS 15+,
  ADR-020-style gate), dedicated SSH session, one Terminal button dispatching on a
  built-in/external setting. Checkpoints: A mockups+sign-off · B FerryKit
  (`TerminalSession` + `FerryTerminalUI` + tests) · C app UI + XCUITest + docs.
- **M16** Tabs, settings (screen 5), dark-mode audit vs mockups, error-message pass,
  acknowledgements screen (license notices), minimal in-app help (Help menu → user
  guide incl. `.ferrypart`/resume explainer + keyboard-shortcut reference). **Split into
  3 checkpoints** (approved 2026-07-19): **A Settings window + wiring** (done — all five
  tabs, terminal font/scrollback, transfer policies configurable; ADR-025/026) · **B Tabs**
  (done — screen-1 connection tab strip: N per-tab sessions/window, `OrderedTabs` +
  `ConnectionTab`, reopen-N-tabs, within-folder drag reorder; ADR-027) ·
  **C Polish** (done — dark-mode conformance audit [no code changes: semantic colors
  already], error-message voice pass, and the Help-menu **Ferry Help** + **Acknowledgements**
  windows over pure FerryCore content models; ADR-028). **M16 complete.**

## Phase F — Ship
- **M17** Packaging: Developer ID, notarization, DMG, Sparkle, production icon, release checklist.
- **M18** Sale readiness: trial + license keys (merchant-of-record comparison → LICENSING.md),
  EULA, website checklist.

*M17/M18 deferred for now (user decision 2026-07-19) but must ship before any sale; the
post-v1 phases below are planned and may be built ahead of them.*

## Post-v1 plan (planned 2026-07-19, ADR-029 — supersedes the old rough-priority backlog)

Sequencing rules: multiplexed session **before** ProxyJump (build the jump chain once);
transfer filters **before** folder sync (sync needs excludes); `FileSystemSource`
capability flags **before** cloud backends and checksum/preserve.

### Phase G — v1.1 "Workflow" (switcher funnel + daily-driver wins)
- **M19** Editor round-trip — **done (2026-07-20, ADR-030)**: "Open in Editor" / "Open With ▸"
  a remote file in an external editor, auto-upload on save (as queue rows). Default editor in
  Settings ▸ General; `⌘E`. Reused the Quick Look temp-streaming download + a `.restart` upload
  `TransferRequest`; net-new pure `FileWatcher` (`DispatchSource` → coalesced `AsyncStream`,
  atomic-save re-arm) + `EditorDispatch` in FerryCore + an editing-sessions tracker on
  `BrowserSession`. Direct-only (`#if !APPSTORE`, like the external terminal); no new dependency.
- **M20** Switchers & trust: FileZilla (`sitemanager.xml`) + Cyberduck (bookmark plists)
  importers mirroring the `SSHConfigParser` → `SSHImportSheet` pattern; secret-free profile
  **export/import** (the store is already self-contained, schema-versioned JSON); **FTPS
  self-signed cert TOFU prompt** (acknowledged debt, DOMAIN.md).
- **M21** Pane power pack: batch rename (pattern/numbering/find-replace); remote file
  search (`find` via SSH exec fast-path, listing-walk fallback); server-side archive
  compress/extract via exec (SSH-only); remote→Finder drag-out (`NSFilePromiseProvider`,
  deferred from M10); terminal-follows-pane toggle (auto-`cd` on pane navigation).

### Phase H — v1.2 "Pro SSH core"
- **M22** Multiplexed `SSHSessionManager`: one SSH session shared by SFTP + exec + tunnels
  + terminal, built at the `SSHClientFactory` seam. Must respect the tunnel engine's
  dedicated event-loop group (ADR-021); graceful fallback to per-consumer sessions.
  Design ADR required.
- **M23** Jump hosts & agent: ProxyJump chains (incl. honoring `ProxyJump` on ssh-config
  import — currently skipped); ssh-agent auth (Direct-only, `#if !APPSTORE`); ECDSA key
  support (investigate the ADR-017 blocker in Citadel).
- **M24** Trust & visibility: activity log window (per-connection protocol/transfer log);
  Touch ID lock for marked profiles (LocalAuthentication).

### Phase I — v1.3 "Sync"
- **M25** Transfer engine upgrades: `FileSystemSource` capability-flags refactor; transfer
  filters/rules (glob excludes, e.g. `.DS_Store`); bandwidth throttling + checksum
  verification (both settings already ship visible-but-disabled); timestamp/permission
  preservation options.
- **M26** Folder synchronization: one-way mirror with **dry-run preview** — a two-sided
  listing diff engine over `list`/`stat`, reusing M25 filters and the existing recursive
  enumeration + conflict machinery.

### Phase J — v1.4 "Breadth"
- **M27** WebDAV backend: URLSession-based `FileSystemSource` (no new dependencies).
- **M28** S3 backend: flat key space with synthesized directories; dependency decision
  (hand-rolled SigV4 vs Soto, Apache-2.0 — allowed) recorded in LICENSING.md.
- **M29** Remote↔remote transfers: UI/wiring only — `TransferEngine` already streams
  between two arbitrary `FileSystemSource`s.

### Phase K — v1.5 "Reach"
- **M30** Automation: `sftp://` URL handler; Shortcuts/AppleScript surface; menu-bar
  quick-upload droplet.
- **M31** Localization & help: String Catalogs groundwork (externalize UI strings);
  expanded/contextual help (per-screen ? buttons, troubleshooting guides: host keys,
  firewalls/passive FTP, permissions); localized help follows translations.

*Retired from the old backlog: embedded terminal shipped as M15.5 (ADR-023); remote port
forwarding shipped as M14.5 (ADR-022).*
