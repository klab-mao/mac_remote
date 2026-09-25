#!/bin/bash
# uninstall_service.sh — remove the mac_remote_host launchd service that was
# installed by install_service.sh: stops it, removes the LaunchAgent plist and
# the installed binary + logs.
#
# Usage:
#   scripts/uninstall_service.sh
#
# Set MAC_REMOTE_INSTALL_DIR if you installed to a custom location.
# Screen Recording / Accessibility entries in System Settings (if granted)
# must be removed manually.

set -euo pipefail

LABEL="com.mac_remote.host"
INSTALL_DIR="${MAC_REMOTE_INSTALL_DIR:-$HOME/Library/Application Support/mac_remote}"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LAUNCH_DOMAIN="gui/$(id -u)"

if [ "$(id -u)" -eq 0 ]; then
    echo "error: do not run with sudo — the service is installed per user" >&2
    exit 1
fi

if launchctl print "$LAUNCH_DOMAIN/$LABEL" >/dev/null 2>&1; then
    echo "==> Stopping service $LABEL"
    launchctl bootout "$LAUNCH_DOMAIN" "$PLIST" 2>/dev/null \
        || launchctl bootout "$LAUNCH_DOMAIN/$LABEL" 2>/dev/null \
        || true
else
    echo "==> Service not loaded (nothing to stop)"
fi

if [ -f "$PLIST" ]; then
    echo "==> Removing $PLIST"
    rm -f "$PLIST"
fi

if [ -d "$INSTALL_DIR" ]; then
    if [ -x "$INSTALL_DIR/bin/mac_remote_host" ] || [ "$INSTALL_DIR" = "$HOME/Library/Application Support/mac_remote" ]; then
        echo "==> Removing $INSTALL_DIR (binary + logs)"
        rm -rf "$INSTALL_DIR"
    else
        echo "==> Skipping $INSTALL_DIR (no installed binary found there — refusing to remove an unknown directory)"
    fi
fi

echo
echo "Done — $LABEL uninstalled."
