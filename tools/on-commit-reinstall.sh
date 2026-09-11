#!/bin/zsh
# Claude Code PostToolUse (Bash) hook gate.
#
# Reads the hook's JSON payload on stdin. When the Bash command that just ran
# was a `git commit`, it launches tools/reinstall-app.sh DETACHED (so the
# session never blocks on the multi-minute Release build) to rebuild Ferry and
# reinstall it to /Applications. For any other command it does nothing.
#
# Wired up in .claude/settings.local.json. Exits 0 always so it never blocks a
# tool call.
set -u

REPO="/Users/gfragos/Documents/Intellij/FraSSH"

# Pull the exact command string out of the payload (falls back to scanning the
# raw JSON if python is unavailable for any reason).
input="$(cat)"
cmd="$(printf '%s' "$input" | /usr/bin/python3 -c \
  'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("command",""))' \
  2>/dev/null || printf '%s' "$input")"

case "$cmd" in
  *"git commit"*)
    log="$REPO/.claude/reinstall-app.log"
    # Detach fully: new session, stdio to the log, so the build outlives this
    # hook invocation and never holds up Claude Code.
    nohup "$REPO/tools/reinstall-app.sh" >>"$log" 2>&1 &
    echo '{"systemMessage":"Ferry commit detected — rebuilding ReleaseDirect and reinstalling to /Applications in the background (see .claude/reinstall-app.log)."}'
    ;;
esac

exit 0
