---
name: verify
description: Build, launch, and observe the Ferry macOS app to verify UI changes at runtime (accessibility-API driving; screencapture is blocked).
---

# Verifying Ferry at runtime

## Build & launch

```sh
xcodebuild -scheme Ferry-Direct -destination 'platform=macOS' build
APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/Ferry-*/Build/Products/DebugDirect/Ferry.app | head -1)
open "$APP" && sleep 4
osascript -e 'tell application "Ferry" to activate'
```

## Observing the UI

`screencapture` (both `-l<windowid>` and full-screen) fails with "could not
create image" — the shell has no screen-recording permission. **Use the
accessibility API instead**: System Events *is* permitted, and every
interactive Ferry view carries an `accessibilityIdentifier` (e.g.
`tabStrip.tab.0`, `tabStrip.newTab`, `passwordPrompt.connect`), exposed as
`AXIdentifier`.

Geometry/behavior checks via osascript:

```applescript
tell application "System Events" to tell process "Ferry"
  set w to window "Ferry"          -- by name; "window 1" is flaky when the app was backgrounded
  set {wx, wy} to position of w    -- report element coords relative to wx/wy
  set els to entire contents of w  -- slow (~seconds) but exhaustive
  repeat with e in els
    try
      set ident to value of attribute "AXIdentifier" of e
      if ident starts with "tabStrip" then
        -- position of e / size of e; click e to drive it
      end if
    end try
  end repeat
end tell
```

Gotchas:

- Always `activate` Ferry (and `delay 1`) before querying or sending
  keystrokes; a backgrounded Ferry can transiently report **0 windows**.
- `entire contents` must re-run after any UI change — stale references throw.
- Keystrokes: `keystroke "w" using command down` works for testing shortcuts.
- The app is not AppleScript-scriptable; only System Events works.

## What to drive

- Tab strip: `tabStrip.tab.<i>` / `tabStrip.close.<i>` / `tabStrip.newTab`;
  ⌘T new tab, ⌘W close (window always keeps ≥1 tab).
- Connecting needs the Docker servers: `testinfra/start.sh` (SFTP :2222,
  user ferry/ferrypass).
