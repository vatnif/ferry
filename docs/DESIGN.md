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
  (M14). The Terminal control (M15/M15.5) is live. **Connection tabs are live (M16
  checkpoint B, ADR-027)**: the `.wintabs` strip above the toolbar — one chip per connection
  (green dot connected / grey disconnected), active chip highlighted, per-tab ✕, trailing ＋;
  double-click connects in the current tab, ⌘-double-click / ＋ / ⌘T open a new tab; the sidebar
  is shared. **Within-folder drag reorder is live (M16)** — drop an item onto a profile row to
  reposition it. Pending: remote→Finder promise drag (backlog). Status bar shows first-listing
  round-trip instead of continuous latency for now. **The row context menu gained Open in
  Editor / Open With (M19, Direct only — editor round-trip; see below).**
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
- Screen 3 (host keys & certs): **live (M11; FTPS certs M20 checkpoint C)** — TOFU
  first-contact prompt (🔑, selectable fingerprint box, "Remember this key" default-on) and
  the changed-key alarm (⚠️, Disconnect primary, Replace gated behind a second confirmation).
  Plus the connect-time key-passphrase prompt for encrypted keys. The FTPS certificate
  prompts (📜 untrusted-cert TOFU + ⚠️ changed-cert alarm) mirror the host-key pair exactly
  (ADR-033, signed off 2026-07-20). Pending in this screen: `~/.ssh/config` Import…
  and `~/.ssh/known_hosts` pre-trust (M11 checkpoint B). Screen 4 (tunnels): live (M14).
  Screen 5 (settings): **live (M16 checkpoint A)** — the Settings window with all five tabs
  (General · Transfers · Keys · Terminal · Advanced). General/Keys/Advanced are net-new UI
  drawn into the mockups and signed off (ADR-025); the approved Terminal tab (tab 7) is wired
  reactively over M15's storage with font + scrollback (SwiftTerm scrollback caveat retired,
  ADR-025). The screen-1 connection tab strip is **live (checkpoint B, ADR-027)**.
  **Checkpoint C is complete**: dark-mode conformance audited (no code changes — the UI
  already used semantic/adaptive colors and the mockup color specs), the error-message
  voice unified, and the **Acknowledgements** + **Ferry Help** windows added under the Help
  menu (net-new UI, signed off 2026-07-19, ADR-028). **M16 is complete.**

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
  Edit / Duplicate / Delete / New Folder / **Export…**. Import menu pulls `~/.ssh/config` (M11)
  and — M20 checkpoint A, ADR-031 — FileZilla (`sitemanager.xml`), Cyberduck (Bookmarks folder),
  and WinSCP (exported `WinSCP.ini`) into a source-named folder via a shared checklist sheet
  (`ImportChecklistSheet`); FileZilla/WinSCP folder hierarchy is preserved, no secrets read.
  **M20 checkpoint B (ADR-032)**: Export… (per profile/folder) + File ▸ Export All Connections…
  write a secret-free `.json`; Import ▸ From Ferry Export… re-imports it (fresh "Imported"
  folder, fresh ids, structure preserved) through the same checklist sheet.
- **Tabs**: one per connection; green dot connected, grey disconnected; sidebar shared.
  Double-click connects in the current tab, ⌘-double-click / ＋ / ⌘T open a new tab; per-tab
  ✕ / ⌘W closes (disconnecting it; a running queue confirms first; the last tab resets to an
  empty tab so the window stays). *Implemented M16 checkpoint B (ADR-027).*
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

FTPS certificate dialogs (ADR-033) — the TLS analogue, identical structure:
- **Untrusted certificate (TOFU)**: 📜, "Untrusted certificate for X", explainer, detail
  box (Subject / Issuer / Valid range + `SHA-256 · E1:E5:…` colon-hex fingerprint,
  selectable), "Remember this certificate" default-on. Buttons: Cancel (destructive-styled)
  ←→ **Trust & Connect** (primary).
- **Changed certificate**: ⚠️, red title "Certificate has CHANGED", was/now fingerprints,
  MITM warning. Buttons: **Disconnect (Recommended)** = primary; "Replace Certificate &
  Connect…" = destructive + requires second confirmation. Pins live in Ferry's own trust
  store (never the Keychain); reviewable in Settings ▸ Keys ▸ Trusted certificates.

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

