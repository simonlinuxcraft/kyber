#!/usr/bin/env bash
# Builds the Linux maxima-bootstrap and drops it into the launcher bundle.
# The bootstrap is the qrc:// protocol handler that catches the EA OAuth
# redirect after login and forwards the auth code to the running launcher
# (which listens on 127.0.0.1:31033 during the login flow).
#
# Run this after every `flutter build linux --release` — the Flutter build
# does not produce or copy maxima-bootstrap on its own.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
MAXIMA_DIR="$ROOT/Kyber/ThirdParty/Maxima"
BUNDLE_DIR="$ROOT/Kyber/Launcher/build/linux/x64/release/bundle"
DESKTOP_FILE="$HOME/.local/share/applications/maxima-qrc.desktop"

if [[ ! -d "$MAXIMA_DIR" ]]; then
    echo "Maxima workspace not found at $MAXIMA_DIR" >&2
    exit 1
fi
if [[ ! -d "$BUNDLE_DIR" ]]; then
    echo "Launcher bundle not found at $BUNDLE_DIR — run 'flutter build linux --release' first" >&2
    exit 1
fi

echo ">>> cargo build --release -p maxima-bootstrap"
( cd "$MAXIMA_DIR" && cargo build --release -p maxima-bootstrap )

SRC_BIN="$MAXIMA_DIR/target/release/maxima-bootstrap"
DST_BIN="$BUNDLE_DIR/maxima-bootstrap"

echo ">>> install $SRC_BIN -> $DST_BIN"
install -m 0755 "$SRC_BIN" "$DST_BIN"

if [[ -f "$DESKTOP_FILE" ]]; then
    EXEC_LINE=$(grep -E '^Exec=' "$DESKTOP_FILE" || true)
    if [[ "$EXEC_LINE" != *"$DST_BIN"* ]]; then
        echo "WARN: $DESKTOP_FILE Exec= does not match $DST_BIN"
        echo "      current: $EXEC_LINE"
    fi
else
    echo "WARN: $DESKTOP_FILE missing — run xdg-mime default maxima-qrc.desktop x-scheme-handler/qrc after creating it"
fi

echo ">>> update-desktop-database"
update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true

echo ">>> smoke test (--noop)"
"$DST_BIN" --noop >/dev/null
echo "OK"
