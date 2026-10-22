#!/bin/bash
# Builds ClaudeMultiAcc.app and installs it into ~/Applications atomically.
# Usage: scripts/install.sh [--restart] [--link-cli] [bundle-app.sh options…]
#   --restart   terminate a running ClaudeMultiAcc (only ours) and relaunch it after install
#   --link-cli  symlink ~/.local/bin/cmacc to the installed helper (only if ~/.local/bin exists)
set -euo pipefail

BUNDLE_ID="com.imaxzone.ClaudeMultiAcc"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="$HOME/Applications"
DEST="$DEST_DIR/ClaudeMultiAcc.app"
STAGED="$DEST_DIR/.ClaudeMultiAcc.app.new"
OLD="$DEST_DIR/.ClaudeMultiAcc.app.old"

RESTART=0
LINK_CLI=0
BUNDLE_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --restart) RESTART=1 ;;
    --link-cli) LINK_CLI=1 ;;
    *) BUNDLE_ARGS+=("$1") ;;
  esac
  shift
done

is_running() {
  [[ -n "$(lsappinfo find "bundleid=$BUNDLE_ID")" ]]
}

WAS_RUNNING=0
if is_running; then
  if [[ $RESTART -eq 0 ]]; then
    echo "ClaudeMultiAcc is running; quit it first or pass --restart." >&2
    exit 1
  fi
  WAS_RUNNING=1
fi

"$ROOT/scripts/bundle-app.sh" ${BUNDLE_ARGS[@]+"${BUNDLE_ARGS[@]}"} >/dev/null

if [[ $WAS_RUNNING -eq 1 ]]; then
  # Older macOS prints `"pid"=123`, macOS 27 prints a block containing `pid = 123`.
  PID="$(lsappinfo info -only pid -app "$BUNDLE_ID" | grep -oE 'pid"? ?= ?[0-9]+' | grep -oE '[0-9]+' | head -1 || true)"
  if [[ "$PID" =~ ^[0-9]+$ ]]; then
    kill -TERM "$PID"
    for _ in $(seq 1 50); do is_running || break; sleep 0.1; done
  fi
  if is_running; then
    echo "ClaudeMultiAcc did not quit; install aborted." >&2
    exit 1
  fi
fi

mkdir -p "$DEST_DIR"
rm -rf "$STAGED" "$OLD"
ditto "$ROOT/dist/ClaudeMultiAcc.app" "$STAGED"
if [[ -e "$DEST" ]]; then mv "$DEST" "$OLD"; fi
mv "$STAGED" "$DEST"
rm -rf "$OLD"

if [[ $LINK_CLI -eq 1 ]]; then
  if [[ -d "$HOME/.local/bin" ]]; then
    ln -sfn "$DEST/Contents/Helpers/cmacc" "$HOME/.local/bin/cmacc"
  else
    echo "~/.local/bin does not exist; skipping CLI link." >&2
  fi
fi

if [[ $WAS_RUNNING -eq 1 ]]; then open "$DEST"; fi

echo "$DEST"
