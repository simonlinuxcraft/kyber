#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 simonlinuxcraft
#
# update_apply.sh — Sidecar that swaps a freshly staged launcher build
# into the active "current" slot under $HOME/.local/share/kyber/launcher,
# then re-execs the launcher.
#
# Why a separate process: Linux lets you unlink and replace a binary
# while it's running, but the running process still holds the old
# inode. To make sure the user sees the new version on relaunch we
# (a) wait for the previous launcher to exit, (b) flip the
# `current` symlink atomically, (c) update the state file, and
# (d) exec the new launcher.
#
# Called either by the launcher right before it exits ("apply on exit")
# or by the kyber-bf2 wrapper when it detects update_pending.json
# without an active launcher process. Both paths are idempotent.
#
# Layout managed:
#
#   $KYBER_DIR/
#     versions/<X.Y.Z>/        compiled launcher tree (binary, lib/, data/, cli/)
#     current     -> versions/<X.Y.Z>     (relative symlink)
#     update_pending.json      written by linux_self_update_service.dart
#     update_apply.log         this script's last run log
#     .update.lock             flock target for self-update operations

set -eu

KYBER_DIR="${HOME}/.local/share/kyber/launcher"
PENDING_FILE="$KYBER_DIR/update_pending.json"
LOG_FILE="$KYBER_DIR/update_apply.log"
LOCK_FILE="$KYBER_DIR/.update.lock"
VERSIONS_DIR="$KYBER_DIR/versions"
CURRENT_LINK="$KYBER_DIR/current"

mkdir -p "$KYBER_DIR" "$VERSIONS_DIR"

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG_FILE"
}

bump_attempts() {
  # Read attempts counter, increment, write back. Bounded retries
  # protect against poison updates that crash on every start.
  local attempts=0
  if command -v jq >/dev/null 2>&1; then
    attempts=$(jq -r '.attempts // 0' "$PENDING_FILE" 2>/dev/null || echo 0)
    attempts=$((attempts + 1))
    local tmp
    tmp=$(mktemp "$KYBER_DIR/update_pending.json.XXXXXX")
    jq --argjson a "$attempts" '.attempts = $a' "$PENDING_FILE" > "$tmp" \
      && mv "$tmp" "$PENDING_FILE"
  else
    # Fallback without jq: persist counter as a plain integer in a
    # sidecar file. Counting bytes via wc -c is fragile (wc -c on
    # `printf '.'` includes implicit-newline, locale, fs-block edge
    # cases) — keep it simple.
    local counter_file="$KYBER_DIR/update_pending.attempts"
    if [ -s "$counter_file" ]; then
      attempts=$(cat "$counter_file" 2>/dev/null || echo 0)
    fi
    case "$attempts" in *[!0-9]*|'') attempts=0 ;; esac
    attempts=$((attempts + 1))
    printf '%d\n' "$attempts" > "$counter_file"
  fi
  echo "$attempts"
}

abort_pending() {
  log "abort_pending: $1"
  rm -f "$PENDING_FILE" "$KYBER_DIR/update_pending.attempts"
}

# Open the lock and hold it for the duration of the swap. flock with
# -n exits 1 if another process owns it (e.g. a parallel launcher
# instance also trying to apply). The launcher should never spawn two
# of us simultaneously, but it's cheap insurance.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "another update_apply.sh holds the lock; aborting"
  exit 0
fi

if [ ! -s "$PENDING_FILE" ]; then
  log "no pending update"
  exit 0
fi

attempts=$(bump_attempts)
log "pending update detected (attempts=$attempts)"

if [ "$attempts" -gt 3 ]; then
  abort_pending "exceeded 3 attempts; refusing to retry"
  exit 1
fi

# Read the staged version. Prefer jq, fall back to a primitive grep
# so this still works on minimal containers.
if command -v jq >/dev/null 2>&1; then
  staged_version=$(jq -r '.version // empty' "$PENDING_FILE")
else
  staged_version=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "$PENDING_FILE" \
    | head -n1 | sed 's/.*"\([^"]*\)"$/\1/')
fi

if [ -z "$staged_version" ]; then
  abort_pending "update_pending.json missing 'version'"
  exit 1
fi

staged_dir="$VERSIONS_DIR/$staged_version"
if [ ! -d "$staged_dir" ] || [ ! -x "$staged_dir/kyber_launcher" ]; then
  abort_pending "staged version $staged_version not on disk or missing binary"
  exit 1
fi

# Atomic symlink replacement: write to a temporary name in the same
# directory and rename over `current`. ln -sfn does this internally.
log "swapping current -> versions/$staged_version"
ln -sfn "versions/$staged_version" "$CURRENT_LINK"

# Update succeeded — drop the marker so we don't try again next boot.
rm -f "$PENDING_FILE" "$KYBER_DIR/update_pending.attempts"
log "update_apply succeeded"

# Re-exec the new launcher unless the caller set NOEXEC=1 (the
# launcher boot hook calls us with NOEXEC=1 and re-execs itself).
# `cd` into the launcher directory first so any libraries shipped
# alongside it (lib/, cli/) resolve via $ORIGIN-based RPATH the same
# way the kyber-bf2 wrapper would set them up. Without this, RPATH
# lookups fail when the binary is exec'd from an unrelated cwd.
if [ "${NOEXEC:-0}" != "1" ]; then
  target="$CURRENT_LINK/kyber_launcher"
  cd "$(dirname "$(readlink -f "$target")")" 2>/dev/null || cd "$CURRENT_LINK"
  exec "$target" "$@"
fi
