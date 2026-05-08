#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 simonlinuxcraft
#
# nxm_handler.sh - bridge for the nxm:// URL scheme on Linux.
#
# Registered as the default handler for `x-scheme-handler/nxm` via
# `~/.local/share/applications/kyber-bf2-nxm.desktop`. When the user
# clicks "Mod Manager Download" on the Nexus website, the browser fires
# this script with the `nxm://...?key=...&expires=...` URL as $1. We
# atomically deposit the URL into a per-user response file inside
# $XDG_RUNTIME_DIR (which is 0700/$UID, so other users cannot read or
# overwrite it) and the launcher's inotify watcher picks it up.
#
# This is the Linux equivalent of the Windows protocol_handler plugin's
# WM_COPYDATA dispatch — the kyber-bf2-linux reference build uses the
# same pattern but with /tmp; we use $XDG_RUNTIME_DIR for safety.

set -eu

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <nxm://...>" >&2
  exit 64
fi

RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
KYBER_DIR="$RUNTIME_DIR/kyber"
RESPONSE_FILE="$KYBER_DIR/nxm-response"

mkdir -p "$KYBER_DIR"
chmod 700 "$KYBER_DIR"

# Atomic write: temp file in the same dir, then rename. Avoids the
# launcher's watcher reading a half-written URL when two NXM clicks
# arrive in quick succession.
TMPFILE=$(mktemp "$KYBER_DIR/nxm-response.XXXXXX")
trap 'rm -f "$TMPFILE"' EXIT INT HUP TERM
printf '%s\n' "$1" > "$TMPFILE"
mv "$TMPFILE" "$RESPONSE_FILE"
trap - EXIT

exit 0
