# Ferry — UI design spec

*The approved M0 mockups are the binding UI contract (CLAUDE.md rule 3). This file is
their written form. Any change requires user approval + an ADR. Approved 2026-07-05.*

**Mockups**: open `docs/design/ferry-mockups.html` in a browser (7 tabs, light + dark —
tab 7 "Terminal" added in M15.5, approved 2026-07-18, ADR-023).

**Implementation status** (which mockup elements are live vs pending — keep current):
- Screen 1: sidebar + editor (M4), dual-pane browser with sync browsing (M7), the
  transfer queue dock with Upload/Download + drag between panes (M8), and M9's
  robustness set — pause/resume buttons, RESUMED/PAUSED badges, folder transfers,
  per-file conflict dialog with Replace All/Skip All, reconnect states in the status
  bar (amber "Reconnecting…", red "Connection lost" + Reconnect link) — are live. M10's
  file operations are live too: per-row context menu (Quick Look · Upload/Download ·
  Rename… · Permissions… · Delete…), rename alert, delete confirmation, chmod editor
  sheet, Quick Look (local in place / remote via temp download), and Finder drag & drop
  (drop files onto a pane to transfer; drag local files out to Finder).
  Notes: drag handle is the file icon (whole-row drag breaks double-click, ADR-013); local
  items vend a file URL, remote items a string payload (ADR-015). The **Tunnels toolbar
  button** (SSH profiles only) and the **active-tunnel count** in the status bar are live
  (M14). Pending: tabs (M16), within-folder drag reorder (M16), remote→Finder
  promise drag (backlog), Terminal button (M15). Status bar shows first-listing round-trip
  instead of continuous latency for now.
- Screen 2 (connection sheet): live since M4; SSH-key + agent auth rows are wired (M11 —
  key auth live; agent reports "planned"); "Test Connection" is a TCP probe until a
  protocol-level test replaces it. The tunnels row (saved-count + Edit…) still opens the
  full manager only from screen 1's Tunnels button in M14; editing tunnels from the
  connection sheet is a later refinement.
- Screen 7 (embedded terminal, M15.5): **approved 2026-07-18** (mockup tab 7, ADR-023)
  and **implemented** — docked panel (header states, resize drag, collapse/close with
  live-shell confirm, ended banner + Restart), ⧉ pop-out window with "Dock in Window",
  profile context-menu Open Terminal (terminal-only window), macOS-14 explainer.
  The **external hand-off choices (Terminal.app / iTerm2 / custom) are implemented (M15,
  ADR-024)** — the toolbar control and Open Terminal item dispatch on the stored setting
  (built-in → panel/window; external → ssh hand-off); on macOS 14 Direct they now open
  Terminal.app rather than explaining. Pending until M16: the **Settings ▸ Terminal
  picker UI** (mockup tab 7 — the setting is storage-only for now, changeable via
  `defaults write`) and the scrollback-lines setting (SwiftTerm recomputes its options
  on resize, needs care).
- Screen 3 (host keys): **live (M11)** — TOFU first-contact prompt (🔑, selectable
  fingerprint box, "Remember this key" default-on) and the changed-key alarm (⚠️,
  Disconnect primary, Replace gated behind a second confirmation). Plus the connect-time
  key-passphrase prompt for encrypted keys. Pending in this screen: `~/.ssh/config` Import…
  and `~/.ssh/known_hosts` pre-trust (M11 checkpoint B). Screen 4 (tunnels): pending M14.
  Screen 5 (settings): pending M16.

## Brand

- **Name**: Ferry (working title; trademark check pending — user).
- **Accent**: sea-teal — light `#0D6E8C`, dark `#35B3D4` (asset `AccentColor`). Semantic
  colors (green ok / amber warn / red danger) are separate from the accent.
- **Icon**: concept A — white ferry silhouette, sea gradient (`#1A94B5`→`#0A4A68`),
  squircle. Source `docs/design/icon-concept-a.svg`, generator `tools/generate-appicon.swift`.
  Portholes drop below 64 px. Production 1024 px master due M17.
- **Typography**: system font (SF Pro) throughout; monospace (SF Mono) for permissions,
  fingerprints, tunnel endpoints. Tabular numerals for sizes/speeds/ETAs.

## Screen 1 — Main window

Structure: title bar → connection tabs → toolbar → [sidebar | dual panes] → transfer
queue (docked, collapsible) → status bar.

- **Sidebar** = connection manager: folder tree (arbitrary nesting, drag to reorganize),
  protocol badge per connection; "This Mac" section with local favorites below.
  Double-click connects in current tab; ⌘-double-click new tab. Context menu:
  Edit / Duplicate / Delete / New Folder. Import… button pulls `~/.ssh/config` (M11).
- **Tabs**: one per connection; green dot connected, grey disconnected; sidebar shared.
- **Panes**: local left, remote right — same `FileBrowserView`. Sortable columns (Name,
  Size, Modified, Kind; remote adds Perms mono + Owner), clickable breadcrumbs, per-pane
  hidden-toggle (👁) and overflow menu, footer with item count + free space / server info.
  Selection = accent-filled row. Hidden files render dimmed.
- **Toolbar**: back/forward, Upload, Download, New Folder, Refresh, **Linked** (sync
  browsing toggle, accent-filled when active), spacer, Tunnels, Terminal, filter field
  (filters focused pane live).
- **Sync browsing** (approved addition): per-tab. On enable, both current paths become
  anchor roots; navigation mirrors relative paths both ways. Missing counterpart folder ⇒
  pane stays put + path bar flash, link kept. Off ⇒ independent. State shown in status bar.
