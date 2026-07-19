# Ferry — Licensing

*Two concerns: (a) licenses of everything we depend on, (b) how Ferry itself will be
licensed and sold. Update (a) on EVERY dependency change — CLAUDE.md rule 4.*

## a) Dependency license policy

Ferry is a closed-source commercial product. Every dependency must permit commercial,
closed-source redistribution without copyleft obligations.

- **Allowed**: MIT, BSD-2/3, Apache-2.0, Zlib, ISC, curl license, OS frameworks.
- **Forbidden**: GPL (any), LGPL (even dynamically linked — kills App Store flexibility
  and complicates notarized bundles), AGPL, SSPL, BUSL, CC-NC.
  Concretely: **libssh2 (BSD-3) yes, libssh (LGPL) never.**
- Apache-2.0 obligations: ship a NOTICE/acknowledgements screen — **live since M16
  checkpoint C** (Help ▸ Acknowledgements…, ADR-028).
- MIT/BSD obligations: reproduce copyright notices in the acknowledgements screen (done, M16 C).

### Current dependency inventory

| Dependency | License | Scope | Status |
|---|---|---|---|
| Apple SDKs (SwiftUI, Foundation, Security, …) | Apple SDK terms | app | in use (M1) |
| Citadel (orlandos-nl/Citadel) | MIT | SSH/SFTP client | added M6 |
| swift-nio-ssh (Wellz26 fork of apple/swift-nio-ssh) | Apache-2.0 (fork's LICENSE.txt verified) | SSH transport (via Citadel; provides the remote-forward API) | added M6 (transitive); fork identified M14.5 (ADR-022) |
| swift-crypto (apple) | Apache-2.0 | host-key SHA256 fingerprints + private-key types (SHA256/Curve25519/RSA) | **promoted to direct M11** (was transitive since M6) |
| swift-nio, swift-atomics, swift-collections, swift-log (apple) | Apache-2.0 | via Citadel | added M6 (transitive) |
| BigInt (attaswift) | MIT | via Citadel (RSA math) | added M6 (transitive) |
| System libcurl (`/usr/lib/libcurl`, ships with macOS) | curl (MIT-like) | FTP/FTPS backend | **in use M12** (linked `-lcurl` via the `CFTP` shim; nothing bundled — ADR-019) |
| SwiftTerm (migueldeicaza) | MIT (LICENSE verified 2026-07-18) | embedded terminal emulator (`FerryTerminalUI`, M15.5) | **added M15.5** (ADR-023; pinned ≥ 1.14.0). Its Package.swift deps (swift-argument-parser, swift-docc-plugin, package-benchmark — Apache-2.0-family) attach only to executable/doc/benchmark targets, **not** the `SwiftTerm` library product Ferry links |

Transitive inventory: `cd FerryKit && swift package show-dependencies` — re-check and
update this table whenever `Package.swift` or pinned versions change. All names above
appear in the acknowledgements screen (Help ▸ Acknowledgements…, M16 checkpoint C) — the
list is `Acknowledgements.all` in `FerryKit/Sources/FerryCore/Help/Acknowledgements.swift`;
**keep the two in sync**. `HelpContentTests` fails the build if a listed dependency's license
is not one this policy allows, or if any of Citadel/swift-nio-ssh/swift-crypto/SwiftTerm/libcurl
is dropped from the screen.

### Planned (record here BEFORE adding)

| Dependency | License | Purpose | When |
|---|---|---|---|
| libssh2 (fallback only if Citadel proves insufficient) | BSD-3 | SSH/SFTP | contingency |
| Sparkle 2 | MIT | auto-update, Direct build only | M17 |

### Dev/test-only (not shipped, so license only needs to permit use)

| Tool | License | Purpose |
|---|---|---|
| Docker images `atmoz/sftp` (incl. OpenSSH), `delfer/alpine-ftp-server` (vsftpd), and a locally-built `alpine` + `openssh` image (`testinfra/ssh-exec`, for SCP/exec — M13) | MIT / GPL components / BSD (OpenSSH) | local test servers — run in Docker, never distributed with the app |

GPL in test *infrastructure* is fine: we distribute nothing from it.

## b) Product licensing & sale plan

Decided: **one-time purchase** (Transmit model), price TBD. Possible paid major upgrades
(v1 → v2) later. No subscription.

Distribution:
1. **Direct** (first): own website; payment + license keys via a merchant-of-record —
   compare **Paddle** vs **Lemon Squeezy** (both handle EU VAT — relevant for a
   Greece-based seller) vs Gumroad (simplest, higher fee) at M18. Offline-friendly
   license validation, generous trial (e.g. 14 days full-featured), no account required.
2. **Mac App Store** (later): Apple IAP replaces license keys; price parity.

To do before sale (M18 checklist): trademark/domain check for "Ferry" (user), EULA,
privacy policy (easy: no telemetry planned), acknowledgements screen, refund policy.

Ferry's own code: proprietary, all rights reserved. The repo must never carry an
open-source LICENSE file.
