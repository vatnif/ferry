# Ferry — Domain rules (business logic)

*The behavioral contract of the app. Update whenever a rule changes; the code follows
this document, not the other way round.*

## Connection profiles & folders

- A **ConnectionProfile** holds: name, protocol (sftp/ftp/ftps/scp), host, port, username,
  auth method (password / key file / agent), remote & local start paths, keep-alive flag,
  saved tunnels, UI state (e.g. last paths). **Never any secret.**
- Profiles live in a user-arrangeable **folder tree** (arbitrary nesting). Drag to
  reorganize; folders collapse/expand; state persists.
- Store: JSON (Codable, versioned with a `schemaVersion` field for future migration) at
  `~/Library/Application Support/Ferry/connections.json`. Atomic writes.
- Secrets are referenced by Keychain item, keyed by the profile's stable UUID.

## Credential policy (M3)

- Passwords and key passphrases go to the **macOS Keychain** as app-specific generic
  password items (service `com.gfragos.Ferry`, account `"<profileUUID>/<role>"`, roles:
  `password`, `keyPassphrase`; accessibility WhenUnlocked; login keychain — ADR-010).
  Implemented by `CredentialVault` (store = upsert, delete = idempotent).
- Empty stored password ⇒ prompt at connect time, with "remember" opt-in.
- Deleting a profile deletes its Keychain items. (`.ferrypart` leftovers are not tracked
  per profile — they live wherever the user transfers to; stale ones are GC'd on
  encounter after 30 days, ADR-014.)
- Secrets never appear in: profile JSON, logs, error messages, crash reports, test fixtures.

## Connection lifecycle

1. Resolve profile → 2. establish transport (TCP/TLS/SSH) → 3. **host trust check** (SSH:
   see below) → 4. authenticate → 5. open browsing channel, cd to start paths.
- **Keep-alive**: when enabled, protocol-level no-ops every 30 s (SFTP: `realpath .`) —
  `ConnectionSupervisor` (M9).
- **Auto-reconnect**: on unexpected drop (failed ping, or a transfer that exhausted its
  retries), reconnect with exponential backoff (1/2/4 s, 3 attempts) and reload the
  panes in place; in-flight transfers resume via the engine's retry policy or the
  queue's Resume button. All attempts failed ⇒ status bar shows "Connection lost" with
  a manual Reconnect action. Keep-alive and auto-reconnect share the profile flag.
- **Tabs (M16 checkpoint B, ADR-027)**: one window holds several connections as tabs; each tab
  is an independent session (its own panes, queue, tunnels, terminal, and "Linked" state). The
  detail area follows the selected tab; the sidebar is shared. **Disconnect** (toolbar) returns a
  tab to the disconnected state (grey dot) keeping its profile so it can reconnect in place.
  **Closing** a tab (✕ / ⌘W) disconnects *and* removes it; if that tab's queue still has
  running/queued transfers, closing **confirms first**. Closing the last tab keeps the window with
  one empty tab. App quit still warns if transfers are running.
- **Reopen last connections** restores *every* connection open at last quit, one tab each,
  reconnecting each (prompting for any non-Keychain credential); it persists the connected tabs'
  profile IDs.

## Host key trust (SSH) — TOFU

- Ferry keeps its own host-key store (`~/Library/Application Support/Ferry/known_hosts`,
  OpenSSH format, plaintext entries only). The user's `~/.ssh/known_hosts` is **read** as
  pre-trust, never written (M11 checkpoint B, ADR-018): plaintext **and** hashed
  (HMAC-SHA1) entries are honored, so hosts the user already knows skip the TOFU prompt. A
  system-known host that offers a *different* key still triggers the changed-key alarm. Read
  freely in the Direct build; the App Store build degrades to no pre-trust when `~/.ssh` is
  outside the sandbox.
- Verification is Trust-On-First-Use (M11, ADR-016). The SSH handshake validates against the
  currently-trusted keys; an untrusted key aborts the handshake and Ferry surfaces the
  offered key's algorithm + SHA256 fingerprint for a decision — it cannot pause the
  handshake to ask.
- Unknown key → prompt (mockup: screen 3 top): show algorithm + SHA256 fingerprint,
  "Remember this key" default-on. Trust proceeds (re-connecting with the key now trusted);
  Cancel aborts. With "remember" **off** the key is trusted for the session only (honored on
  an in-session auto-reconnect) and not written to the store.
