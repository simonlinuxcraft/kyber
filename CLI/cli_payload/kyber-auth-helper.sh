#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Original source: ACowAdonis kyber-bf2-linux tarball
#   (src/share/kyber-bf2/payload/cli/kyber-auth-helper.sh, V1.0.0)
# Vendored 2026-05-05 into the Kyber Linux Port. Bundled and
# distributed under GPL-3.0-or-later.
#
# Kyber EA Auth Helper
#
# Fallback for when the browser redirect to localhost doesn't reach
# the Kyber auth server (e.g., port conflict, firewall).
#
# After logging in on EA's website, the browser redirects to:
#   http://127.0.0.1:31033/auth?code=SOME_CODE_HERE
#
# If the browser shows "Login successful!" the code was delivered
# automatically and you don't need this script.
#
# If the browser shows a connection error, copy the URL from the
# address bar and paste it here.
#
# Usage:
#   Terminal 1: ~/.local/share/kyber/cli/launch-kyber.sh
#   Terminal 2: ~/.local/share/kyber/cli/kyber-auth-helper.sh

set -euo pipefail

echo "=== Kyber EA Auth Helper ==="
echo ""

# Check if the CLI auth server is listening
if ! curl -s -o /dev/null --connect-timeout 1 "http://127.0.0.1:31033/" 2>/dev/null; then
    echo "NOTE: Could not reach the auth server on port 31033."
    echo "Make sure launch-kyber.sh is running in another terminal first."
    echo ""
fi

echo "After logging in on EA's website, the browser should redirect to"
echo "http://127.0.0.1:31033/auth?code=..."
echo ""
echo "If the browser shows 'Login successful!' then you don't need this"
echo "script -- the auth code was delivered automatically."
echo ""
echo "If the browser shows a connection error, copy the full URL from"
echo "the browser's address bar and paste it below."
echo ""
echo "Paste the URL here (or just the code value):"
read -r INPUT

# Accept a full URL with code=, or a raw code value
CODE=""
if echo "$INPUT" | grep -qP 'code='; then
    CODE=$(echo "$INPUT" | grep -oP 'code=\K[^&]+')
elif echo "$INPUT" | grep -qP '^[A-Za-z0-9_-]+$'; then
    CODE="$INPUT"
fi

if [ -z "$CODE" ]; then
    echo ""
    echo "ERROR: Could not find an auth code in your input."
    echo "Expected a URL containing code=XXXXX or just the code value."
    exit 1
fi

echo ""
echo "Sending auth code to Kyber..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    "http://127.0.0.1:31033/auth?code=$CODE" 2>/dev/null) || true

if [ "$HTTP_CODE" = "200" ]; then
    echo "Login successful! Check terminal 1 - the game should start launching."
elif [ "$HTTP_CODE" = "000" ]; then
    echo "ERROR: Could not connect to port 31033."
    echo "Is launch-kyber.sh still running in the other terminal?"
    echo "Each launch-kyber.sh session generates a unique login challenge."
    echo "If you restarted it, you need to log in again with the new browser URL."
else
    echo "Auth server responded with HTTP $HTTP_CODE."
    echo "Check terminal 1 for details (look for error messages)."
    echo ""
    echo "Common issue: 'code is invalid' means the code expired or came"
    echo "from a different launch-kyber.sh session. Restart and try again."
fi
