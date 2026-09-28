#!/bin/bash
# install_service.sh — install or upgrade mac_remote_host as a macOS launchd service.
#
# Supports both LAN mode (direct UDP) and relay mode (cloud relayd).
# Wraps the binary in a .app bundle for reliable TCC permission handling.
#
# Usage (LAN mode):
#   scripts/install_service.sh [--port N] [--fps N] [--bitrate N]
#                              [--display N] [--client-timeout S] [--binary PATH]
#
# Usage (relay mode):
#   scripts/install_service.sh --relay HOST:PORT --device-id NAME
#                              [--password PW] [--fps N] [--bitrate N]
#                              [--display N] [--client-timeout S] [--binary PATH]
#
# If the service is already installed, the script runs in **upgrade** mode:
#   - Settings not specified on the command line are preserved from the existing plist.
#   - The binary is rebuilt (or the --binary path is used) and replaced.
#   - The service is restarted with the merged settings.
# If no service exists, it runs in **install** mode with defaults or provided flags.
# Remove everything with scripts/uninstall_service.sh.

set -euo pipefail

LABEL="com.mac_remote.host"
INSTALL_DIR="${MAC_REMOTE_INSTALL_DIR:-$HOME/Library/Application Support/mac_remote}"
APP_DIR="$INSTALL_DIR/mac_remote_host.app"
APP_BIN="$APP_DIR/Contents/MacOS/mac_remote_host"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST="$PLIST_DIR/$LABEL.plist"
LOG_FILE="$INSTALL_DIR/host.log"
LAUNCH_DOMAIN="gui/$(id -u)"

PORT=""
FPS=""
BITRATE=""
DISPLAY=""
CLIENT_TIMEOUT=""
BINARY=""
RELAY=""
DEVICE_ID=""
PASSWORD=""
CODEC=""

usage() {
    cat <<'USAGE'
usage: scripts/install_service.sh [flags]

LAN mode flags:
  --port N            UDP port                    (default 42420)

Relay mode flags:
  --relay HOST:PORT   relay server address (enables relay mode)
  --device-id NAME    device name registered on relay (required with --relay)
  --password PW       device account password (or $MAC_REMOTE_PASSWORD env var)

Common flags:
  --fps N             capture/encode framerate    (default 60)
  --bitrate N         bitrate in Mbps            (default 40)
  --codec CODEC       h264 or hevc               (default h264)
  --display N         initial display index       (default 0)
  --client-timeout S  client inactivity timeout   (default 10)
  --binary PATH       use this prebuilt binary instead of building

When upgrading an existing installation, flags not specified on the command
line are preserved from the current plist. When installing fresh, defaults
shown above are used.

environment:
  MAC_REMOTE_INSTALL_DIR  where the binary and logs are installed
                          (default: $HOME/Library/Application Support/mac_remote)
  MAC_REMOTE_PASSWORD     relay password (if --password not given)
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --port|--fps|--bitrate|--display|--client-timeout|--binary|--relay|--device-id|--password|--codec)
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
        --relay)           RELAY="$2" ;;
        --device-id)       DEVICE_ID="$2" ;;
        --password)        PASSWORD="$2" ;;
        --codec)           CODEC="$2" ;;
        -h|--help)         usage; exit 0 ;;
        *) echo "error: unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
    shift 2
done

if [ "$(id -u)" -eq 0 ]; then
    echo "error: do not run with sudo — this installs a per-user LaunchAgent" >&2
    exit 1
fi

# Resolve password from env var if not provided
if [ -n "$RELAY" ] && [ -z "$PASSWORD" ] && [ -n "${MAC_REMOTE_PASSWORD:-}" ]; then
    PASSWORD="$MAC_REMOTE_PASSWORD"
fi

# Validate relay args
if [ -n "$RELAY" ] && [ -z "$DEVICE_ID" ]; then
    echo "error: --device-id is required when --relay is given" >&2
    exit 1
fi

# ---- detect install vs upgrade -----------------------------------------------

