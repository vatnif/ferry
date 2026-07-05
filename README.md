# Ferry

A native macOS dual-pane file-transfer client — SFTP, FTP/FTPS and SCP, with a
connection manager, resumable transfers, SSH tunneling and terminal hand-off.
Swift 6 · SwiftUI · macOS 14+.

**Status**: pre-alpha, under construction milestone by milestone — see
[PROGRESS.md](PROGRESS.md) and [docs/ROADMAP.md](docs/ROADMAP.md).

## Quick start

```sh
xcodebuild -scheme Ferry-Direct -destination 'platform=macOS' build   # build the app
testinfra/start.sh                                                    # start test servers (Docker)
cd FerryKit && swift test                                             # unit + integration tests
```

Full instructions: [docs/BUILDING.md](docs/BUILDING.md) · [docs/TESTING.md](docs/TESTING.md)

## Documentation

| | |
|---|---|
| [CLAUDE.md](CLAUDE.md) | Working rules & project guide (read first) |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Modules & concurrency model |
| [docs/DOMAIN.md](docs/DOMAIN.md) | Business logic & behavior rules |
| [docs/DESIGN.md](docs/DESIGN.md) | Approved UI spec & mockups |
| [docs/LICENSING.md](docs/LICENSING.md) | Dependency licenses & sale plan |
| [docs/DECISIONS.md](docs/DECISIONS.md) | Architecture decision records |

All rights reserved. Not open source (commercial product in development).
