# Ferry — Building

*Update on any toolchain, signing, or process change.*

## Prerequisites

- macOS 14+ (dev machine currently runs later), **Xcode 26+** (`xcode-select -p` must
  point at Xcode.app, not CommandLineTools).
- **Docker Desktop** (or compatible) for integration tests only.
- No other tooling: no Homebrew, no XcodeGen — the project file is maintained by hand
  (see ARCHITECTURE.md → Xcode project mechanics).
- **No bundled native libraries.** FTP/FTPS links the **system libcurl** (`-lcurl`, via
  the `CFTP` SwiftPM target — ADR-019); it resolves against the SDK's `libcurl.tbd` at
  link time and macOS's `/usr/lib/libcurl` at runtime. Nothing to install; works in both
  the Direct and sandboxed App Store builds (libcurl is a system dylib).
- **Metal toolchain** (one-time: `xcodebuild -downloadComponent MetalToolchain`) —
  SwiftTerm (M15.5, ADR-023) ships a `.metal` shader that Xcode compiles as a package
  resource; without the component the app targets fail with "cannot execute tool
  'metal'". `swift test` in FerryKit doesn't need it (SwiftPM skips the shader).
  Installed on this machine 2026-07-18.

## Build & run

```sh
# CLI
xcodebuild -scheme Ferry-Direct  -destination 'platform=macOS' build
xcodebuild -scheme Ferry-AppStore -destination 'platform=macOS' build

# The built app lands in DerivedData:
open ~/Library/Developer/Xcode/DerivedData/Ferry-*/Build/Products/DebugDirect/Ferry.app
```

Or open `Ferry.xcodeproj` in Xcode, pick the `Ferry-Direct` scheme, ⌘R.
IntelliJ users: Xcode is required for the app target; FerryKit (pure SwiftPM) also works
in any editor + `swift build`/`swift test`.

Schemes → configurations: `Ferry-Direct` runs DebugDirect / archives ReleaseDirect;
`Ferry-AppStore` likewise with the AppStore pair (sandboxed, `APPSTORE` compile flag).

## Tests

See `docs/TESTING.md`. Short version:

```sh
testinfra/start.sh
cd FerryKit && swift test        # unit + integration
cd .. && xcodebuild -scheme Ferry-Direct -destination 'platform=macOS' test   # UI tests
```

UI tests need a one-time `sudo DevToolsSecurity -enable`.

## App icon

`swift tools/generate-appicon.swift` regenerates
`Ferry/Assets.xcassets/AppIcon.appiconset/` from the approved concept A
(`docs/design/icon-concept-a.svg`). Dev icon only; production master due M17.

## Signing & distribution (current state)

- **Now**: the **Ferry app target** is signed with a personal-team **`Apple Development`**
  identity — `DEVELOPMENT_TEAM = 9H2MFWH42X`, Automatic signing, on all four app configs
  (ADR-041, 2026-09-11). This is a **free** identity (no paid Developer Program needed) and
  exists so login-Keychain secrets persist across rebuilds; it is **local-run only**. The
  `FerryUITests` target stays ad-hoc (`CODE_SIGN_IDENTITY = "-"`) — it holds no Keychain items.
- **Still placeholders to change before any distribution** (in `project.pbxproj`):
  - `PRODUCT_BUNDLE_IDENTIFIER` — currently `com.gfragos.Ferry`; set to a domain the
    user owns.
  - For distribution, switch `CODE_SIGN_IDENTITY` to `Developer ID Application` (Direct,
    notarized) / an App Store signing+provisioning setup, under a **distribution** team —
    a paid Apple Developer Program membership ($99/yr). The current personal team is fine
    for local runs but not for shipping. (Deferred to M17 — packaging.)
- **Versioning**: `MARKETING_VERSION` (semver, mirror `FerryVersion.current`) +
  `CURRENT_PROJECT_VERSION` (monotonic build number).

### Keychain prompts in local builds

**Resolved as of 2026-09-11 (ADR-041).** The app target now signs with a stable
`Apple Development` identity (`DEVELOPMENT_TEAM = 9H2MFWH42X`), so the login-keychain ACL binds
durably: *Always Allow* / "Remember in my Keychain" **now sticks across rebuilds**. The panel
still appears **once** on the first access to a newly-saved secret (it is authorizing the ACL,
not unlocking the keychain) — click *Always Allow* and subsequent connects are silent.

Background (why it was broken, and the two rules that still bite): login-keychain items carry an
ACL naming the app allowed to read them, identified by its code signature. An **ad-hoc**
signature has no stable identity, so every ad-hoc build was a different app to macOS and the
panel looped. That is fixed by the stable identity, **but**:

- **Never rebuild while the app is running** — replacing the bundle underneath a live process
  invalidates its signature and brings the panel back on the next Keychain access.
- **Run a freshly-signed build, not a stale ad-hoc copy.** `tools/reinstall-app.sh` rebuilds
  `ReleaseDirect` and installs it to `/Applications`; confirm identity with
  `codesign -dv --verbose=2 /Applications/Ferry.app` (expect `Authority=Apple Development…`,
  `TeamIdentifier=9H2MFWH42X`).
- Confirm the machine has the identity: `security find-identity -v -p codesigning` should list
  one `Apple Development:` entry (it comes from adding an Apple ID team in Xcode ▸ Settings ▸
  Accounts — free, no paid membership).
- To clear secrets left over from the ad-hoc era (their ACLs are bound to the old signature):
  `security delete-generic-password -s com.gfragos.Ferry` (repeat once per item until
  "not found"), then re-save.
- The app never freezes behind the panel (ADR-034); Keychain reads run off the main actor.

## Release process (filled in at M17)

Planned: Developer ID signing → notarization (`notarytool`) → stapled DMG → Sparkle
appcast for Direct; App Store Connect upload for the AppStore flavor. Checklist TBD.
