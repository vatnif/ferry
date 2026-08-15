# Ferry — progress tracker

> Update this file at the end of **every working session** and **every milestone**
> (rule 1 in CLAUDE.md). States: `todo` · `in progress` · `awaiting review` · `done`.

## Milestones

| # | Milestone | State |
|---|---|---|
| M0 | UI mockups & approval | **done** (approved 2026-07-05, incl. icon concept A + sync browsing) |
| M1 | Scaffolding, docs & test infra | done (committed 97fccf4) |
| M2 | Domain models & profile store | done (committed 18d38e5) |
| M3 | CredentialVault (Keychain) | done (committed dff4ded) |
| M4 | Connection Manager UI | done (committed 3d17f7c) |
| M5 | FileSystemSource protocol + LocalFileSource | done (committed 27e1dfe) |
| M6 | SFTP spike → SFTPSource (read-only) | done (committed 3c9567a) |
| M7 | Dual-pane browser UI | done (committed c23cf04) |
| M8 | TransferEngine + queue UI | done (committed b1c9394) |
| M9 | Resume & robustness | done (committed 388de0d) |
| M10 | File operations | done (committed 9cfe66a) |
| M11 | Key auth & host trust | done (checkpoint A ffd7233, checkpoint B a008639) |
| M12 | FTP/FTPS via libcurl | done (committed 7223169) |
| M13 | SCP | done (committed 6b1e981) |
| M14 | Tunneling | done (committed 7938556) |
| M14.5 | Remote port forwarding | done (committed a4899a2) |
| M15 | Open in Terminal | done (committed d500ac3) |
| M15.5 | Embedded terminal (SwiftTerm) | done (A+B d7971a8, C 6410384) |
| M16 | Tabs & polish | **done** (A ec114e2 · B c6942fb · C 2f3b553) |
| M17 | Packaging (sign/notarize/DMG/Sparkle) | todo (deferred 2026-07-19 — required before sale) |
| M18 | Sale readiness | todo (deferred 2026-07-19 — required before sale) |
| M19 | Editor round-trip (Phase G) | **done** (ADR-030, 2026-07-20) |
| M20 | Switchers & trust (Phase G) | **done** — A committed ea43d51; B committed ccb252b; C committed 92796ff |
| M21 (pulled forward) | Remote→Finder drag-out (`NSFilePromiseProvider`) | **in progress** — A committed 735b955; B committed 1420349; C todo |
| M21–M31 | Post-v1 Phases G–K (v1.1–v1.5) | todo (planned 2026-07-19, ADR-029) |

