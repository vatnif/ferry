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
- Disconnect on tab close; app quit warns if transfers are running.

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

## Transfers & queue (M8–M9)

- Queue is global per app, FIFO within a connection, default **3 concurrent transfers per
  connection** (setting). Directory transfers enumerate lazily — a folder item expands
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
- **Conflict policy** (file exists): Overwrite / **Ask (default)** / Skip / Rename; the
  ask-dialog walks conflicts per file with Replace / Replace All / Skip / Skip All
  (Overwrite/Skip/Rename presets arrive with Settings, M16). Replace on a folder =
  merge, overwriting same-named children. Interrupted-transfer policy: **Resume
  automatically (default)** / Ask / Restart (setting arrives M16; default implemented).
- Failed items retry 3× with 5 s spacing (setting) before showing ERROR — transient
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

- All local-FS access flows through `LocalFileSource`, whose every operation runs inside
  `SecurityScopedBookmarkStore.withAccess(toPathContaining:)` — it starts/stops
  security-scoped access for the deepest granted folder covering the path, and is a
  pass-through when no grant matches (always true in the Direct build). Grants are
  persisted bookmarks (JSON next to connections.json) registered when the user picks a
  folder in an open panel; stale bookmarks self-refresh on resolve.
- Capabilities that can't work sandboxed (ssh-agent, launch Terminal, Sparkle) are gated
  at seams with `#if APPSTORE` or runtime capability checks — degrade, don't crash.
- Network: outbound client only (`com.apple.security.network.client`). Remote tunnels
  listen on the *server*, so no server entitlement is needed.