UPGRADE=false
if [ -f "$PLIST" ]; then
    UPGRADE=true
    echo "==> Upgrade detected — existing plist found at $PLIST"
    echo "    Preserving settings not explicitly overridden:"

    # Read flag values from existing plist by name (robust against arg order changes)
    read_plist_flag() {
        plutil -convert json -o - "$PLIST" 2>/dev/null | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    args = data.get('ProgramArguments', [])
    for i, a in enumerate(args):
        if a == '$1' and i+1 < len(args):
            print(args[i+1])
            break
except: pass
" 2>/dev/null
    }

    [ -z "$PORT" ]           && PORT="$(read_plist_flag --port)"           && [ -n "$PORT" ]           && echo "    --port $PORT"
    [ -z "$FPS" ]            && FPS="$(read_plist_flag --fps)"            && [ -n "$FPS" ]            && echo "    --fps $FPS"
    [ -z "$BITRATE" ]        && BITRATE="$(read_plist_flag --bitrate)"        && [ -n "$BITRATE" ]        && echo "    --bitrate $BITRATE"
    [ -z "$DISPLAY" ]        && DISPLAY="$(read_plist_flag --display)"        && [ -n "$DISPLAY" ]        && echo "    --display $DISPLAY"
    [ -z "$CLIENT_TIMEOUT" ] && CLIENT_TIMEOUT="$(read_plist_flag --client-timeout)" && [ -n "$CLIENT_TIMEOUT" ] && echo "    --client-timeout $CLIENT_TIMEOUT"
    [ -z "$RELAY" ]          && RELAY="$(read_plist_flag --relay)"          && [ -n "$RELAY" ]          && echo "    --relay $RELAY"
    [ -z "$DEVICE_ID" ]      && DEVICE_ID="$(read_plist_flag --device-id)"      && [ -n "$DEVICE_ID" ]      && echo "    --device-id $DEVICE_ID"
    [ -z "$PASSWORD" ]       && PASSWORD="$(read_plist_flag --password)"       && [ -n "$PASSWORD" ]       && echo "    --password (preserved)"
    [ -z "$CODEC" ]          && CODEC="$(read_plist_flag --codec)"             && [ -n "$CODEC" ]          && echo "    --codec $CODEC"
else
    echo "==> Fresh install — no existing plist found"
fi

# ---- fill defaults for anything still unset ----------------------------------

[ -z "$FPS" ]            && FPS=60
[ -z "$BITRATE" ]        && BITRATE=40
[ -z "$CODEC" ]          && CODEC=h264
[ -z "$DISPLAY" ]        && DISPLAY=0
[ -z "$CLIENT_TIMEOUT" ] && CLIENT_TIMEOUT=10
# LAN mode default port (only used if not relay)
[ -z "$PORT" ]           && PORT=42420

IS_RELAY=false
if [ -n "$RELAY" ]; then
    IS_RELAY=true
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
    echo "==> No prebuilt binary found — building universal (arm64+x86_64) Release binary"
    if ! (cd "$repo_root" && swift build -c release --arch arm64 --arch x86_64); then
        echo "==> Universal build failed (it needs full Xcode) — building native-arch Release binary" >&2
        (cd "$repo_root" && swift build -c release)
    fi
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

# ---- install .app bundle + plist --------------------------------------------

mkdir -p "$APP_DIR/Contents/MacOS" "$PLIST_DIR"

echo "==> Installing .app bundle to $APP_DIR"
cp "$SRC_BIN" "$APP_BIN"
chmod +x "$APP_BIN"

cat > "$APP_DIR/Contents/Info.plist" << 'INFOEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.mac_remote.host</string>
	<key>CFBundleExecutable</key>
	<string>mac_remote_host</string>
	<key>CFBundleName</key>
	<string>mac_remote_host</string>
	<key>CFBundleVersion</key>
	<string>1.0</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
INFOEOF

# ---- codesign (stable identity for TCC permissions) ---------------------------
# Use an Apple Development certificate if available; fall back to adhoc with
# a stable identifier so TCC permissions survive across rebuilds.

SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="$(security find-identity -p codesigning -v 2>/dev/null \
        | grep 'Apple Development' \
        | head -1 \
        | sed 's/^[[:space:]]*[0-9]*) \([A-Fa-f0-9]*\) .*/\1/' || true)"
fi

if [ -n "$SIGN_IDENTITY" ]; then
    echo "==> Code signing .app bundle with: $SIGN_IDENTITY"
    security unlock-keychain -p "" "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null || true
    if codesign --force --timestamp=none --sign "$SIGN_IDENTITY" --identifier "$LABEL" "$APP_DIR" 2>&1; then
        echo "    Signed successfully"
    else
        echo "    WARNING: signing failed — falling back to adhoc" >&2
        codesign --force --sign - --identifier "$LABEL" "$APP_DIR" 2>/dev/null || true
    fi
