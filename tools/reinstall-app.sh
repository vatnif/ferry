#!/bin/zsh
# Rebuild Ferry (Release/Direct flavor) and install it to /Applications so the
# copy the user launches always tracks the latest committed code.
#
# Run by hand any time, or automatically after each `git commit` via the
# Claude Code PostToolUse hook in .claude/settings.local.json (which invokes
# tools/on-commit-reinstall.sh). Safe to run standalone.
set -eu

REPO="/Users/gfragos/Documents/Intellij/FraSSH"
cd "$REPO"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Building Ferry-Direct (ReleaseDirect)…"
/usr/bin/xcodebuild -scheme Ferry-Direct -configuration ReleaseDirect \
    -destination 'platform=macOS' build

APP="$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/Ferry-*/Build/Products/ReleaseDirect/Ferry.app 2>/dev/null | head -1)"
if [ -z "${APP:-}" ] || [ ! -d "$APP" ]; then
  echo "[$(date '+%H:%M:%S')] ERROR: built Ferry.app not found under DerivedData/…/ReleaseDirect" >&2
  exit 1
fi

echo "[$(date '+%H:%M:%S')] Installing $APP → /Applications/Ferry.app"
rm -rf "/Applications/Ferry.app"
cp -R "$APP" "/Applications/Ferry.app"

echo "[$(date '+%H:%M:%S')] Done — /Applications/Ferry.app now tracks $(git -C "$REPO" rev-parse --short HEAD)."