- **Transfer queue**: rows = direction icon, name + "source → destination", progress bar,
  "X of Y · speed · ETA" (tabular), state badge (QUEUED grey / UPLOADING·DOWNLOADING·
  RESUMED accent / ERROR red), pause + cancel. Header shows counts; collapsible to one line.
- **Status bar**: ● connection state (green), endpoint + protocol, latency, link state,
  active tunnel count.

## Screen 2 — Connection sheet (new/edit)

Form sheet: Name; Save-in-folder picker; Protocol segmented SFTP/FTP/FTPS/SCP (FTP/FTPS
hide auth-method row, default ports 21/990); Server + Port; Username; Authentication
segmented Password / SSH Key / SSH Agent (agent hidden in APPSTORE builds); password
field with permanent hint "Stored in the macOS Keychain — never written to Ferry's
files. Leave empty to be asked on connect."; collapsed **Advanced**: remote/local start
paths, keep-alive checkbox (30 s + auto-reconnect), saved tunnels count + Edit….
Footer: Test Connection (runs live, inline ✓/✗ + duration; triggers host-key prompt if
needed) · Cancel · Save (accent).

## Screen 3 — Host key dialogs

- **First contact (TOFU)**: 🔑, "Unknown server key for X", explainer, mono fingerprint
  box (`ED25519 · SHA256:…`, selectable), "Remember this key" default-on.
  Buttons: Cancel (destructive-styled) ←→ **Trust & Connect** (primary).
- **Changed key**: ⚠️, red title "Server key has CHANGED", was/now fingerprints, MITM
  warning. Buttons: **Disconnect (Recommended)** = primary; "Replace Key & Connect…" =
  destructive + requires second confirmation.

## Screen 4 — Tunnel manager

Per-connection window: table Active (toggle) / Type pill (LOCAL accent · REMOTE amber ·
SOCKS purple) / Listen (mono) / Destination (mono, "— (dynamic)" for SOCKS) / Status
(live: "● forwarding · N conns" green, "stopped" grey, errors inline red) / Edit.
Footer: ＋ Add Tunnel · "Start active tunnels automatically on connect" checkbox.

## Screen 5 — Settings

Standard macOS settings window, icon tab strip: General · Transfers · Keys · Terminal ·
Advanced. Transfers tab (mocked): simultaneous transfers per connection (default 3);
interrupted policy segmented **Resume automatically** (default) / Ask / Restart with
`.ferrypart` explainer; exists-policy Overwrite / **Ask** / Skip / Rename; retry count
(3× / 5 s); bandwidth limit + checksum verification (v1.x, may ship hidden); queue-done
notification. Footer note: "Changes apply immediately."

## Screen 7 — Embedded terminal (M15.5 — approved 2026-07-18)

*Added to the binding UI contract at the M15.5 checkpoint A review (mockup tab 7,
ADR-023).*

- **Terminal panel**: collapsible, docked below the dual panes and above the transfer
  queue (independent collapse); height draggable at its top edge; open/closed state,
  height, and docked/windowed mode are per connection tab. Header: `＞_ Terminal` +
  endpoint (mono) + live state ("● shell running" green / "session ended" grey) +
  pop-out (⧉), collapse (⌄) and close (✕). Body: the shell (SF Mono, standard ANSI
  palette, follows the app theme). Session-ended state shows an accent-tinted banner
  with "↻ Restart Session".
- **Pop-out window**: ⧉ moves the *same live shell* (session + scrollback intact) to a
  per-connection window titled "Terminal — <profile>"; its header swaps the pop-out
  action for "⇤ Dock in Window", which reverses the move. A popped-out window survives
  disconnecting/closing the browser tab (it owns its session).
- **Terminal-only connections**: an **Open Terminal** item in the sidebar profile
  context menu (SSH profiles only) opens a shell *without* connecting the browser,
  honoring the same dispatch setting — built-in → the standalone terminal window
  ("Dock in Window" hidden; there is no browser tab), external → the M15 hand-off.
  Same host-key TOFU + credential flow as a normal connect.
- **Dispatch**: the existing screen-1 Terminal toolbar button (accent-filled while the
  panel is open) and the Open Terminal menu item act per Settings ▸ Terminal —
  "Ferry's built-in terminal" opens the panel/window; Terminal.app / iTerm2 / custom
  command do the M15 external hand-off.
- **Settings ▸ Terminal tab**: radio group "Open terminal sessions in" (built-in ·
  Terminal.app · iTerm2 · custom command + command field), then built-in options: font
  (family + size) and scrollback line count, with the hint "Scrollback is kept in memory
  only — nothing you type or see is ever written to disk."
- **Visibility rules**: Terminal button only for SSH profiles (SFTP/SCP), absent for
  FTP/FTPS (like Tunnels). Built-in requires macOS 15 (SSH-library gate, as SCP):
  on macOS 14 the Settings option is disabled with "Requires macOS 15" — Direct falls
  back to Terminal.app; APPSTORE builds hide all three external options (Direct-only
  capability) and on macOS 14 disable the toolbar button with the same explainer.
- **Security**: every terminal (panel or window) is its own SSH session reusing the
  profile's resolved credential (no second prompt); nothing typed or displayed is
  logged; scrollback is memory-only.
- **Scope fence**: Ferry's terminal is a convenience, not a terminal app — deliberately
  no terminal tabs, split panes, color themes, or keybinding editors; font and
  scrollback settings only (ADR-023).

## Conventions

- Both themes always (system appearance); mockups demonstrate both.
- Destructive actions styled red and never the default; dangerous flows need a second step.
- Errors are specific and actionable (what failed + how to fix), no apologies.
- Every async action shows progress or state within 100 ms (spinner, badge, or bar).
