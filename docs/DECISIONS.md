# Ferry — Decision log (ADRs)

*Append a dated entry for every significant technical or product decision. Newest last.*

## 2026-07-05 — ADR-001: Native Swift 6 + SwiftUI
User choice (over Kotlin/Compose and Electron/Tauri): premium native feel for a paid Mac
utility, Keychain/Touch ID access, small bundle. AppKit bridges allowed where SwiftUI
falls short. Min target macOS 14.

## 2026-07-05 — ADR-002: Dual distribution, sandbox-compatible from day one
Direct sale first (Developer ID + notarization), Mac App Store later. Consequence: 4 build
configurations (Debug/Release × Direct/AppStore), `APPSTORE` compile flag, all local FS
access through security-scoped-bookmark-aware code, agent/terminal features gated.

## 2026-07-05 — ADR-003: Permissive-licenses-only policy
Product will be sold; GPL/LGPL and friends are banned outright (details LICENSING.md).
SSH stack: Citadel (MIT) over swift-nio-ssh (Apache-2.0), fallback libssh2 (BSD-3) —
decided by M6 spike. FTP via macOS system libcurl (nothing bundled). Never libssh (LGPL).

## 2026-07-05 — ADR-004: Core logic in a local SwiftPM package (FerryKit)
All non-UI code lives in FerryKit/FerryCore: headless-testable (`swift test`), keeps the
hand-written pbxproj tiny, enforces UI/core separation. App target is a thin SwiftUI shell.

## 2026-07-05 — ADR-005: Hand-authored Xcode project, no generator
No Homebrew/XcodeGen on the dev machine; instead `project.pbxproj` (objectVersion 77)
uses synchronized folder groups, so file additions don't touch the project file.
Revisit only if target structure grows complex.

## 2026-07-05 — ADR-006: Docker-based integration test servers
`atmoz/sftp` (:2222) + `delfer/alpine-ftp-server` (:2121), creds ferry/ferrypass, seeded
fixtures. Integration tests skip when servers are down (FERRY_REQUIRE_TEST_SERVERS=1
forces failure). Rationale: real protocol servers over mocks — resume/tunnel behavior
can't be faked credibly.

## 2026-07-05 — ADR-007: Product decisions (M0)
Name **Ferry** (working; trademark check pending, user's task). One-time-purchase model.
Icon: concept A ("The Ferry", white boat on sea-teal squircle) — approved. UI mockups for
5 key screens approved, including user-requested **sync browsing** (linked panes toggle);
implementation must match `docs/design/ferry-mockups.html` (CLAUDE.md rule 3).

## 2026-07-05 — ADR-008: Credentials in Keychain only; JSON profile store carries no secrets
Profile store is versioned JSON in Application Support; secrets are Keychain generic
password items keyed by profile UUID. Works identically sandboxed and unsandboxed.

## 2026-07-05 — ADR-009: connections.json schema (v1)
Recursive tree: `ConnectionLibrary{schemaVersion, items:[SidebarItem]}` where SidebarItem
is `{"type":"folder"|"profile", ...}` via hand-written Codable (clean discriminator, no
synthesized `_0` keys — pinned by test). Dates ISO8601 (whole seconds); output
prettyPrinted+sortedKeys so identical content ⇒ identical bytes (backup/diff friendly).
Atomic writes. Loading probes schemaVersion first: newer-than-supported fails with a
precise error instead of decode garbage; older versions are the future migration hook.
Enum raw values (`TransferProtocol`, tunnel kinds) are part of the schema — never rename
without a migration.

## 2026-07-05 — ADR-010: Keychain via login keychain (not data-protection keychain)
CredentialVault uses classic SecItem generic-password items in the login keychain, WITHOUT
`kSecUseDataProtectionKeychain`. Rationale: the data-protection keychain requires a signed
app with an application-identifier entitlement, which would break `swift test` (unsigned
runner) and ad-hoc dev builds. Accessibility: `kSecAttrAccessibleWhenUnlocked`. Account
format `"<profileUUID>/<role>"` and service `com.gfragos.Ferry` are persistence contracts
(pinned by test). Revisit for the App Store build in M17 — switching stores will need a
one-time migration that reads old items and rewrites them.