else
    echo "==> WARNING: no Apple Development certificate found — using adhoc signing" >&2
    echo "    TCC permissions (Screen Recording/Accessibility) may not persist" >&2
    codesign --force --sign - --identifier "$LABEL" "$APP_DIR" 2>/dev/null || true
fi

# ---- build ProgramArguments -------------------------------------------------

echo "==> Writing $PLIST"

ARGS=""
if [ "$IS_RELAY" = true ]; then
    ARGS+="		<string>--relay</string>\n"
    ARGS+="		<string>$(xml_escape "$RELAY")</string>\n"
    ARGS+="		<string>--device-id</string>\n"
    ARGS+="		<string>$(xml_escape "$DEVICE_ID")</string>\n"
    if [ -n "$PASSWORD" ]; then
        ARGS+="		<string>--password</string>\n"
        ARGS+="		<string>$(xml_escape "$PASSWORD")</string>\n"
    fi
else
    ARGS+="		<string>--port</string>\n"
    ARGS+="		<string>$PORT</string>\n"
fi
ARGS+="		<string>--fps</string>\n"
ARGS+="		<string>$FPS</string>\n"
ARGS+="		<string>--bitrate</string>\n"
ARGS+="		<string>$BITRATE</string>\n"
ARGS+="		<string>--codec</string>\n"
ARGS+="		<string>$CODEC</string>\n"
ARGS+="		<string>--display</string>\n"
ARGS+="		<string>$DISPLAY</string>\n"
ARGS+="		<string>--client-timeout</string>\n"
ARGS+="		<string>$CLIENT_TIMEOUT</string>\n"

printf '%s\n' \
"<?xml version=\"1.0\" encoding=\"UTF-8\"?>" \
"<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">" \
"<plist version=\"1.0\">" \
"<dict>" \
"	<key>Label</key>" \
"	<string>$LABEL</string>" \
"	<key>ProgramArguments</key>" \
"	<array>" \
"		<string>$(xml_escape "$APP_BIN")</string>" \
"$(printf "$ARGS")" \
"	</array>" \
"	<key>RunAtLoad</key>" \
"	<true/>" \
"	<key>KeepAlive</key>" \
"	<true/>" \
"	<key>StandardOutPath</key>" \
"	<string>$(xml_escape "$LOG_FILE")</string>" \
"	<key>StandardErrorPath</key>" \
"	<string>$(xml_escape "$LOG_FILE")</string>" \
"</dict>" \
"</plist>" > "$PLIST"

plutil -lint "$PLIST"

# ---- load ----------------------------------------------------------------------

echo "==> Loading service"
launchctl bootstrap "$LAUNCH_DOMAIN" "$PLIST"
launchctl enable "$LAUNCH_DOMAIN/$LABEL"

echo
if [ "$UPGRADE" = true ]; then
    echo "Upgraded:  $LABEL  (starts at login, restarts on crash)"
else
    echo "Installed:  $LABEL  (starts at login, restarts on crash)"
fi
echo "Binary:     $APP_BIN"
echo "Log:        $LOG_FILE"
if [ "$IS_RELAY" = true ]; then
    echo "Mode:       relay ($RELAY, device=$DEVICE_ID)"
else
    echo "Mode:       LAN (UDP port $PORT)"
fi
echo
echo "  status :  launchctl list $LABEL"
echo "  restart:  launchctl kickstart -k $LAUNCH_DOMAIN/$LABEL"
echo "  stop   :  launchctl bootout $LAUNCH_DOMAIN \"$PLIST\""
echo "  logs   :  tail -f \"$LOG_FILE\""
echo
if [ "$UPGRADE" = true ]; then
    echo "Binary updated — re-signed with stable identifier, TCC permissions preserved."
    echo "If permissions show NOT GRANTED, toggle OFF→ON in System Settings."
else
    echo "IMPORTANT — TCC permissions are granted per .app bundle. Grant in:"
    echo "  1. System Settings > Privacy & Security > Screen Recording -> add $APP_DIR"
    echo "  2. System Settings > Privacy & Security > Accessibility    -> add $APP_DIR"
    echo "  3. launchctl kickstart -k $LAUNCH_DOMAIN/$LABEL"
    echo "The log then prints 'Screen Recording permission: GRANTED' and"
    echo "'Accessibility permission: GRANTED'."
    echo ""
    echo "If permissions were granted to a previous build and now show NOT GRANTED"
    echo "(stale TCC cache), reboot the Mac to flush the cache."
fi