- **Changed key → alarm dialog** (screen 3 bottom): safe action (Disconnect) is primary;
  replacing the key requires a second confirmation. No "silently accept" path exists.
- **SSH key auth** (M11): OpenSSH-format ed25519 and RSA private keys, encrypted or not; the
  passphrase follows the credential policy above (Keychain `keyPassphrase`, prompt on
  connect, remember opt-in). ECDSA key files are not supported (ADR-017). **ssh-agent** is
  deferred to post-v1 — the UI offers it but reports it as planned.

## Importing existing SSH config (M11 checkpoint B, ADR-018)

- **`~/.ssh/config` import** (File ▸ Import from SSH Config…, ⌘⇧I, mirrored by the sidebar's
  Import toolbar menu): concrete `Host` blocks become SFTP `ConnectionProfile`s under a new
  "Imported" folder. Mapping: `HostName` (alias fallback) → host, `Port`, `User`,
  `IdentityFile` → public-key auth (tilde-expanded path). Wildcard/negated `Host` patterns
  are skipped; `Match`/`ProxyJump`/`ProxyCommand` are ignored (imported without a tunnel).
- The config is read-only and **never carries secrets into Ferry** — key passphrases and
  passwords are prompted on first connect per the credential policy. The import sheet lets
  the user pick which parsed hosts to add. Read freely in the Direct build; degrades to
  "nothing to import" when `~/.ssh` is outside the App Store sandbox.

## FTP / FTPS specifics (M12, ADR-019)

- **Transport**: system libcurl (nothing bundled). FTP has **no persistent session** in
  Ferry — each operation opens its own control+data connection (a login per op), which is
  why concurrent transfers are naturally safe. Keep-alive/auto-reconnect still apply: a
  "ping" is a fresh `PWD` probe.
- **Home directory** comes from the server's `PWD` reply (`257 "<path>"`), not a fixed
  root. Absolute paths are anchored at the server root via libcurl's `%2F` leading-slash
  encoding.
- **Listing** parses the server's Unix `ls -l` `LIST` output (vsftpd/proftpd/pure-ftpd
  dialect). Modified times are **approximate** — `LIST` gives server-local, minute-or-year
  resolution with no time zone; Ferry shows a best-effort date and may show none if the
  line is unparseable. There is no `stat` in FTP: an item's metadata comes from its parent
  directory's listing.