Post-v1 plan (Phases G–K, M19–M31): see `docs/ROADMAP.md`. M20 is **split into 3 checkpoints**
(approved 2026-07-20): **A** competitor importers (FileZilla/Cyberduck/**WinSCP**) · **B**
secret-free profile export/import · **C** FTPS self-signed cert TOFU (ADR-033, committed 92796ff).
**M20 complete.** M17/M18 still deferred.

## Current state of the code (M21 checkpoint B — groups/plan/policy in FerryCore — committed 1420349)

- **The engine-side machinery for a truthful Finder drag-out promise is built and green** —
  all headless FerryCore, no AppKit, no UI change (per the plan:
  `/Users/gfragos/.claude/plans/quirky-cuddling-quasar.md` → Checkpoint B). Checkpoint C wires
  it into `RemoteDragBridge` (replacing the 30 s stub promise) and writes ADR-038.
- **`TransferRequest`/`TransferSnapshot` gained an optional `groupID`** (defaulted — every
  existing call site compiles unchanged; snapshot's memberwise init stays internal), threaded
  through `enqueue`'s initial snapshot and `performDirectory`'s child requests, so a whole
  dragged tree shares one group.
- **New `Transfer/TransferGroups.swift`**: `TransferGroupTracker` (actor; constructed WITH the
  engine so it can never miss a member) turns member snapshots into one
  `AsyncStream<TransferGroupEvent>` per group — `.progress` (aggregate bytes; `totalBytes` nil
  until enumeration closes, then the exact sum), `.stalled` (a paused member holds the group
  open), `.finished(outcome)` (failed ▸ cancelled ▸ completed precedence; stream ends). This
  exists because **`performDirectory` marks a folder `.completed` when its children are merely
  *enqueued*** — awaiting the root would tell Finder "done" far too early. The stopping rule
  "every known member is finished" carries the three planned guards, each pinned by a test:
  the **seeded root** (else vacuously true for an empty group), **explicit `.paused` handling**
  (not `isFinished` — would hang forever), and a **frozen conclusion** (`resume` on a failed
  directory re-enqueues members; no second `.finished`). `cancelGroup` also cancels members
  that surface after the call (the enqueue/consume race).
- **New `Transfer/DragOut.swift`**: `DragOutPlan` (always `mode: .restart` — the resume
  heuristic would silently append a stranger's fresh same-size `.ferrypart` at the drop
  location; direct-to-destination, no temp-then-move) with the `litter(after:)`/`cleanUp`
  policy — a file's litter is only its `.ferrypart` (Finder owns the destination URL); a
  directory the drag created is removed whole on failure/cancel; a **pre-existing directory is
  never deleted**; cleanup only on `.finished`, never `.stalled` (pause keeps partials so
  Resume still lands the file). `DragOutPolicy.itemsToDrag` = Finder selection semantics.
- Tests: **446 kit green (+17: TransferGroupTrackerTests 13, DragOutTests 4** — incl. the
  invariant test capturing the destination at the instant `.finished` arrives on a nested
  tree; `InMemoryFileSource` gained a `listFailuresRemaining` knob; ADR-014 timer-race
  waits**)**, integration suites ran against live Docker servers; the new tracker suite is
  stable across 3 consecutive runs. XCUITests (run as belt-and-braces — no UI changed):
  21/22 green; the one failure is `testEmbeddedTerminalTouchShowsFileInRemotePane`, the
  documented under-load flake, which passed its solo re-run as always. Both flavors build
  (Direct + AppStore). TESTING.md updated; the remaining docs (ADR-038, DOMAIN, DESIGN,
  ARCHITECTURE, ROADMAP) are checkpoint C's per the plan. **Approved after a hands-on run
  of the Direct build & committed (1420349).**

## Current state of the code (M21 pulled forward — remote→Finder drag-out, checkpoint A — committed 735b955)

- **The remote pane's rows can now be dragged out to Finder** (spike level — ADR-038 to be
  written in checkpoint C). Full plan + the complete measured record:
  `/Users/gfragos/.claude/plans/quirky-cuddling-quasar.md` (the only durable copy of the
  measurements until ADR-038 exists — keep it).
- **New**: `Ferry/Models/RemoteDragBridge.swift` (session-scoped `NSDraggingSource` + promise
  delegates; checkpoint-A stub promise `useStubPromise = true` — 30 s fake progress then a tiny
  file/directory), `Ferry/Views/RemoteDragHandle.swift` (transparent AppKit overlay on the row
  icon: click selects, double-click navigates/Quick Looks — retiring that ADR-013 wart — ⌘/⇧
  clicks forwarded to the table's native toggle/extend, drag past 3 pt starts the promise drag),
  `Ferry/Models/RemoteDragPayload.swift` (Transferable over Ferry's declared drag type), and
  **`Ferry/Info.plist`** — the target's first real plist, holding ONLY `UTExportedTypeDeclarations`
  for `com.gfragos.ferry.drag-item`; merged with the generated plist (`GENERATE_INFOPLIST_FILE`
  stays YES; `INFOPLIST_FILE` wired into the 4 app configs; `Info.plist` added to the
  synchronized-folder membership-exception set).
- **The drag shape, arrived at by measurement** (full matrix in the plan file): one dragging item
  per row (the file promise — so Finder's count badge is truthful; it counts *dragging items*
  regardless of type), with the M8 `ferryitem|…` payload appended straight to
  `session.draggingPasteboard` under the declared type (SwiftUI decodes nothing off a
  promise-bearing item, even declared/`.string` types; an undeclared UTI never matches; a
  `.string` second item badged 2 per row and pasted raw text into TextEdit).
  `FileBrowserPane`'s inter-pane drop is now `.dropDestination(for: RemoteDragPayload.self)`.
- **Cancelled drags release their promise delegates** (`draggingSession(_:endedAt:)`, per-session
  token tracking) — a no-drop drag would otherwise leak them; on a real drop they're retained
  until the promise resolves (Finder can fulfil it after the session ends).
- **User-verified by hand in BOTH flavors** (Finder is XCUITest-undrivable): truthful badge
  (1 file → plain ＋, 2 → ＋2), file + folder promises land (30 s deferred completion honoured),
  same-name drop, drop-onto-folder-icon, TextEdit no-op (no text leak), cancelled drag clean,
  ⌘/⇧ selection, pane-to-pane real download. Sandbox writes to the drop folder work.
  **Measured, do not re-litigate**: published `NSProgress` produces NO Finder indicator — dropped
  from scope.
- **Still open for checkpoint C**: dragging an unselected row doesn't update the selection to
  match (decide); scroll-perf on multi-thousand-row listings unmeasured; multi-minute sandbox
  extension lifetime unproven (stub is 30 s).
- Tests: **429 kit + 22 XCUITests green** (+3 XCUITests: icon click/double-click, icon
  right-click context menu, and the M8 regression gate — icon drag to the local pane still
  enqueues a download). `testEmbeddedTerminalTouchShowsFileInRemotePane` remains the known
  under-load flake (fails in 2 of 3 full-suite runs today, passes every solo re-run — the
  pre-existing note stands). Both flavors build. **Awaiting review — nothing committed.**
  Checkpoints B (groups/plan/policy in FerryCore) and C (real engine-backed promise, integration
  tests, ADR-038 + docs) are next. **Approved & committed (735b955).**

## Current state of the code (bug fix — terminal windows are never restored, ADR-037 — committed adcb099)

- Closes the item ADR-036 left open. A standalone terminal window is a view onto a live in-memory
  `TerminalController`, so after an abnormal termination macOS restored empty windows reading "This
  terminal session has ended" (up to three seen at once; proven to be restoration because
  `-ApplePersistenceIgnoreState YES` made them vanish).
- **Fix**: `.restorationBehavior(.disabled)` on the terminal `WindowGroup`. The modifier is macOS
  15+ and `if #available` in a `@SceneBuilder` has no `else`, which is right here — every opener of
  that window is already macOS-15 gated (both `BrowserView` sites, and `pendingTerminalWindowID`
  which only `startTerminalOnly` sets), because the built-in terminal needs Citadel's `withPTY`.
  On macOS 14 the scene has nothing to open, so it no longer exists.
- **Also**: `TerminalWindowView` now dismisses when its controller id doesn't resolve instead of
  showing the dead-end "session has ended" text — that state only means the window outlived what it
  was a view onto.
- **Verified**: pop-out → re-dock re-checked by hand against :2223 (window opens, shell keeps
  running, re-dock returns it to its tab) plus the two ADR-035 XCUITests; **429 kit + 19 XCUITests
  green**. **Limit, stated plainly**: once the system's saved state was cleared, the restoration
  could not be re-triggered on demand (neither ⌘Q nor SIGKILL with a window open reproduced it), so
  this rests on the observed failure + the documented API, not a live before/after. No regression
  test — cross-launch OS restoration isn't XCUITest-drivable, and the suite now disables it.
- Noted in passing: `testEmbeddedTerminalTouchShowsFileInRemotePane` can flake on its 20 s
  `browser.status.connected` wait when the whole suite hammers the emulated container; it passes on
  re-run. Not chased.

## Current state of the code (bug fix — sidebar hidden at launch, ADR-036 — committed 2e84f7e)

- **The app launched with the sidebar hidden.** `MainWindow`'s `NavigationSplitView` never set
  `columnVisibility`, and `.automatic` resolved to hidden on this macOS: the window showed only the
  "No Connection Selected" placeholder, with the connection list reachable only via the system
  "Show Sidebar" toolbar button. Not stale prefs — clearing the whole `com.gfragos.Ferry` defaults
  domain changed nothing, and it reproduces at `ec114e2` (before the tab strip, split view at the
  window root). Fixed by binding `@State columnVisibility = .all`; the user's Hide/Show toggle
  still works for the session, and the choice is deliberately not persisted.
- **UI tests now isolate window state too** (`-ApplePersistenceIgnoreState YES`): macOS was
  restoring the previous Ferry's windows into each test app, so runs that popped a terminal out
  left dead "Terminal" windows in later tests' `app.windows`.
- **This closed all four pre-existing UI-test failures** (`testAppLaunchesWithSidebarAndEmptyState`,
  both Help-window tests, `testImportFromSSHConfigAddsProfiles`) — they were failing on a clean
  tree, not because of the ADR-035 work. **Full suite green: 429 kit + 19 XCUITests.**
- **Known, not fixed**: on a normal relaunch macOS still restores popped-out terminal windows with
  dead sessions ("This terminal session has ended."). Needs `restorationBehavior(.disabled)` on the
  terminal `WindowGroup` (macOS 15+, availability-split scene) — its own decision, see ADR-036.

## Current state of the code (bug fix — per-tab terminal identity, ADR-035 — committed 5334cb7)

- **User-reported**: with two connected tabs, the terminal opened in tab 1 kept appearing under
  tab 2's file panes, and opening a terminal in both made things incoherent. **Reproduced** with a
  new XCUITest before any code change.
- **Root cause is the view layer, not the models.** Per-tab ownership was already correct
  (`ConnectionTab.phase → BrowserSession → TerminalController`, ADR-023/027). But
  `DetailPlaceholderView` builds `BrowserView` in a `switch` branch with no `.id(...)`, so every
  connected tab shares one SwiftUI identity. `SSHTerminalView` is the app's only
  `NSViewRepresentable` and `makeNSView` runs **once per identity** — a tab switch called only
  `updateNSView`, keeping tab 1's live `TerminalView` while the struct's `bridge` pointed at tab 2's
  session: wrong screen, keystrokes on the wrong server (the reused view's delegate is still bridge
  1), and tab 2's bridge never attached (no pump → its shell's output piled up unconsumed; PTY
  stuck at 80×24).
- **Only bites with both panels open** — switching to a tab whose panel is closed destroys the
  subtree, so the next panel gets a fresh identity. **Detaching sidesteps it** (a pop-out lives in
  its own `WindowGroup` scene). **Worst variant: re-dock** — "Dock in Window" pressed while another
  tab's panel is open strands the returning shell (alive, invisible, unreachable).
- **Fix**: `.id(controller.id)` on the `SSHTerminalView` inside `TerminalPanelView` (covers docked
  panel + both window flavours) and `.id(terminal.id)` on the docked panel in `BrowserView`.
  Deliberately *not* `.id(tab.id)` on `BrowserView` — that rebuilds the whole subtree per switch and
  resets the `HSplitView` divider. Debug tripwire: `updateNSView` asserts `view === bridge.view`.
- **Same root cause, also fixed**: `BrowserView`'s `@State` was shared across tabs. Staged
  conflicts, resume decisions, `newFolderName` and `showTunnels` moved onto `BrowserSession`;
  staging is async, so dropping files in one tab and switching before it finished could surface the
  "already exists" alert over another tab and enqueue into *its* session (transfer to the wrong
  server). `terminalDragBase` stays `@State`.
- **Tests**: +1 kit (`TerminalSessionBridgeTests.testEachBridgeOwnsItsOwnViewAndOutput`) and +2
  XCUITests (`testTerminalsInTwoTabsStayIndependent`, `testRedockedTerminalReturnsToItsOwnTab`),
  both confirmed failing before the fix. **430 kit tests green** (18 skipped); UI suite green
  except four **pre-existing** failures unrelated to this change (verified on a clean tree):
  `testAppLaunchesWithSidebarAndEmptyState`, both Help-window tests, and
  `testImportFromSSHConfigAddsProfiles` — the sidebar also fails to appear when driving the app by
  hand, so this needs its own investigation.
- Docs updated: ADR-035, ARCHITECTURE (per-tab view identity), TESTING (new tests). No mockup/spec
  change — this restores what DESIGN.md screen 7 already specifies.

## Current state of the code (M20 checkpoint C — FTPS certificate TOFU — done, committed 92796ff)

- **Third and final M20 checkpoint** (Phase G / v1.1; ADR-033) — **completes M20**. Pays down the
  M12/ADR-019 debt: an FTPS server whose certificate doesn't chain to a system-trusted root used to
  dead-end at `.tlsFailed`. Now Ferry does **trust-on-first-use for certificates**, modelled exactly
  on the SSH host-key TOFU (ADR-016): capture the offered cert, show its fingerprint, trust
  (remember) or cancel, **pin** it, and re-validate identically on every later connect + supervised
  reconnect.
- **Key risk spiked first (retired in the ADR).** System libcurl (8.7.1, **SecureTransport**) on
  macOS: `CURLINFO_CERTINFO` **is** populated even at `VERIFYPEER=0` (full leaf PEM) → capture; and
  `CURLOPT_PREREQFUNCTION` fires after TLS+login but **before any transfer**, with certinfo ready →
  Ferry pins by comparing the presented leaf's DER SHA-256 to the stored pin and aborts on mismatch,
  on **every** handle (control + data), before a byte flows. No bundled TLS lib, no backend switch.
- **Pure FerryCore `TLS/`** (unit-tested): **`CertificateInfo`** (subject/issuer/validity + whole-cert
  **DER SHA-256**, built from the CERTINFO fields; colon-hex display) and **`CertificateTrustStore`**
  (`FERRY_DATA_DIR`-aware plaintext **JSON**, keyed `host:port`; `trust`/`replace`/`remove`/
  `trustedCertificate`/`storedInfos`/`contains`/`allTrustedCertificates`) — the analogues of
  `HostKeyInfo`/`HostKeyStore`, kept as separate types. A cert is public info, never a secret
  (rule 6) — plaintext store, nothing in the Keychain.
- **Seam** (`FTPSource` + `CFTP` shim): `connect` gains `trustedCertificate:` (the pin). No pin +
  untrusted → capture-retry → new `RemoteSourceError.certificateUntrusted`; pinned + mismatch →
  `RemoteSourceError.certificateChanged(stored:offered:)`. The pin lives in the source's in-memory
  `Parameters`, so `reestablish()` (ConnectionSupervisor) re-applies it identically — **the
  security-critical invariant: a supervised reconnect never silently downgrades trust.** Shim gained
  `ferry_getinfo_certinfo` + `ferry_set_prereq_cb` + the prereq OK/ABORT constants. The
  `allowInvalidCertificate` test hook is **kept** alongside (never enabled in the app).
- **App**: `CertificatePrompt` + **`CertificatePromptSheet`** mirror `HostKeyPrompt`/
  `HostKeyPromptSheet` — 📜 first-contact (subject/issuer/validity + fingerprint, Remember toggle)
  and ⚠️ changed-cert alarm (Disconnect primary; Replace behind a second confirmation; was→now).
  Threads a `tabID` (tabbed connections, ADR-027). "Remember off" pins for the session only.
  Settings ▸ Keys gains a **Trusted certificates** section + `TrustedCertsManagerSheet` (parallel to
  Manage known hosts).
- **Net-new UI signed off** (rule 3, ADR-033): the cert prompt (both states) + Settings management
  section drawn into `docs/design/ferry-mockups.html` + `docs/DESIGN.md`. Help gains FTPS-cert copy
  (+ a HelpContent guard). **No new dependency** (system libcurl + swift-crypto, already direct).
- **Both distributions** (rule 5): pure libcurl + a store under `FERRY_DATA_DIR`/the container —
  sandbox-safe, no `#if APPSTORE` gating. **Both flavors build** (Direct + AppStore). Tests: **417
  kit (+20: CertificateInfo 5, CertificateTrustStore 10 unit; +4 `FTPSCertTrustTests` real trust
  path vs :2990 [capture+fingerprint, trust→connect, reconnect pins no re-prompt, changed rejected];
  +1 HelpContent guard) + 17 XCUITests, all green.** No new XCUITest — the trust sheet launches from
  a live FTPS connect (not headless-drivable); TESTING.md manual checklist covers it, the
  capture/pin/mismatch logic is automated. **No testinfra changes. Approved & committed (92796ff)
  — M20 complete.**

## Current state of the code (M20 checkpoint B — Profile export/import — done, committed ccb252b)

- **Second M20 checkpoint** (Phase G / v1.1; ADR-032). Ferry's own **secret-free** connection
  export/import for moving connections between Macs / backup. The store is already
  self-contained, schema-versioned, secret-free JSON, so export serializes a chosen slice and
  import decodes + merges.
- **Pure FerryCore `Store/ConnectionExport.swift`** (unit-tested): a self-describing, versioned
  envelope (`format: com.gfragos.ferry.connections`, `formatVersion`, `generator`, `exportedAt`,
  `items: [SidebarItem]`), reusing `ConnectionStore`'s JSON conventions. `encode`/`decode` (typed
  errors: not-a-Ferry-export / unsupported-version / corrupted), `sanitized` (strips per-machine
  `lastLocalPath`/`lastRemotePath`, keeps configured start paths), `flatten` → `[ImportEntry]`.
  **No secrets** — asserted structurally + by a "no password/passphrase/secret keys" test.
- **`ConnectionLibrary.addImported(_:intoFolderNamed:)`** (pure, unit-tested): the shared
  import-merge — new folder, rebuilt subfolder hierarchy, **fresh UUIDs for every imported item**
  (the id-collision policy: an import never overwrites/aliases existing items). Checkpoint A's
  competitor import was **refactored to route through it** too.
- **Export (user decision): per-item + Export All.** Sidebar row context menu ▸ **Export…**
  (profile or folder subtree) + **File ▸ Export All Connections…**; `NSSavePanel` (`.json`),
  `FERRY_EXPORT_PATH` test override. **Import (user decision): fresh "Imported" folder** via
  **Import ▸ From Ferry Export…** (both sidebar + File menus); `NSOpenPanel`, `FERRY_IMPORT_PATH`
  override.
- **Checklist reuse (rule)**: generalized into **`ImportChecklistSheet`**; `ProfileImportSheet`
  (checkpoint A) refactored onto it and the new `FerryImportSheet` uses it. M11's `SSHImportSheet`
  left as-is.
- **Both distributions** (rule 5): save/open panels are sandbox-legal — no `#if APPSTORE`. **No
  new dependency** (Foundation JSON only). **Net-new UI signed off** (rule 3, ADR-032): mockups +
  DESIGN.md. Help gains export/import copy (+ a HelpContent guard).
- **Both flavors build** (Direct + AppStore). Tests: **397 kit (+12: ConnectionExport 7,
  ConnectionLibraryImport 3 unit; +1 `ConnectionExportIntegrationTests` export→import→connect
  :2222; +1 HelpContent guard) + 17 XCUITests, all green.** No new XCUITest — save/open-panel +
  menu launch isn't headless (TESTING.md manual checklist; the format/merge logic is automated).
  **No testinfra changes. Approved & committed (ccb252b).**

## Current state of the code (M20 checkpoint A — Competitor importers — done, committed ea43d51)

- **First M20 checkpoint** (Phase G / v1.1 "switchers & trust"; ADR-031). Imports saved sites
  from **FileZilla**, **Cyberduck**, and **WinSCP** (the third added at user request during
  planning), mirroring the M11 `~/.ssh/config` pipeline. Sidebar **Import** menu + **File ▸
  Import Connections** submenu → a checklist sheet → profiles under a fresh `<Source> Import`
  folder. **No secrets read** (rule 6) — passwords prompted on first connect.
- **Pure FerryCore `Import/`** (unit-tested): a unified **`ImportedConnection`** value type
  (`makeProfile()`, `folderPath`) shared by three parsers — **`FileZillaImporter`** (event-based
  `XMLParser` over `sitemanager.xml`, `<Folder>` hierarchy preserved, `<Pass>` ignored),
  **`CyberduckImporter`** (`PropertyListSerialization` over `.duck` bookmark plists,
  Bookmarks-folder only), **`WinSCPImporter`** (self-contained INI reader over an exported
  `WinSCP.ini`, `[Sessions\…]` percent-encoded folder names decoded, `Password` ignored).
  Protocol maps drop what Ferry can't speak (HTTP/S3/WebDAV). M11's `ImportedSSHHost`/
  `SSHImportSheet` left **untouched** (deliberate — ADR-031).
- **App**: generalized **`ProfileImportSheet`** (checklist over `ImportedConnection`, shows
  source folder path + 🔑 badge); `ConnectionManagerModel` gains `ProfileImportContext` +
  `beginFileZillaImport()/beginCyberduckImport()/beginWinSCPImport()` (each `NSOpenPanel`-picks
  the source, `FERRY_*` env overrides for tests) + `importConnections(_:sourceName:)` which
  **rebuilds the source folder hierarchy** as nested folders (FileZilla/WinSCP) under the import
  folder. **Both flavors** ship the feature — reading a user-picked file is sandbox-legal (no
  `#if APPSTORE` gating, unlike terminal/editor).
- **Net-new UI signed off** (rule 3, ADR-031): the Import menu entries + shared import sheet are
  drawn into `docs/design/ferry-mockups.html` and `docs/DESIGN.md`.
- **No new dependency** — `XMLParser`/`PropertyListSerialization`/the INI reader are all
  Foundation/hand-rolled (LICENSING.md unchanged).
- **WinSCP `.ppk` caveat** (DOMAIN.md/help): PuTTY keys can't be loaded by `SSHKeyLoader`
  (ADR-017); the path imports as-is so the site is visible, to be repointed at an OpenSSH key.
- **Both flavors build** (Direct + AppStore). Tests: **385 kit (+30: FileZilla 8, Cyberduck 8,
  WinSCP 10 unit = 26; +3 `CompetitorImportIntegrationTests` [FileZilla+WinSCP→SFTP :2222,
  Cyberduck→FTP :2121]; +1 HelpContent guard) + 17 XCUITests, all green.** No new XCUITest — the
  file-picker/menu launch isn't headless-drivable (covered by a TESTING.md manual checklist;
  the parsers/mapping/import logic are automated). **No testinfra changes. Approved & committed
  (ea43d51).**

## Current state of the code (M19 — Editor round-trip — done, committed 1afeca2)

- **First Phase G / v1.1 feature (ADR-030).** Right-click a **remote** file → **Open in Editor**
  (uses the Settings default editor) or **Open With ▸ <app>** (per-file; "Other…" picks any app);
  `⌘E` opens the selection. Ferry downloads the file to a private temp copy, opens it in the
  editor, **watches it, and auto-uploads every save back** to the original remote path — surfaced
  as ordinary transfer-queue rows (the approved *minimal* UI; no active-edits panel). Sessions
  end on disconnect / tab close (watchers cancelled, temp copies deleted).
- **No new dependency** — `DispatchSource` + `NSWorkspace` are system frameworks (LICENSING.md /
  acknowledgements unchanged, confirmed).
- **Pure FerryCore `Editor/`** (unit-tested): `FileWatcher` (a `DispatchSource` vnode source →
  coalesced `AsyncStream<Void>`; **debounces a save's event burst into one upload** and **re-arms
  on the atomic write-then-rename save** most editors use) and `EditorLaunch`
  (`EditorTarget` + `EditorDispatch.resolve` — default / per-file override / App-Store
  `.unavailable`, mirroring `TerminalDispatch`). New `AppSettings.Key.defaultEditor`.
- **App target**: `ExternalEditorLauncher` (`#if !APPSTORE`) — enumerate candidate apps
  (`NSWorkspace.urlsForApplications`), "Other…" picker, launch via
  `NSWorkspace.open(_:withApplicationAt:configuration:)`. The **editing-sessions tracker lives on
  `BrowserSession`** (keyed by remote path; reuses `remote.source.openRead` to stage into a
  per-session `FerryEdit/<uuid>/<name>` temp dir, and enqueues a `.restart` upload on each watcher
  emission — the existing `queue.onCompleted` reloads the remote pane). Row context menu gains the
  two items (accessibility ids `context.openInEditor` / `context.openWith`); `⌘E` command +
  Settings ▸ General "Editing" default-editor picker. **All Direct-only** — absent in the App
  Store build (launching apps can't work sandboxed, like the external terminal ADR-024);
  `EditorDispatch` resolves to `.unavailable` there.
- **Net-new UI signed off** (rule 3, ADR-030): the menu items + Settings picker are drawn into
  `docs/design/ferry-mockups.html` and `docs/DESIGN.md`.
- **Both flavors build** (Direct + AppStore). Tests: **355 kit (+14: EditorLaunch 6, FileWatcher
  5, EditorRoundTrip integration 2, HelpContent 1) + 17 XCUITests (+1: remote-row menu offers
  Open in Editor / Open With)**, all green. The real editor launch isn't headless-testable —
  covered by a TESTING.md manual checklist (the dispatch/watcher/upload pieces are automated).
  Help updated: an **"Editing remote files"** topic + the `⌘E` shortcut, with a test guard.
  **Awaiting review — nothing committed.**

## Current state of the code (M16 checkpoint C — Polish — done, committed 2f3b553)

- **The final M16 checkpoint** (approved 2026-07-19: A Settings · B Tabs · **C Polish**). Four
  workstreams: a dark-mode conformance audit, an error-message voice pass, an **Acknowledgements**
  screen, and a **Help menu** guide. **M16 is complete after this.**
- **Acknowledgements + Help are new Help-menu windows** (net-new UI, signed off 2026-07-19,
  ADR-028). `FerryApp` gains two single-instance `Window` scenes (`help`, `acknowledgements`) and
  a `HelpMenuCommands` (`CommandGroup(replacing: .help)`, reading `openWindow` from the
  environment) → **Help ▸ Ferry Help** (⌘?) and **Help ▸ Acknowledgements…**. Chosen as
  standalone windows over Settings tabs specifically because the `Settings` scene isn't
  XCUITest-openable (ADR-025) but a `Window` is — so the new UI gets real automated coverage.
- **Pure content in FerryCore `Help/`** (unit-tested): `HelpContent` (prose topics incl. the
  `.ferrypart`/resume explainer + a `HelpShortcut` keyboard reference covering the M16-B tab
  affordances) and `Acknowledgements` (`Acknowledgement` + `DependencyLicense` with reproducible
  MIT/Apache-2.0/curl license bodies, mirroring `docs/LICENSING.md`). The SwiftUI windows only
  render these models. `HelpContentTests` fails the build if a listed dependency's license isn't
  policy-allowed (rule 4) or the inventory drops a shipped dependency.
- **Dark-mode audit — no code changes needed.** An exhaustive color sweep + mockup cross-check
  found the UI already uses semantic/adaptive colors throughout (`accentColor`, `.secondary`,
  `Color(nsColor: .controlBackgroundColor/.textBackgroundColor)`, the green/amber/red status
  set); the one fixed-RGB color (the SOCKS pill `#7a5fd0`) matches the mockup CSS, which pins it
  in both themes too. Appearance stays applied via `NSApp.appearance` (ADR-025 — never
  `preferredColorScheme` at the WindowGroup root). Headless screenshotting is blocked by
  screen-recording permission, so the visual pass is a TESTING.md manual checklist; the app was
  confirmed to launch cleanly in dark mode.
- **Error-message voice pass**: apostrophes normalized to typographic curly `’` across all
  user-facing strings (matching the curly quotes already used for paths; the shell-quoting
  literals in `TerminalLaunch.swift` were deliberately left as straight `'`), and the four
  `Couldn’t …` strings folded into the dominant `Could not …`. The three alert channels
  (`errorMessage` / `infoMessage` "Not yet available" / `noticeMessage`) stay distinct; no
  secrets are interpolated (rule 6).
- **Both flavors build** (Direct + AppStore). Tests: **341 kit (+7 `HelpContentTests`) + 16
  XCUITests (+2: Help ▸ Ferry Help window, Help ▸ Acknowledgements… window), all green.** The
  Settings-hosted UI stays covered by the TESTING.md manual checklist (ADR-025). **Approved &
  committed (2f3b553) — M16 complete.**

## Current state of the code (M16 checkpoint B — Tabs — done, committed c6942fb)

- **The main window is now tabbed** (screen 1 `.wintabs`, ADR-027). `ConnectionManagerModel`'s
  single `connectionPhase` became `tabs: OrderedTabs<ConnectionTab>` — an ordered
  selected-collection where **each `ConnectionTab` carries its own `ConnectionPhase`**
  (`.idle`/`.connecting`/`.connected(BrowserSession)`). A connected tab owns a full
  `BrowserSession` (panes/queue/tunnels/terminal/Linked already per-session since M7–M15.5), so
  tabs are independent. The detail column renders the **selected** tab; the sidebar is shared.
- **Pure `OrderedTabs<Element>`** (FerryCore, unit-tested): add/select/close/move with the
  selection-preservation rules (close selected → same-index neighbour → new last → empty). App-
  type-free and non-`Sendable`.
- **Tabs UI**: new `TabStripView` above the detail — one chip per tab (green dot connected / grey
  otherwise), active chip highlighted, per-tab ✕, trailing ＋. `TabChip` is two side-by-side
  buttons (select + ✕) sharing one background — an overlay ✕ was un-findable by XCUITest
  (accessibility merges overlapping buttons).
- **Affordances** (rule 3 — signed off 2026-07-19, ADR-027): ＋ / ⌘T (File ▸ New Tab) /
  ⌘-double-click-in-sidebar open a tab; plain double-click + detail **Connect** connect **in the
  current tab** (replacing its session). Per-tab ✕ / ⌘W close (⌘W via a hidden shortcut button so
  it never closes the window). Closing a tab with running/queued transfers **confirms first**;
  closing the last tab keeps the window with one empty tab.
- **Connect flow threads the target tab** through the async password/passphrase/host-key prompts
  (each prompt gained `tabID`); a connect whose tab was closed mid-flight tears the session down
  (`finishConnect(_:into:)`) instead of leaking. **Disconnect** returns a tab to the grey-dot
  disconnected state (keeps its profile → summary + reconnect). Terminal window plumbing
  (`terminalWindowStorage`/`pendingTerminalWindowID`) stays model-global; a popped-out terminal
  survives disconnect *and* tab close (`canRedock=false`), a docked one shuts down.
- **Reopen last connections → N tabs**: restore reopens every saved connection (first reuses the
  initial empty tab, rest new tabs), reconnecting each; persistence lists the connected tabs'
  profile IDs. Known limitation: several restores each needing an interactive prompt share the one
  prompt slot (Keychain-stored creds reconnect cleanly).
- **Within-folder sidebar drag reorder** (deferred from M4): dropping onto a profile row inserts
  before it via `ConnectionLibrary.move(at:)`; folder rows keep move-into (unchanged).
- **Both flavors build** (Direct + AppStore). Tests: **334 kit (+17 `OrderedTabsTests`) + 14
  XCUITests (+3: tab open/switch/close, ⌘W-closes-tab-not-window, second-tab independence), all
  green.** **Approved & committed (c6942fb).**

## Current state of the code (M16 checkpoint A — done, committed ec114e2)

- **The Settings window is live** (screen 5; app menu / ⌘,) — a standard SwiftUI
  `Settings { }` scene with the five-tab strip General · Transfers · Keys · Terminal ·
  Advanced. M16 was split into **3 checkpoints** (approved 2026-07-19: A Settings · B Tabs ·
  C Polish); this is **A**. Full tabs (screen-1 tab strip) is checkpoint **B**; dark-mode
  audit + acknowledgements + help is **C**.
- **FerryCore `Settings/AppSettings`** (pure, unit-tested): centralizes the `UserDefaults`
  key strings (a persistence contract — the two terminal keys keep M15's exact strings),
  shipping defaults, and the typed enums (`AppearancePreference`, `InterruptedTransferPolicy`,
  `FileExistsPolicy`, `LoggingLevel`) + the pure `TransferNaming.deduplicatedName` (Rename
  preset).
- **Terminal tab** (approved mockup tab 7) rendered over M15's storage, now **reactive**
  (`@AppStorage`): the browser toolbar's Terminal control re-resolves its dispatch the moment
  the picker changes. Added built-in **font (family+size)** and **scrollback**, applied live.
  macOS 14 disables built-in ("Requires macOS 15"); APPSTORE hides the three external options.
- **Scrollback caveat retired (ADR-025).** ADR-023's "SwiftTerm discards scrollback on
  resize" note is outdated for the pinned 1.14.0 (`Terminal.resize` preserves
  `options.scrollback`; public `changeScrollback(_:)` exists). The bridge sets it on view
  creation and **re-asserts it in the existing `sizeChanged` hook** — Ferry owns the
  guarantee. Pinned by a bridge test (set → resize → still set).
- **Transfers tab** (ADR-026): `BrowserSession` reads `TransferSettingsSnapshot` — simultaneous
  transfers + retry count at connect, and the **exists** (Overwrite/Ask/Skip/**Rename**) and
  **interrupted** (Resume/Ask/Restart) policies at each staging call (apply-immediately). Ask
  interrupted prompts Resume/Start-Over. Queue-done `UNUserNotification`. Bandwidth + checksum
  ship **visible-but-disabled** (v1.x).
- **General / Keys / Advanced** (net-new UI, drawn into the mockups + signed off 2026-07-19,
  rule 3 → ADR-025): General — default local folder (feeds the local-pane start fallback),
  appearance Light/Dark/System (applied app-wide via **`NSApp.appearance`**, not
  `preferredColorScheme` — the latter at the WindowGroup root broke the launch XCUITest),
  reopen-last-connections (persisted on `connectionPhase` changes; restored from `onAppear`,
  skipped under `FERRY_DATA_DIR`). Keys — `~/.ssh` key list (read-only; empty in the sandbox),
  Generate/Import (Direct only, `ssh-keygen`/copy-in; disabled in APPSTORE), ssh-agent shown
  disabled (ADR-017), manage Ferry's known hosts (new `HostKeyStore.allTrustedHosts()`).
  Advanced — logging level over a small `FerryLog` (`os.Logger`, level-gated, never logs
  secrets/terminal bytes) + Reveal Logs (Console) + experimental flag.
- **Both flavors build** (Direct + AppStore). Tests: **317 kit (+14: AppSettings 11, HostKeyStore
  2, bridge scrollback 1) + 11 XCUITests, all green.** The Settings window itself isn't
  XCUITest-openable in this harness (the SwiftUI `Settings` scene doesn't route via ⌘,/menu
  under automation) — covered by a **TESTING.md manual checklist** (M15 precedent); the settings
  logic is unit-tested. **Approved & committed (ec114e2).**

## Current state of the code (M15 — done, committed d500ac3)

- **The external Terminal hand-off is live** (ADR-024) — the external branch of the
  ADR-023 dispatch, closing the "no fallback until M15" gap. The one Terminal toolbar
  control and the sidebar **Open Terminal** item now dispatch on the terminal-choice
  setting: built-in → the M15.5 panel/window; **Terminal.app / iTerm2 / custom command**
  → an ssh hand-off (Direct only).
- **Pure FerryCore `Terminal/TerminalLaunch.swift`** (all injection-critical, unit-tested):
  `SSHCommandBuilder` (host/`-p`/`-i`/`-t 'cd …; exec $SHELL -l'`; shlex-style quoting;
  tilde expansion via injected home; **never a password**, rule 6), AppleScript
  string-literal escaping, `TerminalDispatch.resolve` (built-in/external/unavailable across
  macOS 14/15 × Direct/App Store), and `TerminalPreference` (raw values pinned as a
  storage contract).
- **App target**: `ExternalTerminalLauncher` (`#if !APPSTORE`) launches Terminal.app/iTerm2
  via `NSAppleScript` (`do script` / `create window` + `write text`) and the custom command
  via `Process` → `/bin/zsh -lc "<launcher> <ssh command>"` (ssh command appended);
  `TerminalLaunchService` reads the `UserDefaults`-backed preference and applies the build's
  macOS-15/Direct-vs-App-Store capabilities. `ConnectionManagerModel.openTerminal` and
  `BrowserView`'s toolbar control both route through `terminalDispatch()`.
- **No credential resolution on the external path**: passwords are never passed; ssh
  authenticates and does its **own** host-key TOFU against `~/.ssh/known_hosts` (not Ferry's
  store) — documented in DOMAIN.md.
- **Setting is storage-only** (user decision 2026-07-19): the Settings ▸ Terminal picker is
  mocked (tab 7) but the Settings window is M16, so M15 persists the choice in `UserDefaults`
  (`terminalPreference` + `terminalCustomCommand`), changeable via `defaults write`. No new
  UI ⇒ no mockup deviation. Defaults per ADR-023 fall out of one static default (`builtIn`)
  applied by the resolver: built-in on macOS 15+, Terminal.app on macOS 14 Direct.
- **App Store safe** (rule 5): the launcher is entirely `#if !APPSTORE`; the resolver passes
  `externalAllowed=false` there, so every external preference degrades to built-in (or the
  macOS-15 explainer).
- Tests: **303 kit tests (+27: `TerminalLaunchTests`) + 11 XCUITests, all green.** Both
  flavors build (Direct + AppStore). App-launching isn't headless-testable — covered by a
  manual checklist in TESTING.md (the tested builders carry the injection logic). **Nothing
  committed — awaiting review.**

## Current state of the code (M15.5 — done; A+B committed d7971a8, C committed 6410384)

- **The embedded terminal is live in the app** (screen 7; A+B committed d7971a8).
  App target now links the **`FerryTerminalUI`** product (one pbxproj product-dependency
  edit — the hand-authored project's first since M1).
- **`TerminalController`** (@Observable, `@available(macOS 15)`): owns the
  `TerminalSession` + bridge (which owns the live SwiftTerm view — pop-out re-hosts the
  *same* emulator, buffer intact, pinned by a unit test), mirrors the state stream,
  start/restart/shutdown. `BrowserSession` carries it type-erased (`Any?` + gated
  accessor) because the class itself stays macOS 14.
- **Docked panel** in `BrowserView` below the panes (screen 7): header (`＞_ Terminal` ·
  endpoint mono · ● state · ⧉/⌄/✕), drag-resizable height (120–600), ended banner with
  Restart Session, ✕ confirms while the shell is live. Toolbar **Terminal toggle**
  (SSH profiles only, accent-filled while open; raises the window when popped out;
  macOS-14 explainer otherwise).
- **Pop-out & terminal-only windows**: new `WindowGroup(id: "terminal", for: UUID.self)`
  scene + `TerminalWindowView`; controllers registered on the model
  (`terminalWindowStorage`, type-erased; `pendingTerminalWindowID` hand-off because
  models can't call `openWindow`). Pop-out keeps the live shell; "⇤ Dock in Window"
  reverses; a popped-out window survives disconnect (`canRedock` flips off). Sidebar
  context menu gained **Open Terminal** (SSH profiles): resolves the credential through
  the SAME prompts as connect (`ConnectIntent` threaded through
  Password/KeyPassphrase/HostKey prompts), then **`TerminalSession.preflight`** (new
  public FerryCore API) validates TOFU + auth BEFORE the window opens.
- **Sequencing** (ADR-023 note): built-in is the only dispatch target until M15
  (external hand-off) and M16 (Settings picker + scrollback setting) land. Known
  deviation: closing a terminal *window* skips the live-shell confirm (no SwiftUI
  window-should-close hook); the panel ✕ confirms.
- **Build prerequisite**: SwiftTerm's Metal shader → one-time
  `xcodebuild -downloadComponent MetalToolchain` (BUILDING.md; installed 2026-07-18).
- Tests: **276 kit tests + 11 XCUITests, all green** (+3 preflight integration, +1
  bridge view-reuse, +1 UI e2e: open panel → `touch` in the real shell → row appears in
  the remote pane → `rm` → confirmed close). Both flavors build.

## Earlier state (M15.5 checkpoint B — superseded by C above)

- **The embedded terminal's engine + view bridge are built and green** (ADR-023;
  checkpoint A mockups approved 2026-07-18, screen 7 now binding).
- **`FerryCore/Terminal/TerminalSession`** (actor, `@available(macOS 15)` like SCP):
  dedicated SSH session via `SSHClientFactory` (TOFU + resolved credential, no
  re-prompt), Citadel `withPTY` driven from a nonisolated helper (Swift 6 region
  rules), `send`/`resize` (→ `window-change`) via the published `TTYStdinWriter`,
  one lifetime `output: AsyncStream<Data>` spanning restarts, observable state
  stream (idle/connecting/running/ended). End reasons come from the pure
  **`TerminalEndClassifier`** — out-of-band flags (user terminate, session drop)
  outrank whatever `withPTY` throws, because its cleanup `close()` masks errors
  with "Already closed" (the ADR-020 lesson). `onDisconnect` fails a live shell
  ("The SSH session dropped."); `terminate()` is bounded (3 s, TunnelEngine idiom).
- **New FerryKit product `FerryTerminalUI`** (keeps FerryCore UI-free): **SwiftTerm
  1.14.0** dependency (MIT — LICENSING.md moved it from Planned to live; its non-MIT
  deps attach only to targets Ferry doesn't link), `TerminalSessionBridge`
  (`@MainActor`; delegate keystrokes → `send`, `sizeChanged` → `resize`, output pump →
  `feed(byteArray:)`; `@preconcurrency TerminalViewDelegate` conformance), and
  `SSHTerminalView` (`NSViewRepresentable`, `configureNativeColors()` = theme-following,
  settable font). Scrollback-lines config deferred to checkpoint C (SwiftTerm recomputes
  options on resize — needs care).
- Tests: **272 kit tests, all green** — `TerminalSessionUnitTests` (11: classifier
  vectors + PTY request), `TerminalSessionBridgeTests` (6, new `FerryTerminalUITests`
  target, stub session), `TerminalSessionIntegrationTests` (8 against :2223: command
  round trip, resize verified by `stty size`, `exit`/`exit 1` clean, wrong password
  typed, bounded terminate, restart, :2222 forced-command never hangs). **No testinfra
  changes.** Both app flavors build (app doesn't link FerryTerminalUI until C).
- **Checkpoint C (todo)**: terminal panel + pop-out window + "Open Terminal" context
  menu + Settings dispatch per screen 7; XCUITest; scrollback setting.

## Current state of the code (M14.5 — done, committed a4899a2)

- **M14.5: Remote port forwarding works end-to-end** (ADR-022). The pinned Citadel 0.12.1
  turned out to ship a public client `tcpip-forward` API after all (via the Wellz26
  swift-nio-ssh fork it rides on — ADR-021's premise was outdated), so no vendoring was
  needed. `TunnelEngine.startRemote` runs Citadel's `withRemotePortForward` in a stored
  per-tunnel `Task` (cancel ⇒ protocol cancel request; `stop()` awaits it, bounded 3 s);
  each server-opened `forwarded-tcpip` channel gets the new `SSHChannelDataCodec`
  (Citadel's equivalent is internal) + a `GlueHandler` pair bridging to the local
  destination on the same single event loop. Fixed listen port required (Citadel routes
  inbound channels by the requested host/port). `SSHClient.onDisconnect` now fails remote
  tunnels immediately if the session drops (local/SOCKS keep their listeners). Editor's
  "not supported" warning removed; testinfra gained `GatewayPorts clientspecified` + a
  `127.0.0.1:2224 → :18080` mapping (rebuild: `docker compose up -d --build ssh`); new
  unit suites (codec, remote validation) + 3 remote integration tests, all green.
- **Port forwarding works end-to-end for Local + SOCKS** over the M11 SSH stack (Citadel;
  host-key TOFU + password/key auth via `SSHClientFactory`) — ADR-021. New FerryCore
  `Tunnel/` module: **`TunnelEngine`** (actor; observable status stream, start/stop/stopAll,
  auto-start), **`GlueHandler`** (canonical swift-nio bidirectional splice — backpressure via
  read-gating, half-closure, teardown), and **`SOCKSProxy`** (pure SOCKS5 parser +
  `SOCKSServerHandler` negotiator).
- **Local forward**: a loopback `ServerBootstrap` listener; each accepted connection opens a
  Citadel `direct-tcpip` channel to a fixed destination reachable from the server, spliced by a
  `GlueHandler` pair. **SOCKS**: same listener + a per-connection SOCKS5 (CONNECT, no-auth)
  handshake picks the target. **Not macOS-15-gated** — `direct-tcpip` needs no `withExec`
  (unlike SCP), so tunnels work on macOS 14.
- ~~Main technical risk (ADR-021): Remote deferred — no public Citadel API~~ **superseded by
  M14.5/ADR-022**: the pinned revision does expose it; Remote forwarding now runs for real.
- **Single event loop is the key design constraint**: the engine's SSH client, its `direct-tcpip`
  forwards, and the listener sockets all run on one **dedicated single-thread group** (new
  optional `group:` param on `SSHClientFactory.connect`), so a glue pair can touch both channel
  contexts directly. Glue **ordering** avoids dropping the server's opening bytes — the
  local-side glue is installed before the SSH channel is created; for SOCKS the SSH channel's
  reads are held until the success reply is sent, then both sides are primed.
- **Dedicated tunnel session** (not shared with the browser): `TunnelEngine` opens its own SSH
  session (identical trust/auth, reuses the resolved credential → no second prompt), lazily on
  first tunnel start. Decoupled lifecycle; a multiplexed `SSHSessionManager` is backlogged.
- **App**: `TunnelController` (@Observable) wraps the engine; `BrowserSession` holds one for
  SSH-based profiles (nil for FTP/FTPS) and auto-starts enabled tunnels on connect when the
  profile opts in. New **`TunnelManagerSheet`** (screen 4 table: Active toggle / Type pill /
  Listen / Destination / Status / Edit + "auto-start on connect" footer) and **`TunnelEditorSheet`**
  (add/edit form — new UI, ADR-021). A **Tunnels toolbar button** (SSH only) opens it; the
  status bar shows the **active-tunnel count**. `ConnectionManagerModel` persists tunnel edits.
- **Schema**: `TunnelConfiguration` (M2) unchanged. `ConnectionProfile` gained an **optional**
  `autoStartTunnels: Bool?` (nil ⇒ on) for the footer checkbox — backward-compatible, **no
  `connections.json` schemaVersion bump**.
- **Sandbox**: `com.apple.security.network.server` added to `Ferry-AppStore.entitlements`
  (per user sign-off) — Local/SOCKS listeners *accept* connections, which the sandbox gates on
  it. Both flavors build (Direct + AppStore).
- **Test infra**: no new container — the M13 exec server (`testinfra/ssh-exec`, :2223) already
  has `AllowTcpForwarding yes`.
- Tests: **240 kit tests + 10 XCUITests, all green** (+17 kit / +1 UI over M13) — SOCKS parser
  unit vectors; a tunnel op suite (local + SOCKS TCP round-trip reading the server's own sshd
  banner back through the tunnel, port-in-use, stop-releases-port, auto-start, remote-
  unsupported) against :2223; and a UI walk-through opening the manager and adding a tunnel.
  **M14 approved & committed (7938556).**

## Current state of the code (M13 — done, committed 6b1e981)

- **SCP works end-to-end** over an **SSH exec channel**, reusing the M11 SSH stack
  (Citadel; host-key TOFU + password/key auth) — ADR-020. New FerryCore `SCPSource`
  (actor, `FileSystemSource` + `SupervisedConnection`) slots into the generalized
  `BrowserSession` exactly like `FTPSource` did (M12).
- **Split surface** (the core mapping problem — the scp wire protocol carries only bytes):
  **metadata runs POSIX commands over exec** (`pwd`/`ls -la`/`ls -ld`/`mkdir -p`/`rm -rf`/
  `mv`/`chmod`, all paths single-quoted + `--` against injection; `ls` parsed by the shared
  Unix `ls -l` parser reused from FTP), and **bytes stream over the classic scp protocol**
  (`scp -f` download, `scp -t` upload) driven through Citadel's bidirectional `withExec`.
- **Capability compromises vs SFTP** (documented in DOMAIN.md → SCP): **no transfer resume**
  — a resumed download re-reads from the start but the stream still begins at `offset`
  (byte-exact, no bandwidth saving); a resumed upload is rejected (offset > 0 →
  `.invalidOffset`, so the engine restarts). Upload **buffers to a local temp file** (scp
  needs the size up front) and **stages to a remote `.ferry-scp-part` renamed into place on
  success**, so an interrupted upload never poisons the engine's resume. A server that
  forbids exec (SFTP-only) is detected at connect with a clear message.
- **withExec error masking** handled: Citadel's `withExec` cleanup (`channel.close()`) throws
  "Already closed" once the remote scp has exited, masking a thrown error — so neither
  protocol driver throws through it. The download driver reports via the stream continuation;
  the upload driver via an out-of-band `UploadOutcome` (explicit `completed` flag so a clean
  close after success isn't read as failure). Errors are classified from scp `\x01`/`\x02`
  status messages and drained `stderr`.
- **Shared SSH connect**: host-key TOFU + auth + error-classification extracted from
  `SFTPSource` into **`SSHClientFactory`** (+ shared `SSHConnectionParameters`), now used by
  both SFTP and SCP — one audited home for the security-critical trust decision.
- **macOS 15+ gate** (user decision 2026-07-18, ADR-020): SCP needs `withExec`
  (`@available(macOS 15)`) and Citadel exposes no macOS-14 path, so `SCPSource` is
  `@available(macOS 15)` and the app blocks an SCP connect on macOS 14 with a clear message.
  **SFTP/FTP/FTPS are unaffected**; the app stays macOS 14. Metadata commands are
  macOS-14-capable — only byte transfers force the gate.
- **App**: `ConnectionManagerModel.connect` no longer info-alerts `.scp` — it runs the real
  SCP path (`startSCPConnection`, same host-key TOFU + password/key credential resolution as
  SFTP). The editor already offered SCP (SSH auth, port 22), so **no UI changes** — rule 3
  satisfied without a mockup deviation. Both flavors build (Direct + AppStore).
- **Test infra**: the milestone brief's assumption (test SCP against atmoz/sftp) was wrong —
  atmoz forces `internal-sftp` (blocks exec) **and has no scp binary**. Added a purpose-built
  exec-capable OpenSSH container (`testinfra/ssh-exec`, :2223) with the same creds + client
  key; `start.sh` now `--build`s it. **Re-run `testinfra/start.sh` after pulling M13.**
- Tests: **223 kit tests + 9 XCUITests, all green** (+35 kit / +1 UI over M12) — SCP shell-
  quote/error-mapping unit vectors; a full SCP op suite (list/stat/home/byte-exact 1 MiB
  download/600 KB round-trip/offset-skip/mkdir/delete/rename/chmod/wrong-password/missing/
  exec-blocked-server) + engine round-trip, 5-way concurrent uploads, and folder upload
  against :2223; and a UI e2e connecting via SCP and downloading through the queue.
- Self-review applied: removed a dead `import NIOSSH` from `SFTPSource` after the factory
  extraction. **M13 approved & committed (6b1e981).**

## Current state of the code (M12 — done, committed 7223169)

- **FTP and FTPS work end-to-end** over the **system libcurl** — nothing bundled (ADR-019).
  New FerryCore `FTPSource` (actor, `FileSystemSource` + `SupervisedConnection`) covers the
  full surface: home (`PWD`), list (Unix `LIST` → `FTPListParser`), stat (parent-listing
  match), chunked offset download (`REST`), sequential upload with resume (`APPE`),
  mkdir+intermediates (`MKD`), recursive delete (`DELE`/`RMD`), rename refuse-clobber
  (`RNFR`/`RNTO`), chmod (`SITE CHMOD`), ping/reestablish.
- **libcurl binding** via a tiny C target **`CFTP`** that exposes libcurl's *variadic*
  `setopt`/`getinfo` as typed functions (Swift can't call C variadics) + callback setters.
  `FTPSource` runs every blocking `curl_easy_perform` on a **detached thread** (the actor's
  executor is never blocked); C write/read/header callbacks are `@convention(c)` closures
  bridging via `Unmanaged` context. **No persistent session** — each op drives its own easy
  handle (own control+data connection), so concurrent transfers are trivially correct.
- **FTPS**: explicit `AUTH TLS` (`CURLUSESSL_ALL`) and implicit (`ftps://`). The app derives
  the mode from scheme+port (`.ftps` on 990 = implicit, else explicit). Certificates verify
  against the system trust store by default; a **cert-trust prompt** for self-signed/private-
  CA servers is deferred to the backlog (clear `.tlsFailed` error for now) — mirrors the M11
  ssh-agent split. `allowInvalidCertificate` exists in FerryCore for the test server only.
- **App**: `BrowserSession` generalized from concrete `SFTPSource` to
  `any FileSystemSource & SupervisedConnection` (which gained `disconnect()`); both backends
  conform, SCP will slot in the same way. `ConnectionManagerModel.connect` builds an
  `FTPSource` for `.ftp`/`.ftps` (password auth, prompt when none, TLS/auth error messages);
  the editor already offered FTP/FTPS + password-only auth. Both flavors build (Direct +
  App Store — libcurl is a system dylib, sandbox-safe).
- **Test infra**: a **second** vsftpd service (`ftps`, :2990, self-signed cert) added —
  a TLS vsftpd forces SSL so it can't also serve the plaintext `ftp` (:2121). Its config
  sets `require_ssl_reuse=NO` (TLS 1.3 / SecureTransport can't resume the data channel).
  **Re-run `testinfra/start.sh` after pulling** to generate the cert + start the container.
- Tests: **188 kit tests + 8 XCUITests, all green** (+33 kit / +1 UI over M11) — LIST-parser
  unit vectors; a full FTP op suite + engine round-trip + 5-way concurrent uploads against
  the Docker FTP server; explicit-FTPS connect/list/download/upload/round-trip over TLS; and
  a UI e2e that connects to the FTP server and downloads through the queue.
- Self-review applied 4 fixes (dead-connection low-speed timeout, upload read-callback
  zero-length guard, CR/LF control-channel-injection rejection in quote commands, per-chunk
  thread churn → serial queue). Cert-trust prompt deferred to backlog (user sign-off
  2026-07-18). **M12 approved & committed (7223169).**

## Earlier state (M11 — done, committed a008639)

- **`~/.ssh/known_hosts` is now read as pre-trust** (ADR-018). New read-only FerryCore
  `KnownHostsFile` parses plaintext **and** hashed (HMAC-SHA1) entries; `SFTPSource.connect`
  takes an optional `systemKnownHosts` and unions its keys into both the TOFU validator's
  trusted set and the changed-vs-unknown decision — so a host the user already knows skips
  the prompt, while a system-known host offering a *different* key still raises the
  changed-key alarm. `HostKeyStore`'s "Ferry writes only its own plaintext file" invariant
  is untouched (the reader is a separate type). Frozen at connect so auto-reconnect
  re-validates identically; the app re-reads at each connect (`FERRY_SYSTEM_KNOWN_HOSTS`
  override for tests).
- **`~/.ssh/config` Import…** (ADR-018). New FerryCore `SSHConfigParser` lifts concrete
  `Host` blocks into SFTP profiles (`HostName`/alias, `Port`, `User`, `IdentityFile`→
  public-key, tilde-expanded); wildcard/negated patterns and `Match`/`ProxyJump` are
  skipped/ignored. App: **File ▸ Import from SSH Config…** (⌘⇧I) — the canonical entry —
  plus a sidebar-toolbar Import menu, both opening `SSHImportSheet` (a checklist). Chosen
  hosts land under a new "Imported" folder; no secrets are read from the config. UI signed
  off (not in mockups, rule 3 → ADR-018). `FERRY_SSH_CONFIG` override for tests.
- **Sandbox**: both features read `~/.ssh` freely in the Direct build and **degrade
  gracefully to empty** in the App Store build (container home has no `~/.ssh`) — pre-trust
  simply doesn't apply, import reports nothing found. Bookmark-store routing deferred to M17.
- Both flavors build (Direct + AppStore). Tests: **155 kit tests + 7 XCUITests, all green**
  (+20 kit / +1 UI over checkpoint A) — incl. hashed-known_hosts vectors vs `ssh-keygen -H`,
  ssh_config field mapping + wildcard/`Match` skipping, a real-server pre-trust connect (no
  TOFU prompt) + conflicting-key CHANGED detection, and a UI walk-through of the config
  import.
- **M11 is complete** — approved & committed (a008639).

## Earlier state (M11 checkpoint A — committed ffd7233)

- **The `acceptAnything()` host-key placeholder is gone** — the shipping blocker flagged
  since M6 is closed. `SFTPSource.connect` now takes an `SSHAuthCredential` (password or
  private key) + a `HostKeyStore`, verifies the host key TOFU, and throws
  `hostKeyUnknown`/`hostKeyChanged` for the app to resolve (ADR-016). A `sessionTrusted`
  key supports "trust for this session only" (remember off) and survives auto-reconnect.
- **New FerryCore `SSH/` module**: `HostKeyInfo` (algorithm + OpenSSH SHA256 fingerprint +
  storage line, via swift-crypto — now a direct dependency), `HostKeyStore` (plaintext
  known_hosts persister, FERRY_DATA_DIR-aware), `TOFUHostKeyValidator` (rejects untrusted
  keys mid-handshake and captures the offered one), `SSHKeyLoader` (OpenSSH ed25519/RSA
  keys, encrypted or not; ECDSA + legacy PEM rejected with clear errors — ADR-017).
- **App**: `ConnectionManagerModel` drives the whole flow — key-file read + passphrase
  (Keychain `keyPassphrase`, prompt on encrypted/missing/wrong), catches host-key errors,
  and presents screen 3. New views: `HostKeyPromptSheet` (TOFU 🔑 + changed-key ⚠️ alarm
  with second-confirmation Replace) and a key-passphrase prompt. ssh-agent now reports
  "planned for a later release" instead of "M11".
- **testinfra**: `start.sh` generates a client keypair (gitignored) mounted for pubkey
  auth; `sftp.d/00-relax-sshd.sh` sets `PerSourcePenalties no` so TOFU-rejection handshakes
  don't wedge the source IP (ADR-016). **Re-run `testinfra/start.sh` after pulling.**
- Tests: **135 kit tests + 6 XCUITests, all green** (+21 kit, +1 UI over M10) — incl.
  fingerprint vectors vs `ssh-keygen`, HostKeyStore round-trip, key-loader passphrase
  branches, real ed25519 key login, TOFU unknown→trust→reconnect, session-only trust,
  changed-key detection, and a UI walk-through of the TOFU sheet.
- **Still todo in M11 (checkpoint B)**: read `~/.ssh/known_hosts` (plaintext + hashed) as
  pre-trust, and the sidebar `~/.ssh/config` Import….

## Earlier state (after M10)

- **The file-operation surface is complete.** `SFTPSource` gained `rename` (refuses to
  clobber an existing destination → `.alreadyExists`, matching LocalFileSource) and
  `setPermissions` (SETSTAT) — the FileSystemSource mutation contract is now fully live on
  both backends (ADR-015).
- App: each pane row has a context menu (Quick Look · Upload/Download · Rename… ·
  Permissions… · Delete…). Rename is an inline alert; Delete confirms with a recursive
  folder warning and states items are removed on this Mac / on the server (no Trash over
  SFTP). Operations live on `PaneModel` (rename/delete/applyPermissions/previewURL) and
  reload the pane; multi-select delete continues past a per-item failure.
- **Quick Look**: local files preview in place (`.quickLookPreview`); remote files stream
  to a temp file then preview (double-click a file previews, folders navigate).
- **chmod editor** (`PermissionsEditorSheet`): 3×3 rwx grid synced to an editable octal
  field; available on both panes.
- **Finder drag & drop**: local items now vend a file `URL` (drag to Finder + drop onto
  the remote pane = upload); remote items keep the string payload (drop onto local =
  download); Finder files dropped onto a pane enqueue a transfer (upload/copy). Each pane
  carries a `String` and a `URL` drop destination. Remote→Finder promise drag is
  backlogged (ADR-015).
- Tests: 114 kit tests + 5 XCUITests, all green — incl. SFTP rename (move, refuse-clobber,
  missing-source) + chmod round-trip against Docker sshd, and a UI rename+delete walk-
  through via the row context menu.

## Earlier state (after M9)

- **Transfers are robust.** `TransferEngine` (ADR-014): downloads stage into
  `<name>.ferrypart` and atomically rename on completion; valid partials resume
  (stale > 30 days or oversized ⇒ discarded — that's the GC); uploads resume from a
  smaller remote size. Transient failures retry 3× / 5 s resuming their own partial;
  deterministic errors fail immediately. `pause`/`resume` (paused snapshots frozen
  against zombie updates, ADR-013 discipline). Folder transfers expand lazily at the
  queue front (SFTP `createDirectory` with intermediates pulled forward from M10).
- **Connections self-heal.** `ConnectionSupervisor` actor: keep-alive ping every 30 s +
  auto-reconnect with backoff (1/2/4 s, 3 attempts) over `SupervisedConnection`;
  `SFTPSource.reestablish()` rebuilds the transport in place. Wired when the profile's
  keep-alive flag is on; a transfer exhausting retries kicks `noteFailure()`.
- App: queue rows gained pause/resume buttons + RESUMED/PAUSED badges (UPLOADING/
  DOWNLOADING replace TRANSFERRING per mockup); per-file conflict alert with
  Replace/Replace All/Skip/Skip All; folders now stage for real (skip notice removed);
  status bar shows Reconnecting (amber) / Connection lost + Reconnect (red); panes
  reload after recovery.
- Tests: 112 kit tests + 4 XCUITests, all green — incl. the kill-mid-transfer suite
  (server-side session kill, 32 MiB dd-seeded file, md5-verified resume) and supervisor
  reconnect against the real Docker sshd. Test-infra learnings recorded in ADR-014.

## Earlier state (after M8)

- **Transfers work end-to-end.** `TransferEngine` (FerryCore actor): FIFO queue,
  3-concurrent cap per connection, snapshot stream with replay, robust cancellation
  (ADR-013 — publishes cancelled + frees slot immediately, force-closes the write handle).
  `SFTPSource` gained `openWrite` (incl. truncate-to-offset resume contract) and
  recursive `delete`.
- App: `TransferQueueModel` (speed EMA + ETA) + `TransferQueueView` dock per mockup
  (progress, badges, cancel, clear, collapse). Upload/Download toolbar buttons act on
  selections; drag between panes (handle = file icon); per-batch Replace/Cancel conflict
  dialog; folders skipped with notice (M9); destination pane auto-refreshes on completion.
- M8 war stories (see ADR-013): Docker root-owned mountpoint made the SFTP upload dir
  unwritable (fixtures moved to `/fixtures`); AsyncStream bufferingNewest dropped chunks;
  whole-row `.draggable` broke double-click navigation; a happy-path-only test loop hid
  the failure as a hang.
- Tests: 84 kit tests + 4 XCUITests, all green — incl. the e2e UI flow that connects,
  browses, downloads through the queue, and verifies the file on disk.

## Earlier state (after M7)

- **Ferry now connects and browses for real.** Detail column switches on
  `ConnectionPhase`: profile summary → connecting spinner → `BrowserView` (dual panes,
  toolbar, status bar). Connect via double-click or button; password from Keychain or a
  prompt sheet with remember opt-in; typed errors for auth vs unreachable.
- `BrowserSession` + `PaneModel` (ADR-012): symmetric panes over FileSystemSources —
  sortable Table (dirs first; Name/Size/Modified/Kind-or-Perms/Owner), clickable
  breadcrumbs, per-pane hidden toggle + error alerts, back/forward history, double-click
  navigation, New Folder (works local; remote reports unsupported until M10), Refresh,
  toolbar filter on the active pane, Disconnect. **Sync browsing** per DESIGN.md: linked
  toggle, anchor mirroring (PathUtilities, unit-tested), flash-and-stay on missing
  counterpart.
- Upload/Download buttons present but inform "M8"; queue dock, tabs, Quick Look pending
  (see DESIGN.md → Implementation status).
- Tests: 73 in FerryKit + 4 XCUITests, all green — incl. the M7 e2e walk-through
  (create → connect via password prompt → browse the Docker server → disconnect).

## Earlier state (after M6)

- **Citadel 0.12.1 adopted as the SSH stack** (ADR-011) — spike succeeded; first
  third-party dependency, licenses recorded in LICENSING.md before adding.
- `FerryCore/FileSystem/SFTPSource`: actor conforming to FileSystemSource. Read side
  complete: connect (password auth; typed RemoteSourceError), homeDirectory (realpath),
  list with attributes + owner/group from longname, stat, chunked offset openRead
  (128 KiB, EOF = empty buffer). Mutations/openWrite throw `.unsupported(operation:)`
  until M8/M10. Host keys: acceptAnything with TODO(M11) — must not ship past M11.
- Error normalization: raw `SFTPMessage.Status` AND `SFTPError.errorStatus` both map to
  typed FileSystemSourceError (noSuchFile→notFound, permissionDenied→permissionDenied).
- Tests: 69 total, all green (10 SFTP integration tests against the Docker server incl.
  wrong-password auth failure and byte-exact 1 MiB multi-chunk download).

## Earlier state (after M5)

- `FerryCore/FileSystem/`: `FileSystemSource` protocol (the core abstraction, ARCHITECTURE.md
  updated with the exact shape incl. the offset-based resume contract), `FileItem` +
  `FilePermissions` (octal/symbolic), `FileWriteHandle`, typed `FileSystemSourceError`.
- `LocalFileSource`: full conformance over FileManager/FileHandle — listing with hidden
  filter + owner/perms metadata, stat with symlink detection, mkdir (intermediates),
  recursive delete, rename (refuses overwrite), chmod, chunked streaming read (256 KB,
  offset-aware), sequential write handle honoring truncate-to-offset-then-append.
- `SecurityScopedBookmarkStore`: persisted folder grants, deepest-match resolution,
  stale-bookmark refresh, pass-through without grants; composed into LocalFileSource
  (one code path for Direct and App Store builds).
- Tests: 59 total, all green (new: 4 unit FilePermissions; 11 LocalFileSource + 4 bookmark
  integration tests on the real filesystem).

## Earlier state (after M4)

- App UI (per DESIGN.md screens 1–2): `MainWindow` (NavigationSplitView),
  `SidebarView` (folder tree with disclosure state persisted, protocol badges, context
  menus incl. Move-to, drag onto folders / "Connections" header, delete confirmations
  that mention Keychain cleanup, "This Mac" stub section), `ConnectionEditorSheet`
  (protocol-adaptive form, password/key/agent auth with Keychain hint, Advanced group,
  live Test Connection via TCP probe), `DetailPlaceholderView` (summary + stubbed Connect).
- `ConnectionManagerModel` (@Observable, main-actor): persists every mutation, mediates
  vault (secrets follow auth-method changes; duplicate copies secrets; delete cleans up,
  including nested profiles when deleting a folder). Test isolation via FERRY_DATA_DIR /
  FERRY_KEYCHAIN_SERVICE env vars.
- FerryCore additions: `parentFolderID(ofItem:)`, `allFolders`, `ReachabilityProbe` (TCP).
- Known scope notes: within-folder index reordering by drag is deferred to M16 (drop-on-
  folder + Move-to menu work now); Test Connection is TCP reachability until M6's real
  protocol handshake; "This Mac" items are non-functional until M5/M7.
- Tests: 40 in FerryKit (all green) + 3 XCUITests (all green, isolated store).

## Earlier state (after M3)

- `FerryCore/Store/CredentialVault`: Keychain wrapper — roles `password`/`keyPassphrase`
  per profile UUID, upsert store, nil-on-absent retrieve, idempotent delete, `deleteAll`
  for profile removal. Login keychain, WhenUnlocked accessibility (ADR-010).
- Tests: 35 total, all green (unit: account-format contract; integration: 8 real-Keychain
  tests with self-cleaning test service).

## Earlier state (after M2)

- `FerryCore/Models`: `ConnectionProfile` (no secrets; port defaults per protocol),
  `TransferProtocol` (sftp/ftp/ftps/scp), `AuthenticationMethod` (password/publicKey/agent),
  `TunnelConfiguration` (schema fixed early for M14), `ProfileFolder` + `SidebarItem`
  (recursive tree, clean JSON discriminator), `ConnectionLibrary` (queries + add/remove/
  update/rename/move with cycle protection).
- `FerryCore/Store/ConnectionStore`: stateless JSON persister — atomic writes, intermediate
  dirs, ISO8601 dates, sortedKeys stability, schemaVersion probe with precise
  newer-version error (ADR-009). Default path: `~/Library/Application Support/Ferry/connections.json`.
- Tests: 24 total (16 unit + 8 integration incl. 6 real-filesystem persistence tests), all green.

## Earlier state (after M1)

- Xcode project `Ferry.xcodeproj` (hand-authored, objectVersion 77) with app target `Ferry` + `FerryUITests`; 4 build configurations (Debug/Release × Direct/AppStore) and 2 shared schemes (`Ferry-Direct`, `Ferry-AppStore`). Builds clean.
- `FerryKit` local SwiftPM package holds all future core logic. Currently: `FerryVersion` placeholder + 1 unit test + 2 integration smoke tests (SSH banner / FTP greeting) — all passing.
- Docker test infra (`testinfra/`): SFTP on 127.0.0.1:2222, FTP on 2121 (`ferry`/`ferrypass`), seeded fixtures; `start.sh`/`stop.sh` verified working.
- App shows a branded placeholder window; approved icon (concept A) generated into the asset catalog by `tools/generate-appicon.swift`.
- All docs written (see CLAUDE.md doc map). Nothing committed yet — first commit happens on M1 approval.

## Known issues / open items

- Bundle id `com.gfragos.Ferry` and ad-hoc signing are placeholders until the user has an Apple Developer account (BUILDING.md).
- **Ad-hoc signing makes saved Keychain secrets unusable in local builds**: macOS re-shows its
  authorization panel on every access and "Always Allow" cannot stick, because an ad-hoc
  signature has no stable code identity. Leave "Remember in my Keychain" unticked while
  developing, or set an Apple Development identity (BUILDING.md → Keychain prompts, ADR-034).
- Trademark/domain check for the name "Ferry" is the user's task before sale.

## Next steps

1. **M21 checkpoint C**: real engine-backed promise replacing the
   `useStubPromise = true` stub in `RemoteDragBridge`, `DragOutDownloadTests` integration
   suite, ADR-038 + the deferred doc updates (DOMAIN, DESIGN, ARCHITECTURE, ROADMAP), and the
   re-run manual Finder matrix in both flavors. **M17/M18 (packaging, sale readiness) remain
   deferred but required before sale.**
2. Backlog: multiplexed `SSHSessionManager` (ADR-021/022); FTP connection pooling
   (`CURLSH`) to avoid a login per op; per-file `MDTM` for precise FTP mtimes; route `~/.ssh`
   reads through the bookmark store for the App Store sandbox (M17, ADR-018).

## Session log

- **2026-08-15** — **M21 checkpoint B: groups/plan/policy in FerryCore (built, awaiting
  review)**. Implemented the checkpoint exactly per the approved plan: `groupID` threaded
  through `TransferRequest`/`TransferSnapshot`/`performDirectory` (defaulted — no call-site
  churn), new `TransferGroupTracker` actor (per-group `AsyncStream`: progress / stalled /
  finished with failed ▸ cancelled ▸ completed precedence, plus the three guards — seeded
  root, explicit paused, frozen conclusion — and cancel-on-sight for members that surface
  after `cancelGroup`), and `DragOutPlan`/`DragOutPolicy` (always `.restart`;
  litter/cleanUp with the never-delete-a-pre-existing-directory rule; Finder selection
  semantics). +17 unit tests (tracker 13 incl. the capture-at-`.finished` invariant on a
  nested tree, DragOut 4); `InMemoryFileSource` gained `listFailuresRemaining`. **446 kit
  tests green** against live Docker servers; both flavors build. TESTING.md + PROGRESS.md
  updated; remaining docs are checkpoint C's. XCUITests 21/22 — the one failure is the
  documented embedded-terminal under-load flake (passed solo). User ran the Direct build by
  hand and approved. **Committed (1420349).**
- **2026-08-14** — **M21 checkpoint A: remote→Finder drag-out spike (continued + closed)**.
  Reviewed the uncommitted checkpoint-A tree before deciding next steps; found and fixed a
  cancelled-drag promise-delegate leak and a ⌘/⇧-click selection regression on the new icon
  handle. Then resolved the count-badge question by measurement (user decision: try the
  declared-UTI fix, fall back to accepting the badge): declared `com.gfragos.ferry.drag-item`
  via a new merged `Ferry/Info.plist` (first pbxproj `INFOPLIST_FILE` wiring); learned the badge
  counts *dragging items* regardless of type (a non-consumable declared type still badged 2);
  final working shape is one dragging item (the promise) + the payload appended directly to the
  drag pasteboard — badge truthful, no text-paste leak, M8 pane-drop gate green. User ran the
  full manual Finder matrix in both flavors — all pass, including the folder-drag re-verify and
  sandbox. Full suite re-verified twice (429 kit + 22 XCUITests; the embedded-terminal flake
  failed under full-suite load and passed every solo re-run, as documented). Mid-session macOS
  TCC revoked Terminal's Documents access ("Operation not permitted" on every repo path) —
  restored via `tccutil reset SystemPolicyDocumentsFolder com.apple.Terminal` + re-allow.
  **Awaiting review; nothing committed.** Untracked `default.profraw` at the repo root is test
  junk — delete or gitignore before committing.
- **2026-08-02 (cont. 2)** — **Terminal windows are never restored (ADR-037)**. Closed the item
  ADR-036 left open: macOS restored popped-out terminal windows after an abnormal termination, so a
  relaunch showed empty "This terminal session has ended" windows. Opted the scene out with
  `restorationBehavior(.disabled)` (macOS-15-only scene — every opener is already gated), and made
  `TerminalWindowView` dismiss itself when its controller id no longer resolves. Pop-out/re-dock
  re-verified by hand + the ADR-035 tests; 429 kit + 19 XCUITests green. Honest caveat recorded in
  the ADR: after the saved state cleared, the restoration couldn't be re-triggered on demand, so
  there is no live before/after and no regression test (XCUITest can't drive OS restoration).
- **2026-08-02 (cont.)** — **Sidebar hidden at launch (ADR-036)**. Chased the four XCUITests that
  were failing on a clean tree. Root cause: `NavigationSplitView` with `.automatic` visibility
  opened with the sidebar hidden, so Ferry launched with its connection manager off screen — the
  give-away was a system "Show Sidebar" button in the toolbar and a split view reporting one
  full-width column. Not stale prefs (clearing the defaults domain changed nothing; reproduces at
  `ec114e2`). Bound an explicit `columnVisibility = .all`. Also isolated **window state** in UI
  tests (`-ApplePersistenceIgnoreState YES`) — macOS was restoring dead popped-out terminal windows
  into later tests' `app.windows`. All four tests pass again; **429 kit + 19 XCUITests green**.
  Left open (ADR-036): a normal relaunch still restores dead terminal windows.
- **2026-08-02** — **Per-tab terminal identity (ADR-035)**. Chased a user report that the first
  tab's embedded terminal followed into the second tab. Verified the models are per-tab and the
  fault is SwiftUI view identity: `BrowserView` has one identity across all tabs, so
  `SSHTerminalView` (the only `NSViewRepresentable`) never re-ran `makeNSView` on a tab switch and
  kept hosting the first tab's live emulator — wrong screen *and* keystrokes on the wrong server.
  Detaching a terminal sidesteps it (own scene); re-docking from another tab is the worst case
  (the returning shell is stranded). Fixed with `.id(controller.id)` on the emulator +
  `.id(terminal.id)` on the docked panel, plus a debug assert in `updateNSView`; moved
  `BrowserView`'s cross-tab `@State` (staged conflicts/resume decisions, New Folder, tunnel sheet)
  onto `BrowserSession`, which also closes a wrong-server transfer window. +1 kit test, +2
  XCUITests, both confirmed red before the fix. **Found in passing, not fixed:** four XCUITests
  fail on a clean tree too — the sidebar ("Connections") and both Help windows don't show up under
  automation, and the SSH-config import test fails; the sidebar is also missing when driving the
  built app by hand. Needs its own session.
- **2026-07-25** — **Toolbar tooltips + Keychain main-actor freeze (ADR-034)**. (1) Every
  icon-only control now has a `.help()`: the browser toolbar was missing Back, Forward, Upload,
  Download, New Folder, Refresh and the Filter field; the transfer-queue header was missing its
  collapse chevron and Clear. (2) Diagnosed a report of "stuck in the Keychain password dialog,
  then the app crashed": it never crashed (clean ⌘Q `terminate:` in the log, no crash report) —
  `resolveCredential` read the Keychain **synchronously on the main actor**, so the macOS
  authorization panel froze the UI for as long as it was on screen. `CredentialVault` gained
  `retrieveAsync`/`storeAsync`/`deleteAllAsync` (detached hop) and every UI call site moved to
  them (`resolveCredential`, `connectWithKey`, `saveDraft`, `deleteItem`, `duplicateProfile`,
  remember-on-connect, `ProfileDraft.fromExisting`). `errSecUserCanceled` is now its own error
  case: a denied panel aborts the connect with an explanation instead of silently re-showing
  Ferry's password sheet as if the secret were missing. The panel loop itself is an **ad-hoc
  signing** artifact (no stable code identity ⇒ no durable ACL entry ⇒ "Always Allow" cannot
  stick) — documented in BUILDING.md; the user's two stale items were deleted to unblock.
  (3) Fixed a **stale UI test**: `testImportFromSSHConfigAddsProfiles` still looked for a
  top-level "Import from SSH Config…" menu item, which M20 checkpoint A (ea43d51) had moved
  into the **Import Connections** submenu — red since 2026-07-20, unrelated to this session's
  changes. 428 kit + 17 UI tests green (+4 kit). Both flavors build.

- **2026-07-23 (b)** — **CRLF hardening + integration-test crash fix** (follow-ups from the
  WinSCP session, user-approved). (1) The same LF-only split fixed in `SSHConfigParser`,
  `KnownHostsFile`, `HostKeyStore`, and `SSHKeyLoader` (Windows-copied config/known_hosts/key
  would parse as one line); `SSHKeyLoader` additionally normalizes CRLF→LF before handing the
  PEM to Citadel, whose OpenSSH boundary check is LF-only (`invalidOpenSSHBoundary`). CRLF
  regression tests added to all four suites. (2) Four integration-test tearDowns
  (`EditorRoundTrip`/`SFTPRobustness`/`SFTPTransfer`/`FTPTransfer`) force-unwrapped `localDir`,
  which is still nil when setUp skips because the server is down — the IUO unwrap killed the
  whole xctest process (signal 5) instead of skipping; now `if let`-guarded (the pattern
  `SCPTransferTests` already used). Verified both ways: servers down → 422 tests, 103 skipped,
  0 failures, no crash; servers up → all pass.
- **2026-07-23** — **WinSCP import CRLF fix** (bug found by the user against a real export).
  `WinSCPImporter.parse` split on the literal `"\n"`, but Swift folds `"\r\n"` into a *single*
  `Character` — so a real (always-CRLF, Windows-written) `WinSCP.ini` was one giant "line",
  no `[Sessions\…]` header matched, and the import reported nothing found. Now splits with
  `whereSeparator: \.isNewline`; regression test `testParsesCRLFLineEndings` added (existing
  fixtures were all LF, which is why the suite never caught it). Verified against the user's
  real 97-section export: 49 connections parse, hierarchy intact. Same LF-only split exists in
  `SSHConfigParser`/`KnownHostsFile`/`HostKeyStore`/`SSHKeyLoader` (latent — macOS-origin files
  are LF; a Windows-copied key/config would hit it) — flagged, not yet changed.

- **2026-07-19 (f)** — **Post-v1 roadmap planned** (ADR-029). M17/M18 deferred by user
  decision (still required before sale). The rough backlog became five release-themed phases
  in ROADMAP.md: **G v1.1 Workflow** (M19 editor round-trip · M20 importers/export + FTPS
  cert trust · M21 pane power pack) · **H v1.2 Pro SSH** (M22 multiplexed `SSHSessionManager`
  · M23 ProxyJump/ssh-agent/ECDSA · M24 activity log + Touch ID lock) · **I v1.3 Sync**
  (M25 engine upgrades incl. capability flags · M26 mirror + dry-run) · **J v1.4 Breadth**
  (M27 WebDAV · M28 S3 · M29 remote↔remote) · **K v1.5 Reach** (M30 automation · M31
  localization + help). Eight Claude-suggested features accepted into scope. Next: M19.
- **2026-07-19 (e)** — **Tab-strip layout fix** (ADR-027 addendum). The checkpoint-B strip
  rendered mid-window: its horizontal `ScrollView` greedily split the detail column's height with
  the detail view, centering the chips vertically. `TabStripView` now takes
  `.fixedSize(horizontal: false, vertical: true)` and moved out of the detail column to sit
  **above** the `NavigationSplitView` — a thin full-width bar under the title bar, matching the
  mockup's `.wintabs` (DESIGN.md screen 1: title bar → tabs → sidebar | detail).
- **2026-07-19 (d)** — M16 **checkpoint C built** (Polish, ADR-028) — the final M16 checkpoint.
  Early decisions signed off: Acknowledgements + Help live as **Help-menu standalone windows**
  (not Settings tabs — chosen for XCUITest-drivability, ADR-025); the guide is a **static SwiftUI
  window**; **one ADR-028** covers both. Built: FerryCore `Help/` (pure `HelpContent` +
  `Acknowledgements` models, mirroring LICENSING.md) rendered by `HelpGuideWindowView` /
  `AcknowledgementsWindowView`; `FerryApp` gains two `Window` scenes + `HelpMenuCommands`
  (`CommandGroup(replacing: .help)` reading `openWindow`). **Dark-mode audit found no code
  changes needed** — the UI already uses semantic/adaptive colors and the one fixed color (SOCKS
  pill `#7a5fd0`) matches the mockup CSS (pinned both themes); appearance stays via
  `NSApp.appearance`. **Error-voice pass**: apostrophes → curly `’` across user-facing strings
  (shell-quoting literals in `TerminalLaunch.swift` left alone), `Couldn’t` → `Could not`.
  **XCUITest lesson (ADR-028)**: "Ferry Help" the menu item collides with the window title →
  scope the query to `menuBarItems["Help"].menuItems["Ferry Help"]` (a global `.firstMatch`
  resolves to an off-screen INFINITY-point element). 341 kit (+7 `HelpContentTests`) + 16 UI
  (+2 Help/Acknowledgements windows) green; both flavors build; app confirmed to launch in dark
  mode (headless screenshots blocked by TCC → manual visual checklist in TESTING.md). Docs
  updated (DESIGN/DECISIONS ADR-028/LICENSING/TESTING/ROADMAP/ARCHITECTURE/PROGRESS).
  **Approved & committed (2f3b553) — M16 complete.** Follow-up marks M16 done in PROGRESS.md.
- **2026-07-19 (c)** — M16 **checkpoint B built** (Tabs, ADR-027). Early decisions signed off:
  reopen reconnects all saved tabs; closing a tab with running transfers confirms; last-tab-close
  keeps the window with an empty tab; affordances = ＋/⌘T/⌘-double-click + per-tab ✕/⌘W. Refactor:
  `connectionPhase` → `OrderedTabs<ConnectionTab>` (pure collection in FerryCore, unit-tested),
  per-tab `ConnectionPhase`; target tab threaded through the async password/passphrase/host-key
  prompts (each gained `tabID`), a tab closed mid-connect tears its session down; Disconnect →
  grey-dot state, close → disconnect+remove; terminal window plumbing stays model-global (popped-
  out terminal survives tab close). New `TabStripView`; DetailPlaceholderView renders the selected
  tab; MainWindow hosts the strip + close-confirm alert + ⌘W hidden-button; FerryApp ⌘T; Sidebar
  ⌘-double-click new tab + within-folder drag reorder. **XCUITest lesson**: overlay ✕ button
  un-findable (a11y merges overlapping buttons) → two side-by-side buttons per chip
  (`tabStrip.tab.<i>`/`tabStrip.close.<i>`); ⌘W verified to close the active tab, never the
  window. 334 kit (+17) + 14 UI (+3) green; both flavors build.
  Docs updated (DESIGN/DOMAIN/DECISIONS ADR-027/ARCHITECTURE/TESTING/ROADMAP/PROGRESS).
  **Approved & committed (c6942fb).**
- **2026-07-19 (b)** — M16 planned + **checkpoint A built** (Settings window). Split approved
  (full in-window tabs; 3 checkpoints A Settings · B Tabs · C Polish; all four settings groups
  wire in v1). General/Keys/Advanced tabs drawn into `ferry-mockups.html` screen 5 and signed
  off (rule 3). Built: `Settings { }` scene + 5 tabs; FerryCore `AppSettings` (keys/defaults/
  enums + pure `TransferNaming`); Terminal tab reactive over M15 storage + font + scrollback
  (ADR-025 — SwiftTerm 1.14.0's public `changeScrollback` retires the ADR-023 caveat,
  re-asserted in the bridge `sizeChanged` hook); Transfers tab wiring — engine tunables +
  Overwrite/Skip/**Rename** + interrupted Resume/Ask/Restart + queue-done notification
  (ADR-026); General (default folder, appearance via `NSApp.appearance`, reopen-last-
  connections), Keys (key list + Direct-only Generate/Import + known-hosts Manage via new
  `HostKeyStore.allTrustedHosts`), Advanced (logging via `FerryLog` + experimental flag).
  **Debug saga**: `preferredColorScheme` at the WindowGroup root broke the app-launch XCUITest
  (window re-creates) — fixed by applying appearance through `NSApp.appearance`; verified by
  stashing to clean main (passed) then re-testing. The SwiftUI `Settings` scene doesn't open
  under XCUITest (⌘,/menu don't route via automation) → Settings covered by a TESTING.md manual
  checklist (M15 precedent). 317 kit (+14) + 11 UI green; both flavors build. Docs updated
  (DESIGN/DOMAIN/DECISIONS ADR-025+026/TESTING/ROADMAP/PROGRESS + mockups). **Approved &
  committed (ec114e2).**
- **2026-07-19** — M15 built (Open in Terminal — external hand-off, ADR-024). The external
  branch of the ADR-023 dispatch: the Terminal toolbar control + sidebar Open Terminal now
  dispatch on the terminal-choice setting (built-in → M15.5 panel/window; Terminal.app /
  iTerm2 / custom → ssh hand-off, Direct only). New pure `Terminal/TerminalLaunch.swift`
  (`SSHCommandBuilder` — injection-safe quoting, tilde expansion, `-i`/`-p`/`-t` start-path,
  **never a password**; AppleScript escaping; `TerminalDispatch.resolve` matrix;
  `TerminalPreference` storage contract) + app `ExternalTerminalLauncher` (`#if !APPSTORE`;
  `NSAppleScript` for Terminal.app/iTerm2, `Process` for custom) + `TerminalLaunchService`
  (UserDefaults-backed, build-capability aware). External path resolves no credential — ssh
  does its own `~/.ssh/known_hosts` TOFU (DOMAIN.md). **Setting storage-only** (user
  decision: Settings window is M16; picker already mocked in tab 7) — `defaults write`
  until then; ADR-023 defaults fall out of one static default via the resolver. Launch
  mechanism decision recorded in ADR-024 (AppleScript over temp-`.command`/NSWorkspace;
  custom appends the ssh command through a login shell). 303 kit (+27 `TerminalLaunchTests`)
  + 11 UI green; both flavors build; app-launching covered by a TESTING.md manual checklist.
  Docs updated (DOMAIN/DESIGN/DECISIONS/TESTING/ROADMAP/PROGRESS). **Awaiting review —
  nothing committed.**
- **2026-07-18 (e)** — M15.5 checkpoint C built (terminal app UI). A+B committed
  (d7971a8) on user approval. `FerryTerminalUI` linked into the app (pbxproj product
  dependency); `TerminalController` + docked panel + pop-out/terminal-only windows +
  sidebar Open Terminal + `ConnectIntent` prompt threading + `TerminalSession.preflight`
  (kit addition so terminal-only TOFU/auth prompts fire pre-window). Bridge now owns the
  TerminalView (`makeOrReuseView`) so pop-out re-hosts the same live emulator. Metal
  toolchain component installed (SwiftTerm's shader; BUILDING.md). UI-test war stories
  (TESTING.md): container identifiers clobber children; Toggle = checkbox; Touch Bar
  duplicate again. 276 kit + 11 UI tests green; both flavors build. **Checkpoint C
  approved & committed (6410384) — M15.5 complete.**
- **2026-07-18 (d)** — M15.5 checkpoint B built (terminal engine + bridge). SwiftTerm
  1.14.0 added (MIT verified; new `FerryTerminalUI` product so FerryCore stays UI-free;
  LICENSING.md updated). `TerminalSession` actor over Citadel `withPTY` (dedicated
  session, ADR-021 pattern; macOS-15 gate; out-of-band `TerminalEndClassifier` for the
  "Already closed" masking, ADR-020 pattern) + `TerminalSessionBridge`/`SSHTerminalView`
  (SwiftTerm delegate ⇄ session, theme-following colors). One Swift 6 fight: the
  `withPTY` closure must be formed in a nonisolated region (sending non-Sendable
  closure), solved with a nonisolated static driver + `@unchecked Sendable` boxes
  (TunnelEngine idiom). 272 kit tests green (+11 unit, +6 bridge in a new test target,
  +8 integration against :2223 — no testinfra changes); both flavors build.
  ARCHITECTURE.md corrected (aspirational `SSHSessionManager` → session-per-subsystem
  reality), DOMAIN.md gained the Embedded-terminal rules, TESTING.md updated.
  **Checkpoint B awaiting review — nothing committed.**
- **2026-07-18 (c)** — M15.5 planned + checkpoint A built (embedded terminal, ADR-023).
  Planning verified both risks against pinned sources: Citadel 0.12.1 has a **public
  `withPTY`** (pty-req + shell + stdin writer + `changeSize` resize) but it is
  `@available(macOS 15)` like `withExec` with no public macOS-14 path → terminal is
  macOS-15-gated (ADR-020 precedent, no Citadel fork); SwiftTerm v1.14.0 verified MIT,
  SwiftPM, macOS 11 floor, pure emulator (no process spawn → App Store-safe). Plan
  approved: backlog item 6 pulled forward as M15.5; dedicated SSH session via
  `SSHClientFactory` (ADR-021 pattern); SwiftTerm attaches via a new `FerryTerminalUI`
  FerryKit product; embedded-vs-external is one setting driving the one Terminal button
  (user's proposal). Checkpoint A artifacts: mockup **tab 7** in
  `docs/design/ferry-mockups.html` (terminal panel docked below the panes — running +
  session-ended states — and the Settings ▸ Terminal tab with the built-in/external
  picker), DESIGN.md screen 7 (marked PROPOSED), ADR-023 (status: sign-off pending),
  ROADMAP updated. Review round 1 added two user-requested features to the proposal:
  a **pop-out terminal window** (⧉ re-hosts the same live shell; "Dock in Window"
  reverses; tunnel-manager precedent) and **terminal-only connections** (profile
  context-menu "Open Terminal" — a shell with no browser, same dispatch setting, same
  TOFU/credential flow), plus an explicit **scope fence** (no terminal tabs/splits/
  themes/keybindings — ADR-023). **Checkpoint A approved (both rounds) 2026-07-18**;
  markers flipped in mockups/DESIGN.md/ADR-023 — screen 7 is now part of the binding UI
  contract. Checkpoint B (FerryKit) started. Nothing committed yet.
- **2026-07-18 (b)** — M14.5 built (Remote port forwarding, ADR-022). Re-audit of the pinned
  Citadel 0.12.1 checkout found ADR-021's premise outdated: it ships a full public client
  remote-forward API (merged via the **Wellz26/swift-nio-ssh 0.3.6 fork** that
  Package.resolved pins — LICENSING.md corrected, still Apache-2.0). No vendoring needed.
  Engine: `startRemote` wraps `withRemotePortForward` in a stored per-tunnel `Task`
  (validation: destination required, fixed listen port — Citadel dispatches inbound
  `forwarded-tcpip` channels by the requested host/port pair; cancel ⇒ protocol cancel,
  `stop()` awaits it bounded 3 s); new `SSHChannelDataCodec` (Citadel's is internal) + the
  existing `GlueHandler`/count machinery bridge each forwarded channel to the local
  destination on the engine's single loop; `onDisconnect` fails remote tunnels on session
  drop (local/SOCKS listeners deliberately survive). UI: editor warning label removed (closes
  the ADR-021 mockup deviation). Testinfra: `GatewayPorts clientspecified` +
  `127.0.0.1:2224 → :18080` mapping (image rebuilt). Tests: `SSHChannelDataCodecTests` +
  `TunnelRemoteValidationTests` (unit), remote round trip / stop-releases-server-port /
  refusal / live-count integration tests — full `swift test` green, Ferry-Direct builds.
  **Approved & committed a4899a2.**
- **2026-07-18** — M14 built (Tunneling — Local + SOCKS port forwards, ADR-021). New FerryCore
  `Tunnel/` module: **`TunnelEngine`** (actor; own dedicated single-thread event-loop group +
  own SSH session via `SSHClientFactory`, opened lazily; observable status stream;
  start/stop/stopAll/auto-start; live connection counts), **`GlueHandler`** (canonical swift-nio
  bidirectional channel splice), **`SOCKSProxy`** (pure SOCKS5 parser + negotiator). Local
  forwarding rides Citadel's public `direct-tcpip`; SOCKS layers a self-implemented SOCKS5
  server over it. **Main risk resolved**: Citadel 0.12.1 has no public client `tcpip-forward`,
  so **Remote forwarding is deferred to backlog (user sign-off)** — savable/editable but reports
  not-supported. Not macOS-15-gated (no `withExec`). App: `TunnelController` (@Observable),
  `TunnelManagerSheet` (screen 4) + `TunnelEditorSheet` (new UI, signed off), Tunnels toolbar
  button + status-bar count; `BrowserSession` holds a controller for SSH profiles and
  auto-starts on connect; `ConnectionManagerModel` persists tunnel edits. `ConnectionProfile`
  gained optional `autoStartTunnels` (no schemaVersion bump). `network.server` added to the App
  Store entitlements (user sign-off). Glue **ordering** fix during dev: install the local-side
  glue before the SSH channel exists (and hold SOCKS SSH reads until the reply is sent) so the
  server's opening banner isn't dropped. 240 kit + 10 UI tests green (+17/+1); both flavors
  build. **M14 approved & committed (7938556).**
- **2026-07-18** — M13 built (SCP over an SSH exec channel, ADR-020). New FerryCore
  `SCPSource` (actor) reuses the M11 SSH stack via a new **`SSHClientFactory`** (host-key
  TOFU + password/key auth extracted from `SFTPSource` so both share one audited connect).
  Split surface: **metadata via POSIX commands over exec** (`pwd`/`ls -la`/`ls -ld`/`mkdir`/
  `rm -rf`/`mv`/`chmod`, shell-quoted + `--`, `ls` parsed by the reused Unix parser) and
  **bytes via the classic scp protocol** (`scp -f`/`scp -t`) over Citadel's `withExec`.
  Compromises (DOMAIN.md): no resume (download re-reads from start but stream begins at
  offset; upload rejects offset > 0), upload buffers to a local temp + stages to a remote
  `.ferry-scp-part` renamed on success (avoids poisoning the engine's retry). Handled
  `withExec`'s "Already closed" cleanup masking (drivers report out-of-band via the stream
  continuation / an `UploadOutcome`). **macOS 15+ gate** (user decision): `withExec` is
  macOS 15 and Citadel has no macOS-14 path, so `SCPSource` is `@available(macOS 15)` and the
  app blocks SCP on macOS 14 with a clear message; SFTP/FTP/FTPS + the macOS-14 target are
  unaffected. App runs the real SCP connect (`startSCPConnection`); editor already offered
  SCP so **no UI change** (rule 3 met). **Test-infra deviation**: atmoz/sftp can't serve SCP
  (forces `internal-sftp`, no scp binary), so a purpose-built exec-capable OpenSSH container
  (`testinfra/ssh-exec`, :2223, same creds + key) was added; `start.sh` now `--build`s it.
  223 kit + 9 UI tests green (+35/+1); both flavors build. Self-review removed a dead
  `import NIOSSH`. **M13 approved & committed (6b1e981).**
- **2026-07-18** — M12 built (FTP/FTPS via system libcurl, ADR-019). New `CFTP` C target
  wraps libcurl's variadic `setopt`/`getinfo` (Swift can't call C variadics) + callback
  setters; `FTPSource` (actor) implements the whole `FileSystemSource`+`SupervisedConnection`
  surface with **per-operation easy handles** (no persistent session → concurrent transfers
  are trivially safe), running every blocking `curl_easy_perform` on a detached thread and
  bridging download (push→`AsyncThrowingStream`) and upload (push→pull, bounded-buffer
  backpressure) via `@convention(c)` callbacks. Absolute paths via libcurl's `%2F` root
  anchor; home via `PWD`; stat via parent listing; `FTPListParser` for Unix `LIST` (pure,
  unit-tested). FTPS explicit/implicit (`CURLUSESSL_ALL` / `ftps://`), system-trust
  verification, cert-trust prompt deferred to backlog. `BrowserSession` generalized to
  `any FileSystemSource & SupervisedConnection` (added `disconnect()`); app connects
  `.ftp`/`.ftps` with password auth + TLS/auth error mapping. Test infra gained a second
  TLS vsftpd (`ftps`:2990, self-signed cert, `require_ssl_reuse=NO`). 188 kit + 8 UI tests
  green (+33/+1); both flavors build. Self-review applied 4 hardening fixes; cert-trust
  prompt deferred to backlog (user sign-off). **M12 approved & committed.**
- **2026-07-05** — Project inception. Requirements gathered; plan approved (18 milestones). M0: mockups of 5 screens + icon concepts built and iterated (sync browsing added on user request); user approved mockups + icon A. M1: repo initialized, Xcode project + FerryKit package + test targets created, Docker test infra up, icon generated, all docs written. All suites green: 1 unit + 2 integration + 1 UI test (user enabled DevToolsSecurity). M1 approved & committed (97fccf4).
- **2026-07-05 (cont.)** — M2 built: domain models (profile/folder tree/tunnels/auth), ConnectionLibrary operations with cycle-protected move, ConnectionStore JSON persistence (ADR-009). 24 tests green (one test-side fix: stability check had regenerated UUIDs). App builds. M2 approved & committed (18d38e5).
- **2026-07-05 (cont.)** — M3 built: CredentialVault Keychain wrapper (ADR-010: login keychain so `swift test` works unsigned; revisit at M17 for App Store). 35 tests green incl. 8 real-Keychain integration tests. M3 approved & committed (dff4ded).
- **2026-07-05 (cont.)** — M4 built: connection manager UI (sidebar tree, editor sheet, detail summary, folder prompts, drag-to-folder, Move-to menu), ConnectionManagerModel with vault-aware save/delete/duplicate, ReachabilityProbe + hierarchy queries in FerryCore. 40 kit tests + 3 UI tests green. M4 approved & committed (3d17f7c).
- **2026-07-05 (cont.)** — M5 built: FileSystemSource protocol + FileItem/FilePermissions/FileWriteHandle, LocalFileSource (streaming I/O with resume offset contract), SecurityScopedBookmarkStore composed in. 59 tests green. M5 approved & committed (27e1dfe).
- **2026-07-05 (cont.)** — M6 spike: Citadel 0.12.1 added (licenses recorded first), SFTPSource read-only implemented and validated against Docker sshd. Verdict: adopt Citadel, libssh2 fallback retired (ADR-011). Two fixes during spike: error normalization (raw Status thrown), @preconcurrency import for Swift 6. 69 tests green. M6 approved & committed (3c9567a).
- **2026-07-05 (cont.)** — M7 built: BrowserSession/PaneModel (ADR-012), FileBrowserPane + BrowserView per mockup screen 1, connect lifecycle with password prompt, sync browsing (PathUtilities moved to FerryCore for unit-testability). 73 kit tests + 4 UI tests green incl. e2e connect-and-browse. M7 approved & committed (c23cf04).
- **2026-07-05 (cont.)** — M8 built: TransferEngine + queue dock + SFTP uploads/delete + drag between panes. Debugging saga (all fixed, ADR-013): SFTP writes "hung" → root cause was Docker's root-owned mountpoint making /upload unwritable, masked by a happy-path-only test loop; hardened engine cancellation anyway (immediate cancelled state, force-close handle); fixed chunk-dropping stream buffering; fixed whole-row draggable breaking double-click. 84 kit + 4 UI tests green incl. e2e download through the queue. M8 approved & committed (b1c9394).
- **2026-07-17** — M11 checkpoint B built (known_hosts pre-trust + `~/.ssh/config` import,
  ADR-018): read-only `KnownHostsFile` (plaintext + hashed HMAC-SHA1, pinned to `ssh-keygen
  -H`) folded into `SFTPSource`'s TOFU trusted set + changed/unknown decision, wired via a
  new `systemKnownHosts` connect param (frozen for reconnect; `FERRY_SYSTEM_KNOWN_HOSTS`
  override). `SSHConfigParser` → `SSHImportSheet` checklist reached from **File ▸ Import from
  SSH Config…** (⌘⇧I; the sidebar toolbar's third control folds into the toolbar overflow on
  narrow windows, so the menu command is canonical — UI signed off, not in mockups → ADR-018).
  Imports land under an "Imported" folder; no secrets read from config. Both features degrade
  to empty in the App Store sandbox. 155 kit + 7 UI tests green (+20/+1). Both flavors build.
  Code review applied two fixes (imported profiles default the username to the local login
  name à la OpenSSH; changed-key alarm de-dups stored fingerprints). Security review: clean.
- **M11 is complete** (approved & committed a008639).
- **2026-07-17** — M11 checkpoint A built (key auth + host-key TOFU): removed the
  `acceptAnything()` host-key placeholder (M6 shipping blocker closed). New FerryCore `SSH/`
  module — `HostKeyInfo`/`HostKeyStore`/`TOFUHostKeyValidator`/`SSHKeyLoader`; `SFTPSource`
  now verifies host keys TOFU and takes password-or-key credentials; app drives screen 3
  (TOFU + changed-key alarm) + key-passphrase prompt; ssh-agent deferred to backlog
  (ADR-016/017). swift-crypto promoted to a direct dependency. testinfra gained a client
  keypair mount + `PerSourcePenalties no` boot hook (OpenSSH 9.8 penalises TOFU-rejection
  handshakes). 135 kit + 6 UI tests green. **Awaiting review; checkpoint B (known_hosts
  pre-trust + ssh/config import) still to do before M11 is complete.**
- **2026-07-17** — M10 built: SFTP `rename` + `setPermissions` (completing the mutation
  surface on both backends); per-row context menu (Quick Look/Upload·Download/Rename/
  Permissions/Delete); rename alert + delete confirmation (recursive folder warning, no
  Trash); `PermissionsEditorSheet` chmod grid; Quick Look (local in place, remote via temp
  download); Finder drag & drop via a drag-payload split (local items vend file URLs, remote
  items keep the string payload) + a URL drop destination per pane (ADR-015). Remote→Finder
  promise drag backlogged. Test notes: alert TextFields don't expose identifiers (type into
  the auto-focused field); alert buttons live under `windows`, not `dialogs` (Touch Bar dup);
  the context Delete uses "Delete…" to stay unique vs AppKit's Edit▸Delete. 114 kit + 5
  XCUITests green. M10 approved & committed (9cfe66a).
- **2026-07-05 (cont.)** — M9 built: `.ferrypart` staging + resume, pause/resume, transient-error retry policy, lazy folder transfers (SFTP mkdir pulled forward), ConnectionSupervisor keep-alive/auto-reconnect, per-file conflict dialog with apply-to-all, reconnect status bar (ADR-014). Test saga: closing the local SSHClient mid-read fatalErrors NIOSSH → kill-mid-transfer tests drop the session server-side (`docker exec pkill`, matching OpenSSH ≥ 9.8 `sshd-session` naming) on a 32 MiB dd-seeded file; first run hung forever because `for await` deadline checks never fire on silent streams → test waits now race a timer. 112 kit + 4 UI tests green. M9 approved & committed (388de0d).
