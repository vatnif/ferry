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
- **M9** Resume (`.ferrypart`, offset/REST), auto-reconnect, keep-alive, retries —
  kill-mid-transfer integration tests.
- **M10** File ops: rename, delete, mkdir, chmod editor, Quick Look, Finder drag & drop.

## Phase D — Protocol breadth & SSH depth
- **M11** Key auth, host-key TOFU UI (screen 3), known_hosts + `~/.ssh/config` import.
- **M12** `FTPSource` via system libcurl (TLS modes, REST resume).
- **M13** `SCPSource` over SSH exec.

## Phase E — Power features
- **M14** `TunnelEngine` + tunnel manager UI (screen 4): local/remote/SOCKS, auto-start.
- **M15** Open in Terminal (Direct only).
- **M16** Tabs, settings (screen 5), dark-mode audit vs mockups, error-message pass,
  acknowledgements screen (license notices).

## Phase F — Ship
- **M17** Packaging: Developer ID, notarization, DMG, Sparkle, production icon, release checklist.
- **M18** Sale readiness: trial + license keys (merchant-of-record comparison → LICENSING.md),
  EULA, website checklist.

## Post-v1 backlog (rough priority)
1. Edit remote file in external editor with auto-upload on save
2. Jump host / ProxyJump; ssh-agent support (Direct)
3. Import from FileZilla / Cyberduck
4. Folder synchronization (one-way mirror, dry-run preview)
5. Bandwidth limits; checksum verification
6. Embedded terminal (SwiftTerm)
7. WebDAV + S3 backends; remote↔remote transfers
8. Menu-bar quick-upload droplet; `sftp://` URL handler; Shortcuts/AppleScript