- **File ops**: rename (`RNFR`/`RNTO`, refuses to clobber), delete (`DELE`/recursive
  `RMD`), mkdir with intermediates (`MKD`), permissions (`SITE CHMOD` — a de-facto standard;
  servers without it report the command unsupported). No host-key trust (that's SSH-only).
- **TLS modes**: plain FTP, **explicit FTPS** (`AUTH TLS`, the default for the `ftps`
  scheme on any port but 990), and **implicit FTPS** (`ftps://`, assumed on port 990).
  Certificates are verified against the system trust store. A self-signed / private-CA
  server currently fails with a clear TLS error — a certificate-trust prompt (the analogue
  of host-key TOFU) is a post-v1 backlog item.
- **Resume**: downloads `REST` from the `.ferrypart` size; uploads `APPE` from the remote
  size (FTP can't truncate, so upload resume requires the remote size to equal the offset).

## SCP specifics (M13, ADR-020)

SCP reuses the SSH stack (same host-key TOFU + password/key auth as SFTP), but the classic
scp wire protocol is far weaker than SFTP: it transfers **only file bytes** and has no
listing, stat, mkdir, delete, rename, or chmod. So Ferry splits the surface:

- **Metadata runs POSIX commands over an SSH exec channel**: `pwd` (home), `ls -la`
  (listing, parsed with the same Unix `ls -l` parser as FTP), `ls -ld` (stat), `mkdir -p`,
  `rm -rf`, `mv`, `chmod`. Every path is single-quoted (plus `--`) to block shell
  injection. This costs more round-trips than SFTP's structured requests, and — like FTP —
  timestamps are the `ls` best-effort resolution. Symlink following is not applied to
  `stat` (it reports the link, matching the listing).
- **Bytes stream over the real scp protocol**: `openRead` drives `scp -f` (source→sink),
  `openWrite` drives `scp -t` (sink←source).
- **Capability compromises vs SFTP (v1)**:
  - **No transfer resume.** SCP has no seek and cannot append. A resumed *download* still
    produces byte-exact output but **re-reads from the start** (the stream discards the
    bytes before the offset — no bandwidth saving). A resumed *upload* is **rejected**
    (non-zero offset → the engine restarts it cleanly).
  - **Upload buffers locally first.** scp declares the file size up front, which the
    streaming write contract doesn't provide, so the write handle buffers to a local temp
    file and transfers on close. It stages to a remote `.ferry-scp-part` file and renames
    into place on success, so an interrupted upload never leaves a partial at the
    destination (which would otherwise poison the engine's resume).
  - **Exec required.** A server that accepts the SSH login but forbids command execution
    (e.g. SFTP-only with `ForceCommand internal-sftp`) cannot do SCP; Ferry detects this at
    connect and says so, pointing the user to SFTP.
  - **Availability**: SCP needs Citadel's bidirectional exec channel, which is **macOS
    15+**. On macOS 14 the app blocks an SCP connect with a clear message (SFTP/FTP/FTPS
    are unaffected).

## Transfers & queue (M8–M9)

- Queue is global per app, FIFO within a connection, default **3 concurrent transfers per
  connection** — user-configurable in Settings ▸ Transfers (M16, ADR-026), read at connect
  time. Directory transfers enumerate lazily — a folder item expands
  when it reaches the front of the queue (destination dir created, one queue item per
  child) and counts as many items.
- Each item: direction, source → destination, progress, speed (rolling average), ETA,
  pause/cancel. Badges: QUEUED / UPLOADING / DOWNLOADING / RESUMED / ERROR (+ DONE,
  PAUSED, CANCELLED for the remaining states).
- **Resume — downloads**: data streams to `<name>.ferrypart`; on resume, restart from its
  byte count (SFTP: seek/offset read; FTP: `REST`). On completion, atomically rename into
  place. A partial resumes only if it is not stale and not larger than the source;
  `.ferrypart` files older than 30 days are garbage-collected when encountered (ADR-014).
- **Resume — uploads**: stat remote size; if smaller than local and resume is allowed,
  continue from remote size (SFTP: append/offset write; FTP: `APPE`/`REST`). Applies on
  engine retries and the queue's Resume button; a *re-staged* upload whose destination
  exists is a conflict (Ferry cannot tell an interrupted upload from a foreign file).
- **Pause**: stops the item, keeps partial data, badge PAUSED; Resume continues from the
  partial (badge RESUMED). Cancelling keeps partial data for a later automatic resume.
- **Conflict policy** (file exists), Settings ▸ Transfers (M16, ADR-026): Overwrite /
  **Ask (default)** / Skip / Rename. Overwrite replaces from byte 0; Ask walks conflicts
  per file with Replace / Replace All / Skip / Skip All; Skip drops the conflicting items;
  Rename enqueues a `name 2.ext` copy (Finder-style de-duplication). Replace on a folder =
  merge, overwriting same-named children. **Interrupted-transfer policy** (a resumable
  `.ferrypart` exists, no final file): **Resume automatically (default)** / Ask / Restart —
  Ask prompts Resume / Resume All / Start Over / Skip per item.
- Failed items retry **N× (default 3, Settings ▸ Transfers)** with 5 s spacing before
  showing ERROR — transient
  (I/O) errors only; deterministic failures (missing file, permissions) fail immediately.
- Post-transfer checksum verification (v1.x): only when server supports it; mismatch ⇒ ERROR.

## Dual-pane browsing

- Local pane left, remote right; both are the same browser component (sortable columns,
  clickable breadcrumbs, hidden-files toggle, type-to-filter). Remote adds permissions +
  owner columns; chmod editor from the row context menu (rwx grid + octal field).
- **Sync browsing** (approved M0 addition): per-tab "Linked" toggle. On enable, both
  current paths become anchor roots; navigation mirrors relative paths. Missing folder on
  the other side ⇒ that pane stays, path bar flashes, link persists. Toggle off ⇒
  independent again.
- Drag & drop: between panes ⇒ queue transfer; from Finder ⇒ same (drop files onto a
  pane to upload/copy); local files drag out to Finder. Remote→Finder promise drag is
  backlogged. Double-click: folders navigate; files on local Quick Look, on remote
  download-and-Quick-Look (streamed to a temp file first).
- File ops (row context menu): rename (in place, rejects "/" and clobbering an existing
  name), delete (confirms; recursive for folders; no Trash — items are removed, not moved),
  chmod (both panes). Rename refuses to overwrite; replacements go through the conflict
  dialog, never a silent clobber.

## Tunnels (M14; Remote M14.5)

- Types: **Local** (listen locally → destination reachable from the server), **Dynamic SOCKS**
  (loopback SOCKS5 proxy; per-connection target), and **Remote** (the server listens via a
  `tcpip-forward` request; each server-side connection arrives back as a `forwarded-tcpip`
  channel and is bridged to a destination reachable from this Mac — ADR-022). A Remote tunnel
  needs a **fixed listen port** (Citadel dispatches incoming channels by the requested
  host/port pair, so "let the server choose" can't work); its listen host is the *server-side*
  bind address (default loopback; subject to the server's `GatewayPorts` policy). If the SSH
  session drops, remote tunnels fail immediately ("The SSH session dropped."); local/SOCKS
  listeners stay up and re-dial lazily.
- Saved per profile (`ConnectionProfile.tunnels`); `isEnabled` marks a tunnel for auto-start,
  and the per-profile `autoStartTunnels` flag (footer checkbox; nil ⇒ on) gates whether enabled
  tunnels come up on connect. The Active toggle starts/stops a tunnel live while connected.
- `TunnelEngine` runs a **dedicated SSH session** (its own `SSHClientFactory` connect — same
  host-key TOFU + auth, reusing the resolved credential so no second prompt), opened lazily the
  first time a tunnel starts. It's independent of the browser's SFTP/SCP session. Tunnels apply
  to SSH-based profiles only (SFTP/SCP); FTP/FTPS have no Tunnels button. Not macOS-15-gated —
  forwarding uses `direct-tcpip`, which needs no `withExec`.
- Errors (port in use, permission, remote refusal) surface inline in the tunnel manager's
  status column; the live connection count shows there too.

## Terminal hand-off (M15, Direct builds only)

- The Terminal action is **one button, one setting** (ADR-023): the browser toolbar's
  Terminal control and the sidebar profile's **Open Terminal** item both dispatch on
  Settings ▸ Terminal. "Ferry's built-in terminal" opens the embedded terminal (M15.5,
  below); **Terminal.app / iTerm2 / a custom command** do the external hand-off (this
  section). SSH profiles only (SFTP/SCP); FTP/FTPS show no Terminal control.
- The external hand-off builds an `ssh` command from the profile — host, `-p <port>` (when
  not 22), `-i <key file>` for key auth, and the **remote start path** as
  `-t 'cd '<path>'; exec $SHELL -l'` when set — and launches it in the chosen app.
  **Passwords are never passed** (rule 6): a password profile relies on ssh prompting in
  the terminal; a key profile passes only the key *path*.
- **Host-key trust for the external path is ssh's, not Ferry's.** The launched `ssh` does
  its own Trust-On-First-Use against the user's `~/.ssh/known_hosts` (writing to it on
  first accept) — Ferry's own `known_hosts` store (used by SFTP/SCP/the built-in terminal)
  is not consulted or updated. So a host may prompt for its key in the terminal even if
  Ferry already trusts it, and vice-versa. This is expected: the external terminal is a
  hand-off to the OS's ssh, with its own trust database.
- **Custom command** receives the built ssh command appended to it (run through a login
  shell so PATH resolves), e.g. a launcher that opens your terminal of choice with the
  ssh command as its argument.
- **Hidden in `APPSTORE` builds** (rule 5): launching other apps can't work sandboxed, so
  the three external options never appear and the built-in terminal is the only behavior.
- **Defaults** (ADR-023): built-in on macOS 15+; on macOS 14 the Direct build falls back
  to Terminal.app (the built-in terminal needs macOS 15), while the App Store build shows
  "requires macOS 15" (no external fallback). The setting is storage-only until the
  Settings window ships (M16) — see Embedded terminal below.

## Embedded terminal (M15.5, ADR-023 — both builds)

- **One setting, one entry point**: the Terminal toolbar button and the profile
  context menu's "Open Terminal" dispatch on Settings ▸ Terminal — "Ferry's built-in
  terminal" (default on macOS 15+) opens the embedded terminal; Terminal.app / iTerm2 /
  custom command do the M15 hand-off (Direct only; the App Store build hides them).
- **SSH profiles only** (SFTP/SCP) — FTP/FTPS show no terminal entry points (no shell).
  Remote shells only; Ferry never spawns local processes (sandbox-safe).
- **macOS 15+** — the SSH library's PTY API carries the same availability gate as SCP
  (ADR-020/023). On macOS 14: Settings disables the built-in option with "Requires
  macOS 15"; Direct falls back to Terminal.app, the App Store build disables the
  entry points with the explainer.
- **Session**: every terminal (docked panel or window) is its own SSH session built by
  `SSHClientFactory` — identical host-key TOFU, reuses the profile's resolved
  credential, never re-prompts. Independent of the browser's session and of tunnels.
- **End states**: `exit`/EOF (any exit code) and user close read as a clean end (the
  ended banner with Restart Session); a dropped SSH session or refused shell reads as
  a failure with a specific message. A server that forces a non-shell command (e.g.
  SFTP-only) yields a session that ends on input — never a hang.
- **Privacy (rule 6)**: nothing typed or displayed in a terminal is ever logged;
  scrollback lives only in the emulator's memory and dies with the session's view.

## Settings (M16, ADR-025/026)

The Settings window (screen 5; app menu / ⌘,) persists everything in `UserDefaults` and
applies changes immediately. Keys, defaults, and typed values are centralized in FerryCore
`AppSettings` (raw strings are a persistence contract, like `TerminalPreference`).

- **General**: *default local folder* (used as the local pane's start folder only when a
  profile doesn't set its own), *appearance* Light/Dark/System (applied app-wide via
  `NSApp.appearance`), *reopen last connections* on launch (restores the connections open at
  last quit; you're prompted for any non-Keychain credential; skipped under test isolation).
- **Transfers**: simultaneous transfers, interrupted/exists policies, retry count,
  queue-done notification (see Transfers above). Bandwidth limit + checksum are v1.x
  (visible but disabled).
- **Keys**: lists `~/.ssh` public keys; generate/import keys (Direct only — the sandbox
  can't reach `~/.ssh` or spawn `ssh-keygen`, so these degrade to empty/disabled in the App
  Store build); ssh-agent shown disabled (planned, ADR-017); manage Ferry's own trusted
  host keys (list/forget — the user's `~/.ssh/known_hosts` stays read-only pre-trust).
- **Terminal**: the built-in/external picker (M15 storage, now reactive) plus built-in font
  and scrollback (scrollback is memory-only, rule 6). Built-in requires macOS 15; external
  options are Direct-only.
- **Advanced**: logging level (off/errors/verbose — never records secrets or terminal bytes,
  rule 6) and an experimental-features flag.

## Sandbox strategy (both distributions from day one)

- All local-FS access flows through `LocalFileSource`, whose every operation runs inside
  `SecurityScopedBookmarkStore.withAccess(toPathContaining:)` — it starts/stops
  security-scoped access for the deepest granted folder covering the path, and is a
  pass-through when no grant matches (always true in the Direct build). Grants are
  persisted bookmarks (JSON next to connections.json) registered when the user picks a
  folder in an open panel; stale bookmarks self-refresh on resolve.
- Capabilities that can't work sandboxed (ssh-agent, launch Terminal, Sparkle) are gated
  at seams with `#if APPSTORE` or runtime capability checks — degrade, don't crash.
- Network: outbound client (`com.apple.security.network.client`) **plus**
  `com.apple.security.network.server` (M14, ADR-021) — Local and SOCKS forwards bind a loopback
  listener socket and *accept* connections, which the sandbox permits only with the server
  entitlement. Remote forwards (M14.5) need nothing further: the listener lives on the *server*;
  the forwarded channels arrive over the existing SSH connection and the bridge to the local
  destination is an ordinary outbound connect (`network.client`, already held). The Direct
  build is unsandboxed.
