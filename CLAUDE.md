# Ferry — project guide for Claude sessions

Ferry is a native macOS dual-pane file-transfer client (SFTP/FTP/FTPS/SCP; think Transmit/Cyberduck) built with Swift 6 + SwiftUI, intended for commercial sale (one-time purchase). Working directory name "FraSSH" is historical; the product name is Ferry.

**Start every session by reading `PROGRESS.md`** — it holds milestone states, current code status, and next steps. The full milestone plan lives in `docs/ROADMAP.md`.

## Standing rules (user-mandated — never skip)

1. **Milestone workflow**: implement → all unit + integration tests pass → update `PROGRESS.md` and every affected doc → present to the user for review → **commit only after the user approves**. Never commit unreviewed work.
2. **Tests every milestone**: new logic gets unit tests (in FerryKit) and integration tests (against the Docker servers, `testinfra/`) in the same milestone. See `docs/TESTING.md`.
3. **UI must match the approved mockups** in `docs/design/ferry-mockups.html` (spec: `docs/DESIGN.md`). Any deviation needs explicit user sign-off plus an entry in `docs/DECISIONS.md`.
4. **License policy**: never add a dependency without recording it in `docs/LICENSING.md`. Allowed: MIT, BSD, Apache-2.0, Zlib, ISC. Forbidden: GPL, LGPL, AGPL, SSPL, or anything restricting commercial sale. (Notably: use libssh2 if needed, **never libssh**.)
5. **Sandbox compatibility**: the App Store build must stay viable. Local file access goes through security-scoped-bookmark-aware code; ssh-agent and launch-Terminal features are `#if !APPSTORE`-flagged or capability-checked. See `docs/DOMAIN.md` → Sandbox strategy.
6. **Credentials only in the Keychain** — never in the JSON profile store, logs, or test fixtures.
7. Significant technical decisions get a dated entry in `docs/DECISIONS.md`.

## Repo layout

- `Ferry.xcodeproj` — hand-authored (objectVersion 77, synchronized folder groups; no XcodeGen). New files inside `Ferry/` and `FerryUITests/` are picked up automatically — usually no pbxproj edits needed.
- `Ferry/` — app target: SwiftUI shell, assets, entitlements (Direct + AppStore).
- `FerryKit/` — local SwiftPM package with ALL core logic (`FerryCore`) and the unit + integration test targets. Testable headless via `swift test`.
- `FerryUITests/` — XCUITest smoke tests.
- `testinfra/` — Docker test servers (SFTP :2222, FTP :2121; user `ferry`/`ferrypass`).
- `tools/generate-appicon.swift` — regenerates the app icon from the approved concept.
- `docs/` — living documentation (see map below).

## Commands

```sh
# Build & run the app (Direct = default flavor)
xcodebuild -scheme Ferry-Direct -destination 'platform=macOS' build
open ~/Library/Developer/Xcode/DerivedData/Ferry-*/Build/Products/DebugDirect/Ferry.app

# Unit + integration tests (integration tests skip if servers are down)
cd FerryKit && swift test

# Test servers
testinfra/start.sh   # also generates the 1MB fixture on first run
testinfra/stop.sh

# UI tests (requires one-time: sudo DevToolsSecurity -enable)
xcodebuild -scheme Ferry-Direct -destination 'platform=macOS' test

# App Store flavor
xcodebuild -scheme Ferry-AppStore -destination 'platform=macOS' build
```

## Documentation map — update whenever the subject changes

| File | Owns | Update when |
|---|---|---|
| `PROGRESS.md` | Milestone states, current status, session log | **Every session, end of every milestone** |
| `docs/ARCHITECTURE.md` | Modules, layers, concurrency model | Structure changes |
| `docs/DOMAIN.md` | Business rules: connections, transfers, resume, trust, credentials, sandbox | Behavior rules change |
| `docs/DESIGN.md` + `docs/design/` | Approved UI spec + mockups + icon | Any approved UI change |
| `docs/LICENSING.md` | Dependency licenses + product licensing plan | Any dependency change |
| `docs/BUILDING.md` | Build/run/sign/release | Toolchain or process changes |
| `docs/TESTING.md` | Test policy, suites, testinfra | Test setup changes |
| `docs/DECISIONS.md` | Dated ADR log | Every significant decision |
| `docs/ROADMAP.md` | Milestone plan, backlog | Scope changes |

## Environment gotchas

- Xcode 26.6 / Swift 6.3 on this machine; deployment target macOS 14. No Homebrew.
- Code signing is ad-hoc (`CODE_SIGN_IDENTITY=-`) until the user configures a Developer ID team; bundle id `com.gfragos.Ferry` is a placeholder (see BUILDING.md).
- UI tests fail with "Timed out while enabling automation mode" until the user runs `sudo DevToolsSecurity -enable`.
- The SFTP test image (atmoz/sftp) is amd64 and runs under emulation on this arm64 Mac — harmless.
