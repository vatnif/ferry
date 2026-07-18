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
- **M15** Open in Terminal (Direct only).
- **M15.5** Embedded terminal (SwiftTerm) — pulled forward from backlog item 6
  (planning session 2026-07-18, ADR-023): Citadel `withPTY` shell panel (macOS 15+,
  ADR-020-style gate), dedicated SSH session, one Terminal button dispatching on a
  built-in/external setting. Checkpoints: A mockups+sign-off · B FerryKit
  (`TerminalSession` + `FerryTerminalUI` + tests) · C app UI + XCUITest + docs.
- **M16** Tabs, settings (screen 5), dark-mode audit vs mockups, error-message pass,
  acknowledgements screen (license notices), minimal in-app help (Help menu → user
  guide incl. `.ferrypart`/resume explainer + keyboard-shortcut reference).

## Phase F — Ship
- **M17** Packaging: Developer ID, notarization, DMG, Sparkle, production icon, release checklist.
- **M18** Sale readiness: trial + license keys (merchant-of-record comparison → LICENSING.md),
  EULA, website checklist.

## Post-v1 backlog (rough priority)
0. Multiplexed `SSHSessionManager` (one SSH session shared by SFTP + tunnels + exec) so tunnels
   ride the browser's session instead of opening their own. (Remote port forwarding, formerly
   this item, shipped in M14.5 — ADR-022.)
1. Edit remote file in external editor with auto-upload on save
2. Jump host / ProxyJump; ssh-agent support (Direct)
3. Import from FileZilla / Cyberduck
4. Folder synchronization (one-way mirror, dry-run preview)
5. Bandwidth limits; checksum verification
6. ~~Embedded terminal (SwiftTerm)~~ — pulled forward as **M15.5** (2026-07-18, ADR-023)
7. WebDAV + S3 backends; remote↔remote transfers
8. Menu-bar quick-upload droplet; `sftp://` URL handler; Shortcuts/AppleScript
   - Remote→Finder drag-out via `NSFilePromiseProvider` (download-on-drop) — surfaced in
     M10; local→Finder and Finder→pane already ship.
9. Expanded help: searchable/contextual (per-screen ? buttons), troubleshooting
   guides (host keys, firewalls/passive FTP, permissions), localized
