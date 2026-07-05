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
  password items (service `com.gfragos.Ferry`, account = profile UUID + role).
- Empty stored password ⇒ prompt at connect time, with "remember" opt-in.
- Deleting a profile deletes its Keychain items and its `.ferrypart` leftovers.
- Secrets never appear in: profile JSON, logs, error messages, crash reports, test fixtures.

## Connection lifecycle

1. Resolve profile → 2. establish transport (TCP/TLS/SSH) → 3. **host trust check** (SSH:
   see below) → 4. authenticate → 5. open browsing channel, cd to start paths.
- **Keep-alive**: when enabled, protocol-level no-ops every 30 s.
- **Auto-reconnect**: on unexpected drop, retry with backoff (3 attempts) and restore the
  panes' paths; in-flight transfers re-queue as resumable.
- Disconnect on tab close; app quit warns if transfers are running.

## Host key trust (SSH) — TOFU

- Ferry keeps its own host-key store (`~/Library/Application Support/Ferry/known_hosts`,
  OpenSSH format). The user's `~/.ssh/known_hosts` is **read** to pre-trust, never written.
- Unknown key → prompt (mockup: screen 3 top): show algorithm + SHA256 fingerprint,
  "remember" default-on. Trust proceeds; Cancel aborts before auth.
- **Changed key → alarm dialog** (screen 3 bottom): safe action (Disconnect) is primary;
  replacing the key requires a second confirmation. No "silently accept" path exists.

## Transfers & queue (M8–M9)

- Queue is global per app, FIFO within a connection, default **3 concurrent transfers per
  connection** (setting). Directory transfers enumerate lazily and count as many items.
- Each item: direction, source → destination, progress, speed (rolling average), ETA,
  pause/cancel. Badges: QUEUED / UPLOADING / DOWNLOADING / RESUMED / ERROR.
- **Resume — downloads**: data streams to `<name>.ferrypart`; on resume, restart from its
  byte count (SFTP: seek/offset read; FTP: `REST`). On completion, atomically rename into
  place. `.ferrypart` files older than 30 days are garbage-collected.
- **Resume — uploads**: stat remote size; if smaller than local and resume is allowed,
  continue from remote size (SFTP: append/offset write; FTP: `APPE`/`REST`).
- **Conflict policy** (file exists): Overwrite / **Ask (default)** / Skip / Rename; the
  ask-dialog offers "apply to all". Interrupted-transfer policy: **Resume automatically
  (default)** / Ask / Restart.
- Failed items retry 3× with 5 s spacing (setting) before showing ERROR.
- Post-transfer checksum verification (v1.x): only when server supports it; mismatch ⇒ ERROR.

## Dual-pane browsing

- Local pane left, remote right; both are the same browser component (sortable columns,
  clickable breadcrumbs, hidden-files toggle, type-to-filter). Remote adds permissions +
  owner columns; chmod editor from context menu (M10).
- **Sync browsing** (approved M0 addition): per-tab "Linked" toggle. On enable, both
  current paths become anchor roots; navigation mirrors relative paths. Missing folder on
  the other side ⇒ that pane stays, path bar flashes, link persists. Toggle off ⇒
  independent again.
- Drag & drop: between panes ⇒ queue transfer; from/to Finder ⇒ same. Double-click:
  folders navigate; files on local Quick Look, on remote (M10+) download-and-Quick-Look.

## Tunnels (M14)

- Types: Local (listen locally → remote dest), Remote (listen remotely → local dest),
  Dynamic SOCKS. Saved per profile; optional auto-start on connect; live start/stop.
- Reuse the profile's SSH session. Errors (port in use, refusal) surface inline in the
  tunnel manager's status column.

## Terminal hand-off (M15, Direct builds only)

- "Terminal" builds an `ssh` command from the profile (host, port, user, key file) and
  opens Terminal.app / iTerm2 / custom (setting). Passwords are never passed; key auth or
  the user types it. Hidden entirely in `APPSTORE` builds.

## Sandbox strategy (both distributions from day one)

- All local-FS access flows through `LocalFileSource`, which manages security-scoped
  bookmarks; in the Direct build the same code path simply finds everything accessible.
- Capabilities that can't work sandboxed (ssh-agent, launch Terminal, Sparkle) are gated
  at seams with `#if APPSTORE` or runtime capability checks — degrade, don't crash.
- Network: outbound client only (`com.apple.security.network.client`). Remote tunnels
  listen on the *server*, so no server entitlement is needed.
