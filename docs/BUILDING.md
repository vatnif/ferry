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

- **Now**: ad-hoc signing (`CODE_SIGN_IDENTITY = "-"`), runs locally only.
- **Placeholders to change before any distribution** (both in `project.pbxproj`):
  - `PRODUCT_BUNDLE_IDENTIFIER` — currently `com.gfragos.Ferry`; set to a domain the
    user owns.
  - `DEVELOPMENT_TEAM` — absent; requires an Apple Developer Program membership
    ($99/yr), then switch `CODE_SIGN_IDENTITY` to `Apple Development` /
    `Developer ID Application`.
- **Versioning**: `MARKETING_VERSION` (semver, mirror `FerryVersion.current`) +
  `CURRENT_PROJECT_VERSION` (monotonic build number).

### Keychain prompts in local builds (consequence of ad-hoc signing)

Login-keychain items carry an ACL naming the app allowed to read them, identified by its code
signature. An ad-hoc signature has no stable identity, so **every** local build is a different
app to macOS: any profile whose password was saved by an earlier build triggers the
"Ferry wants to use your confidential information stored in …" panel on each connect, and
*Always Allow* cannot make it stick. Typing the login password does not help — the keychain is
already unlocked; the panel is authorizing the ACL change, not an unlock.

Symptoms and handling while developing:

- Panel reappears in a loop ⇒ expected with ad-hoc signing, not an app bug. Deny it, or clear
  the saved secrets: `security delete-generic-password -s com.gfragos.Ferry` (once per item),
  then leave "Remember in my Keychain" unticked and type the password at each connect.
- Never rebuild while the app is running: replacing the bundle underneath a live process
  invalidates its signature and guarantees the panel on the next Keychain access.
- The real fix is a stable identity — an Apple Development certificate is enough (no paid
  membership needed for local runs); set `CODE_SIGN_IDENTITY` accordingly and the ACL survives
  rebuilds. Until then, `security find-identity -v -p codesigning` reports 0 identities here.
- The app no longer freezes behind that panel (ADR-034), but it still cannot dismiss it.

## Release process (filled in at M17)

Planned: Developer ID signing → notarization (`notarytool`) → stapled DMG → Sparkle
appcast for Direct; App Store Connect upload for the AppStore flavor. Checklist TBD.