*Implemented M16 checkpoint A (ADR-025/026).* All five tabs ship. **General / Keys /
Advanced** were only sketched in the M0 review notes — they were drawn into
`ferry-mockups.html` screen 5 as M16 proposals and signed off 2026-07-19 (rule 3):
General (default local folder · Light/Dark/System appearance · reopen-last-connections);
Keys (SSH key list · Generate/Import [Direct only] · ssh-agent disabled/"planned" · manage
Ferry's known hosts · **manage trusted FTPS certificates** [ADR-033, added M20 checkpoint C,
signed off 2026-07-20]); Advanced (logging level + reveal · experimental-features flag). The
**Terminal** tab renders the already-approved tab 7 over M15's storage plus built-in font +
scrollback. Bandwidth + checksum ship **visible-but-disabled** ("v1.x") rather than hidden.

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

## Help menu — Ferry Help + Acknowledgements (M16 checkpoint C — approved 2026-07-19)

*Net-new UI, not in the M0 mockups → signed off 2026-07-19 (rule 3), ADR-028. Both are
standalone single-instance windows opened from the **Help** menu (which replaces the default
help item), so — unlike the Settings scene (ADR-025) — they are XCUITest-drivable.*

- **Help ▸ Ferry Help** (⌘?): a minimal in-app user guide — short prose topics (getting
  connected, transferring files, the **`.ferrypart`/resume explainer**, tabs & windows, the
  built-in terminal) followed by a **keyboard-shortcut reference** table (incl. the M16-B tab
  affordances: ⌘T new tab, ⌘W close tab, ⌘-double-click new tab, ⌘⇧I import). Deliberately
  minimal — a searchable/contextual help system is backlog item 9.
- **Help ▸ Acknowledgements…**: the license notices for every bundled dependency
  (name · what Ferry uses it for · copyright · license pill, with the full license text behind
  a disclosure). Sourced from `docs/LICENSING.md` — satisfies the MIT/Apache-2.0/curl notice
  obligations (rule 4).
- **Content is pure + testable.** Both windows only *render* the `HelpContent` and
  `Acknowledgements` value models in FerryCore; unit tests pin list integrity (every notice has
  a copyright + an allowed license; the shortcut list covers the tab affordances). M19 adds an
  **"Editing remote files"** topic and the `⌘E` shortcut row.

## Editor round-trip (M19 — approved 2026-07-20)

*Net-new UI, not in the M0 mockups → signed off 2026-07-20 (rule 3), ADR-030. Direct builds
only — launching another app can't work in the App Store sandbox, so these entries are absent
there (like the external-terminal options).*

- **Row context menu (remote pane)** gains, right after "Quick Look": **Open in Editor** (uses
  the Settings default editor) and an **Open With ▸** submenu listing the apps that can open the
  file (via `NSWorkspace`) plus **Other…** (pick any app). On the **local pane** a single **Open
  in Editor** opens the file in place. `⌘E` (File menu) opens the current selection.
- **Behavior**: a remote file downloads to a private temp copy, opens in the editor, and every
  save auto-uploads the changes back — surfaced as an ordinary **transfer-queue row** (the
  approved *minimal* treatment; no separate active-edits panel). See DOMAIN.md → Editor
  round-trip.
- **Settings ▸ General** gains an **"Editing"** section: a **Default editor** row (app name or
  "System default", with **Choose…** / **Clear**), matching the existing "Default local folder"
  row's layout. Present only in the Direct build.

## Conventions

- Both themes always (system appearance); mockups demonstrate both. Appearance is applied
  app-wide via `NSApp.appearance` (ADR-025 — never `preferredColorScheme` at the WindowGroup
  root). **Dark-mode conformance was audited screen-by-screen at M16 checkpoint C**: the UI
  uses semantic/adaptive colors throughout (`Color.accentColor`, `.secondary`,
  `Color(nsColor: .controlBackgroundColor/.textBackgroundColor)`, and the semantic status set
  green/amber/red), so both themes track the mockups without hardcoded overrides. The only
  fixed-RGB color is the SOCKS type pill (`#7a5fd0`) — which the mockup CSS also pins in both
  themes, so it is conformant by design.
- Destructive actions styled red and never the default; dangerous flows need a second step.
- Errors are specific and actionable (what failed + how to fix), no apologies.
- Every async action shows progress or state within 100 ms (spinner, badge, or bar).
