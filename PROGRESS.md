# Ferry — progress tracker

> Update this file at the end of **every working session** and **every milestone**
> (rule 1 in CLAUDE.md). States: `todo` · `in progress` · `awaiting review` · `done`.

## Milestones

| # | Milestone | State |
|---|---|---|
| M0 | UI mockups & approval | **done** (approved 2026-07-05, incl. icon concept A + sync browsing) |
| M1 | Scaffolding, docs & test infra | **awaiting review** |
| M2 | Domain models & profile store | todo |
| M3 | CredentialVault (Keychain) | todo |
| M4 | Connection Manager UI | todo |
| M5 | FileSystemSource protocol + LocalFileSource | todo |
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

## Current state of the code (after M1)

- Xcode project `Ferry.xcodeproj` (hand-authored, objectVersion 77) with app target `Ferry` + `FerryUITests`; 4 build configurations (Debug/Release × Direct/AppStore) and 2 shared schemes (`Ferry-Direct`, `Ferry-AppStore`). Builds clean.
- `FerryKit` local SwiftPM package holds all future core logic. Currently: `FerryVersion` placeholder + 1 unit test + 2 integration smoke tests (SSH banner / FTP greeting) — all passing.
- Docker test infra (`testinfra/`): SFTP on 127.0.0.1:2222, FTP on 2121 (`ferry`/`ferrypass`), seeded fixtures; `start.sh`/`stop.sh` verified working.
- App shows a branded placeholder window; approved icon (concept A) generated into the asset catalog by `tools/generate-appicon.swift`.
- All docs written (see CLAUDE.md doc map). Nothing committed yet — first commit happens on M1 approval.

## Known issues / open items

- Bundle id `com.gfragos.Ferry` and ad-hoc signing are placeholders until the user has an Apple Developer account (BUILDING.md).
- Trademark/domain check for the name "Ferry" is the user's task before sale.

## Next steps

1. User reviews M1 → on approval: initial git commit.
2. M2: `ConnectionProfile`, `ProfileFolder` tree, `ConnectionStore` (JSON persistence, no secrets) + tests, per docs/DOMAIN.md.

## Session log

- **2026-07-05** — Project inception. Requirements gathered; plan approved (18 milestones). M0: mockups of 5 screens + icon concepts built and iterated (sync browsing added on user request); user approved mockups + icon A. M1: repo initialized, Xcode project + FerryKit package + test targets created, Docker test infra up, icon generated, all docs written. All suites green: 1 unit + 2 integration + 1 UI test (user enabled DevToolsSecurity). M1 awaiting review.
