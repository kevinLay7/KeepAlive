#!/bin/bash
# Build + install the KeepAlive root helper. Re-run to update.
#
# Requires sudo (installs a LaunchDaemon).
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY_SRC="$DIR/KeepAliveHelper.swift"
PLIST_SRC="$DIR/com.kevinlay.keepalive.helper.plist"

BIN_DST="/usr/local/libexec/keepalive-helper"
PLIST_DST="/Library/LaunchDaemons/com.kevinlay.keepalive.helper.plist"
LABEL="com.kevinlay.keepalive.helper"

if [[ $EUID -ne 0 ]]; then
    echo "Re-running under sudo..."
    exec sudo "$0" "$@"
fi

echo "[1/5] Building helper..."
TMP_BIN="$(mktemp -t keepalive-helper)"
# Use all available SDKs; no frameworks beyond Foundation required.
swiftc -O -o "$TMP_BIN" "$BINARY_SRC"

echo "[2/5] Stopping existing daemon (if any)..."
launchctl bootout system "$PLIST_DST" 2>/dev/null || true

echo "[3/5] Installing binary to $BIN_DST..."
install -d -m 755 /usr/local/libexec
install -m 755 -o root -g wheel "$TMP_BIN" "$BIN_DST"
rm -f "$TMP_BIN"

echo "[4/5] Installing LaunchDaemon plist..."
install -m 644 -o root -g wheel "$PLIST_SRC" "$PLIST_DST"

echo "[5/5] Loading daemon..."
launchctl bootstrap system "$PLIST_DST"
launchctl enable "system/$LABEL"
launchctl kickstart -k "system/$LABEL"

echo "Done. Logs: /var/log/keepalive-helper.log"
echo "Control socket: /var/run/keepalive.sock"
launchctl print "system/$LABEL" | grep -E 'state|pid' | head -4 || true
