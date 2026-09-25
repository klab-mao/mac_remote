#!/bin/bash
# install_service.sh — install mac_remote_host as a macOS launchd service.
#
# Installs a per-user LaunchAgent (not a system LaunchDaemon) on purpose:
# ScreenCaptureKit can only capture the screen from inside a logged-in GUI
# session, and TCC permissions (Screen Recording / Accessibility) are granted
# per user. The host starts automatically at login and is restarted by launchd
# if it crashes (KeepAlive).
#
# Usage:
#   scripts/install_service.sh [--port N] [--fps N] [--bitrate N]
#                              [--display N] [--client-timeout S] [--binary PATH]
#
# Re-running the script replaces the existing service with the new settings.
# Remove everything with scripts/uninstall_service.sh.

set -euo pipefail

LABEL="com.mac_remote.host"
INSTALL_DIR="${MAC_REMOTE_INSTALL_DIR:-$HOME/Library/Application Support/mac_remote}"
BIN_DIR="$INSTALL_DIR/bin"
BIN_PATH="$BIN_DIR/mac_remote_host"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST="$PLIST_DIR/$LABEL.plist"
LOG_FILE="$INSTALL_DIR/host.log"
LAUNCH_DOMAIN="gui/$(id -u)"

PORT=42420
FPS=60
BITRATE=25
DISPLAY=0
CLIENT_TIMEOUT=10
BINARY=""

usage() {
    cat <<'USAGE'
usage: scripts/install_service.sh [flags]

flags (same meaning as mac_remote_host's own flags):
  --port N            UDP port                    (default 42420)
  --fps N             capture/encode framerate    (default 60)
  --bitrate N         H.264 bitrate in Mbps       (default 25)
  --display N         initial display index       (default 0)
  --client-timeout S  client inactivity timeout   (default 10)
  --binary PATH       use this prebuilt mac_remote_host instead of building

environment:
  MAC_REMOTE_INSTALL_DIR  where the binary and logs are installed
                          (default: $HOME/Library/Application Support/mac_remote)
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --port|--fps|--bitrate|--display|--client-timeout|--binary)
            if [ $# -lt 2 ]; then
                echo "error: $1 requires a value" >&2
                exit 1
            fi
            ;;
    esac
    case "$1" in
        --port)            PORT="$2" ;;
        --fps)             FPS="$2" ;;
        --bitrate)         BITRATE="$2" ;;
        --display)         DISPLAY="$2" ;;
        --client-timeout)  CLIENT_TIMEOUT="$2" ;;
        --binary)          BINARY="$2" ;;
        -h|--help)         usage; exit 0 ;;
        *) echo "error: unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
    shift 2
done

if [ "$(id -u)" -eq 0 ]; then
    echo "error: do not run with sudo — this installs a per-user LaunchAgent" >&2
    exit 1
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

find_built_binary() {
    local p
    for p in \
        "$repo_root/.build/apple/Products/Release/mac_remote_host" \
        "$repo_root/.build/out/Products/Release/mac_remote_host" \
        "$repo_root/.build/release/mac_remote_host" \
        "$repo_root/.build/apple/Products/Debug/mac_remote_host" \
        "$repo_root/.build/out/Products/Debug/mac_remote_host" \
        "$repo_root/.build/debug/mac_remote_host"; do
        if [ -x "$p" ]; then
            echo "$p"
            return 0
        fi
    done
    # Fallback for other layouts: any copy under .build, Release preferred.
    while IFS= read -r p; do
        [ -x "$p" ] || continue
        case "$p" in
            *[Rr]elease*) echo "$p"; return 0 ;;
        esac
    done < <(find "$repo_root/.build" -type f -name mac_remote_host 2>/dev/null)
    while IFS= read -r p; do
        if [ -x "$p" ]; then
            echo "$p"
            return 0
        fi
    done < <(find "$repo_root/.build" -type f -name mac_remote_host 2>/dev/null)
    return 1
}

xml_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# ---- locate or build the host binary ---------------------------------------

SRC_BIN="$BINARY"
if [ -n "$SRC_BIN" ] && [ ! -x "$SRC_BIN" ]; then
    echo "error: --binary path is not executable: $SRC_BIN" >&2
    exit 1
fi

if [ -z "$SRC_BIN" ]; then
    SRC_BIN="$(find_built_binary || true)"
fi

if [ -z "$SRC_BIN" ]; then
    echo "==> No prebuilt binary found — building universal Release binary"
    (cd "$repo_root" && swift build -c release --arch arm64 --arch x86_64)
    SRC_BIN="$(find_built_binary || true)"
fi

if [ -z "$SRC_BIN" ]; then
    echo "error: build finished but no mac_remote_host found under $repo_root/.build" >&2
    exit 1
fi

echo "==> Host binary: $SRC_BIN"

# ---- stop previous installation ---------------------------------------------

if launchctl print "$LAUNCH_DOMAIN/$LABEL" >/dev/null 2>&1; then
    echo "==> Stopping existing service"
    launchctl bootout "$LAUNCH_DOMAIN" "$PLIST" 2>/dev/null \
        || launchctl bootout "$LAUNCH_DOMAIN/$LABEL" 2>/dev/null \
        || true
fi

# ---- install binary + plist ---------------------------------------------------

mkdir -p "$BIN_DIR" "$PLIST_DIR"

echo "==> Installing binary to $BIN_PATH"
cp "$SRC_BIN" "$BIN_PATH"
chmod +x "$BIN_PATH"

echo "==> Writing $PLIST"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$(xml_escape "$BIN_PATH")</string>
		<string>--port</string>
		<string>$PORT</string>
		<string>--fps</string>
		<string>$FPS</string>
		<string>--bitrate</string>
		<string>$BITRATE</string>
		<string>--display</string>
		<string>$DISPLAY</string>
		<string>--client-timeout</string>
		<string>$CLIENT_TIMEOUT</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>StandardOutPath</key>
	<string>$(xml_escape "$LOG_FILE")</string>
	<key>StandardErrorPath</key>
	<string>$(xml_escape "$LOG_FILE")</string>
</dict>
</plist>
EOF

plutil -lint "$PLIST"

# ---- load ----------------------------------------------------------------------

echo "==> Loading service"
launchctl bootstrap "$LAUNCH_DOMAIN" "$PLIST"
launchctl enable "$LAUNCH_DOMAIN/$LABEL"

echo
echo "Installed:  $LABEL  (starts at login, restarts on crash)"
echo "Binary:     $BIN_PATH"
echo "Log:        $LOG_FILE"
echo
echo "  status :  launchctl list $LABEL"
echo "  restart:  launchctl kickstart -k $LAUNCH_DOMAIN/$LABEL"
echo "  stop   :  launchctl bootout $LAUNCH_DOMAIN \"$PLIST\""
echo "  logs   :  tail -f \"$LOG_FILE\""
echo
echo "IMPORTANT — permissions are granted per binary path. If not already granted"
echo "for the installed copy:"
echo "  1. System Settings > Privacy & Security > Screen Recording -> add $BIN_PATH"
echo "  2. System Settings > Privacy & Security > Accessibility    -> add $BIN_PATH"
echo "  3. launchctl kickstart -k $LAUNCH_DOMAIN/$LABEL"
echo "The log then prints 'Screen Recording permission: GRANTED' and"
echo "'Accessibility permission: GRANTED'."
