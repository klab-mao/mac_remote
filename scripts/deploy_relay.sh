#!/bin/bash
# deploy_relay.sh — build relayd for Linux, deploy to remote server, set up systemd.
#
# Usage:
#   scripts/deploy_relay.sh [ssh-host] [remote-dir] [flags...]
#
# Defaults:
#   ssh-host   = qianfeng
#   remote-dir = ~/tools/mac_remote
#
# Flags:
#   --control-port N    TCP control port        (default 42430)
#   --udp-port N        UDP data port           (default 42431)
#   --arch ARCH         Target arch (amd64|arm64|both)  (default both)
#   --accounts FILE     Local accounts.json to upload (default: generate if missing)
#   --restart           Restart service after deploy (default: yes)
#   --no-restart        Don't restart service
#
# Examples:
#   scripts/deploy_relay.sh
#   scripts/deploy_relay.sh qianfeng ~/tools/mac_remote
#   scripts/deploy_relay.sh myserver ~/relay --control-port 4430 --udp-port 4431

set -euo pipefail

SSH_HOST="${1:-qianfeng}"
REMOTE_DIR="${2:-~/tools/mac_remote}"
shift 2 2>/dev/null || true

CONTROL_PORT=42430
UDP_PORT=42431
ARCH="both"
ACCOUNTS_FILE=""
RESTART=true

while [ $# -gt 0 ]; do
    case "$1" in
        --control-port) CONTROL_PORT="$2"; shift 2 ;;
        --udp-port)     UDP_PORT="$2"; shift 2 ;;
        --arch)         ARCH="$2"; shift 2 ;;
        --accounts)     ACCOUNTS_FILE="$2"; shift 2 ;;
        --restart)      RESTART=true; shift ;;
        --no-restart)   RESTART=false; shift ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# //; s/^#//'
            exit 0
            ;;
        *) echo "error: unknown option: $1" >&2; exit 1 ;;
    esac
done

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
RELAYD_DIR="$repo_root/relayd"
LABEL="relayd"
SERVICE_FILE="/etc/systemd/system/${LABEL}.service"

echo "==> Deploy relayd to ${SSH_HOST}:${REMOTE_DIR}"
echo "    control: tcp/${CONTROL_PORT}, data: udp/${UDP_PORT}, arch: ${ARCH}"

# ---- build --------------------------------------------------------------------

echo "==> Building relayd for Linux"
cd "$RELAYD_DIR"

build_one() {
    local goarch="$1"
    local out="relayd-linux-${goarch}"
    echo "    GOOS=linux GOARCH=${goarch}"
    GOOS=linux GOARCH="$goarch" CGO_ENABLED=0 go build -o "$out" .
}

case "$ARCH" in
    amd64) build_one amd64 ;;
    arm64) build_one arm64 ;;
    both)  build_one amd64; build_one arm64 ;;
    *)     echo "error: --arch must be amd64, arm64, or both" >&2; exit 1 ;;
esac

# Detect remote arch and pick the right binary
echo "==> Detecting remote architecture"
REMOTE_ARCH=$(ssh "$SSH_HOST" "uname -m" 2>/dev/null | tr -d '[:space:]')
case "$REMOTE_ARCH" in
    x86_64|amd64)  BIN_ARCH="amd64" ;;
    aarch64|arm64) BIN_ARCH="arm64" ;;
    *) echo "    WARNING: unexpected arch '${REMOTE_ARCH}', defaulting to amd64"; BIN_ARCH="amd64" ;;
esac
echo "    Remote arch: ${REMOTE_ARCH} → using relayd-linux-${BIN_ARCH}"

BIN_LOCAL="$RELAYD_DIR/relayd-linux-${BIN_ARCH}"
if [ ! -f "$BIN_LOCAL" ]; then
    echo "error: binary not found: $BIN_LOCAL" >&2
    exit 1
fi

# ---- upload binary ------------------------------------------------------------

echo "==> Uploading relayd to ${SSH_HOST}:${REMOTE_DIR}/"
ssh "$SSH_HOST" "mkdir -p ${REMOTE_DIR}"
scp "$BIN_LOCAL" "${SSH_HOST}:${REMOTE_DIR}/relayd"
ssh "$SSH_HOST" "chmod +x ${REMOTE_DIR}/relayd"

# ---- accounts.json ------------------------------------------------------------

