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
- Apache-2.0 obligations: ship a NOTICE/acknowledgements screen (add in M16).
- MIT/BSD obligations: reproduce copyright notices in the acknowledgements screen.

### Current dependency inventory

| Dependency | License | Scope | Status |
|---|---|---|---|
| Apple SDKs (SwiftUI, Foundation, Security, …) | Apple SDK terms | app | in use (M1) |
| Citadel (orlandos-nl/Citadel) | MIT | SSH/SFTP client | added M6 |
| swift-nio-ssh (apple) | Apache-2.0 | SSH transport (via Citadel) | added M6 (transitive) |
| swift-nio, swift-crypto, swift-atomics, swift-collections, swift-log (apple) | Apache-2.0 | via Citadel | added M6 (transitive) |
| BigInt (attaswift) | MIT | via Citadel (RSA math) | added M6 (transitive) |

Transitive inventory: `cd FerryKit && swift package show-dependencies` — re-check and
update this table whenever `Package.swift` or pinned versions change. All names above
must appear in the acknowledgements screen (M16).

### Planned (record here BEFORE adding)

| Dependency | License | Purpose | When |
|---|---|---|---|
| libssh2 (fallback only if Citadel proves insufficient) | BSD-3 | SSH/SFTP | contingency |
| System libcurl (`/usr/lib/libcurl.dylib`, ships with macOS) | curl (MIT-like) | FTP/FTPS | M12 |
| Sparkle 2 | MIT | auto-update, Direct build only | M17 |
| SwiftTerm | MIT | embedded terminal | post-v1 |

### Dev/test-only (not shipped, so license only needs to permit use)

| Tool | License | Purpose |
|---|---|---|
| Docker images `atmoz/sftp` (incl. OpenSSH), `delfer/alpine-ftp-server` (vsftpd) | MIT / GPL components | local test servers — run in Docker, never distributed with the app |

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