if [ -n "$ACCOUNTS_FILE" ]; then
    echo "==> Uploading accounts.json from ${ACCOUNTS_FILE}"
    scp "$ACCOUNTS_FILE" "${SSH_HOST}:${REMOTE_DIR}/accounts.json"
else
    echo "==> Checking for existing accounts.json on remote"
    if ! ssh "$SSH_HOST" "test -f ${REMOTE_DIR}/accounts.json" 2>/dev/null; then
        echo "    No accounts.json found — generating default"
        read -rp "    Host device-id (e.g. office-mac): " DEV_ID
        DEV_ID="${DEV_ID:-office-mac}"
        read -rp "    Host password: " DEV_PW
        read -rp "    Viewer username (e.g. alice): " USER_NAME
        USER_NAME="${USER_NAME:-alice}"
        read -rp "    Viewer password: " USER_PW

        ACCOUNTS_TEMP=$(mktemp)
        cat > "$ACCOUNTS_TEMP" <<EOF
{
  "users": { "${USER_NAME}": "${USER_PW}" },
  "hosts": { "${DEV_ID}": "${DEV_PW}" }
}
EOF
        scp "$ACCOUNTS_TEMP" "${SSH_HOST}:${REMOTE_DIR}/accounts.json"
        rm -f "$ACCOUNTS_TEMP"
        echo "    accounts.json uploaded"
    else
        echo "    accounts.json already exists — keeping it"
    fi
fi
ssh "$SSH_HOST" "chmod 600 ${REMOTE_DIR}/accounts.json 2>/dev/null || true"

# ---- systemd service ----------------------------------------------------------

echo "==> Installing systemd service"

# Resolve remote home dir and user for absolute paths in systemd unit
REMOTE_HOME=$(ssh "$SSH_HOST" 'echo $HOME')
REMOTE_USER=$(ssh "$SSH_HOST" 'whoami')
# Expand ~ in* in REMOTE_DIR to absolute path
REMOTE_DIR_ABS="${REMOTE_DIR/#\~/$REMOTE_HOME}"

ssh "$SSH_HOST" "sudo tee ${SERVICE_FILE} >/dev/null" <<EOF
[Unit]
Description=mac_remote relay server
After=network.target

[Service]
ExecStart=${REMOTE_DIR_ABS}/relayd -control ${CONTROL_PORT} -udp ${UDP_PORT} -config ${REMOTE_DIR_ABS}/accounts.json
Restart=always
RestartSec=3
User=${REMOTE_USER}
WorkingDirectory=${REMOTE_DIR_ABS}

[Install]
WantedBy=multi-user.target
EOF

ssh "$SSH_HOST" "sudo systemctl daemon-reload && sudo systemctl enable ${LABEL}"

# ---- firewall -----------------------------------------------------------------

echo "==> Opening firewall (tcp/${CONTROL_PORT} + udp/${UDP_PORT})"
ssh "$SSH_HOST" "sudo ufw allow ${CONTROL_PORT}/tcp 2>/dev/null; sudo ufw allow ${UDP_PORT}/udp 2>/dev/null; true" 2>/dev/null || true

# ---- restart ------------------------------------------------------------------

if [ "$RESTART" = true ]; then
    echo "==> Restarting ${LABEL} service"
    ssh "$SSH_HOST" "sudo systemctl restart ${LABEL}"
    sleep 2
    echo "==> Service status:"
    ssh "$SSH_HOST" "sudo systemctl status ${LABEL} --no-pager -l" 2>/dev/null | head -15
    echo ""
    echo "==> Recent logs:"
    ssh "$SSH_HOST" "sudo journalctl -u ${LABEL} --no-pager -n 5" 2>/dev/null
fi

# ---- cleanup local binaries ---------------------------------------------------

rm -f "$RELAYD_DIR"/relayd-linux-*

echo ""
echo "==> Deploy complete!"
echo "    Server:  ${SSH_HOST}"
echo "    Binary:  ${REMOTE_DIR}/relayd"
echo "    Config:  ${REMOTE_DIR}/accounts.json"
echo "    Service: ${LABEL}"
echo ""
echo "    Relay address: \$(ssh ${SSH_HOST} 'curl -s ifconfig.me'):${CONTROL_PORT}"
echo ""
echo "    Host:    mac_remote_host --relay <addr>:${CONTROL_PORT} --device-id <id>"
echo "    Client:  mac_remote_client --relay <addr>:${CONTROL_PORT} --user <user> --device-id <id>"