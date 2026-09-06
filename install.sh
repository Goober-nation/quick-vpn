#!/usr/bin/env bash
#
# auto-vpn: one-shot installer for a fresh Ubuntu VPS.
# Choose any combination of:
#   - vless   : Xray VLESS + Reality + XHTTP VPN (import into Happ / v2rayTun / v2rayNG / NekoBox)
#   - socks   : Dante SOCKS5 proxy (username/password auth, usable in any browser/app/torrent client)
#
#   curl -fsSL https://raw.githubusercontent.com/<you>/<repo>/main/install.sh | bash
#
# Non-interactive selection (skips the prompt, e.g. for automation):
#   COMPONENTS=vless,socks curl -fsSL ... | bash
#   COMPONENTS=vless       curl -fsSL ... | bash
#   COMPONENTS=socks       curl -fsSL ... | bash

set -euo pipefail

# ---------------------------------------------------------------------------
# Config (override via env vars before piping into bash)
# ---------------------------------------------------------------------------
PORT="${PORT:-10000}"                 # VLESS inbound port
SNI="${SNI:-dzen.ru}"                 # Reality camouflage domain
XHTTP_PATH="${XHTTP_PATH:-/xstream}"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
SUB_DIR="/var/www/html"
SUB_FILE="${SUB_DIR}/sub.json"

SOCKS_PORT="${SOCKS_PORT:-1080}"
SOCKS_USER="${SOCKS_USER:-user$(( RANDOM % 9000 + 1000 ))}"
SOCKS_PASS="${SOCKS_PASS:-$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)}"

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$1"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$1" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run this as root (sudo -i, then re-run)."
command -v systemctl >/dev/null || die "systemd required."

# ---------------------------------------------------------------------------
# 0. Component selection
# ---------------------------------------------------------------------------
WANT_VLESS=0
WANT_SOCKS=0

if [[ -n "${COMPONENTS:-}" ]]; then
  IFS=',' read -ra _parts <<< "$COMPONENTS"
  for p in "${_parts[@]}"; do
    case "$(echo "$p" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')" in
      vless) WANT_VLESS=1 ;;
      socks) WANT_SOCKS=1 ;;
      *) warn "Unknown component '$p' in COMPONENTS, ignoring." ;;
    esac
  done
elif [[ -r /dev/tty ]]; then
  echo "Select what to install:"
  echo "  1) VLESS + Xray + XHTTP VPN only"
  echo "  2) Dante SOCKS5 proxy only"
  echo "  3) Both"
  read -rp "Enter choice [3]: " choice </dev/tty
  case "${choice:-3}" in
    1) WANT_VLESS=1 ;;
    2) WANT_SOCKS=1 ;;
    3|"") WANT_VLESS=1; WANT_SOCKS=1 ;;
    *) die "Invalid choice." ;;
  esac
else
  warn "No TTY and no COMPONENTS set — defaulting to both (vless,socks)."
  WANT_VLESS=1
  WANT_SOCKS=1
fi

(( WANT_VLESS || WANT_SOCKS )) || die "Nothing selected, exiting."

# ---------------------------------------------------------------------------
# 1. Base packages
# ---------------------------------------------------------------------------
log "Updating apt and installing prerequisites..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl jq uuid-runtime ufw ca-certificates openssl >/dev/null

# Public IP (used by both components). Override with SERVER_IP=... (e.g. for
# LAN/docker testing where there is no real public IP to auto-detect).
if [[ -z "${SERVER_IP:-}" ]]; then
  SERVER_IP="$(curl -fsSL4 https://api.ipify.org || curl -fsSL https://ifconfig.me)"
fi
[[ -n "$SERVER_IP" ]] || die "Could not determine public IP (set SERVER_IP=... to override)."

log "Ensuring firewall (ufw) is active..."
ufw allow 22/tcp >/dev/null 2>&1 || true
if ufw status | grep -q "Status: inactive"; then
  ufw --force enable >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# VLESS + Xray + XHTTP
# ---------------------------------------------------------------------------
install_vless() {
  log "=== Installing VLESS + Xray + XHTTP ==="

  if ! command -v xray >/dev/null 2>&1; then
    log "Installing Xray-core..."
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
  else
    log "Xray already installed, skipping."
  fi

  log "Generating credentials..."
  CLIENT_UUID="$(xray uuid)"
  # Xray's x25519 label format has changed across versions
  # ("Private key:"/"Public key:" vs "PrivateKey:"/"Password (PublicKey):"),
  # so grab the last whitespace-separated field on the matching line either way.
  KEY_OUTPUT="$(xray x25519)"
  PRIVATE_KEY="$(echo "$KEY_OUTPUT" | grep -i '^Private' | awk '{print $NF}')"
  PUBLIC_KEY="$(echo "$KEY_OUTPUT" | grep -iE '^Public|PublicKey' | awk '{print $NF}')"
  [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] || die "Could not parse keys from 'xray x25519' output:
$KEY_OUTPUT"
  SHORT_ID="$(openssl rand -hex 8)"

  log "Writing Xray config to ${XRAY_CONFIG}..."
  mkdir -p "$(dirname "$XRAY_CONFIG")"
  cat > "$XRAY_CONFIG" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "tag": "xhttp-in",
      "settings": {
        "clients": [
          { "id": "${CLIENT_UUID}", "flow": "" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "dest": "${SNI}:443",
          "serverNames": ["${SNI}", "www.${SNI}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
        },
        "xhttpSettings": {
          "path": "${XHTTP_PATH}"
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF

  xray run -test -config "$XRAY_CONFIG" || die "Generated Xray config failed validation."

  log "Opening firewall port ${PORT}/tcp..."
  ufw allow "${PORT}/tcp" >/dev/null 2>&1 || true

  log "Enabling and starting xray service..."
  systemctl enable xray >/dev/null 2>&1
  systemctl restart xray
  sleep 1
  systemctl is-active --quiet xray || die "xray failed to start — check 'journalctl -u xray -e'."

  urlencode_path() {
    python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$1" 2>/dev/null || echo "${1//\//%2F}"
  }
  local enc_path
  enc_path="$(urlencode_path "$XHTTP_PATH")"

  LINK_STREAM_ONE="$(printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=xhttp&mode=stream-one&path=%s#XHTTP-Stream-One\n' \
    "$CLIENT_UUID" "$SERVER_IP" "$PORT" "$SNI" "$PUBLIC_KEY" "$SHORT_ID" "$enc_path")"
  LINK_PACKET_UP="$(printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=xhttp&mode=packet-up&path=%s#XHTTP-Packet-Up\n' \
    "$CLIENT_UUID" "$SERVER_IP" "$PORT" "$SNI" "$PUBLIC_KEY" "$SHORT_ID" "$enc_path")"

  if [[ -d "$SUB_DIR" ]]; then
    log "Writing subscription file to ${SUB_FILE}..."
    { printf '%s\n%s\n' "$LINK_STREAM_ONE" "$LINK_PACKET_UP"; } | base64 -w0 > "$SUB_FILE" 2>/dev/null || \
    { printf '%s\n%s\n' "$LINK_STREAM_ONE" "$LINK_PACKET_UP"; } | base64 > "$SUB_FILE"
  fi
}

# ---------------------------------------------------------------------------
# Dante SOCKS5 proxy
# ---------------------------------------------------------------------------
install_socks() {
  log "=== Installing Dante SOCKS5 proxy ==="

  apt-get install -y -qq dante-server >/dev/null

  local iface
  iface="$(ip route show default | awk '/default/{print $5; exit}')"
  [[ -n "$iface" ]] || iface="eth0"

  log "Writing /etc/danted.conf (external interface: ${iface})..."
  cat > /etc/danted.conf <<EOF
logoutput: syslog

internal: 0.0.0.0 port = ${SOCKS_PORT}
external: ${iface}

clientmethod: none
socksmethod: username

user.privileged: root
user.libwrap: root
user.notprivileged: nobody

client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error
}

socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    command: bind connect udpassociate
    log: error
    socksmethod: username
}
EOF

  if ! id "$SOCKS_USER" &>/dev/null; then
    log "Creating system user '${SOCKS_USER}' for SOCKS auth..."
    useradd -M -N -s /usr/sbin/nologin "$SOCKS_USER"
  fi
  echo "${SOCKS_USER}:${SOCKS_PASS}" | chpasswd

  log "Opening firewall port ${SOCKS_PORT}/tcp..."
  ufw allow "${SOCKS_PORT}/tcp" >/dev/null 2>&1 || true

  log "Enabling and starting danted service..."
  systemctl enable danted >/dev/null 2>&1
  systemctl restart danted
  sleep 1
  systemctl is-active --quiet danted || die "danted failed to start — check 'journalctl -u danted -e'."
}

# ---------------------------------------------------------------------------
# Run selected installs
# ---------------------------------------------------------------------------
(( WANT_VLESS )) && install_vless
(( WANT_SOCKS )) && install_socks

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "========================================================================"
echo "  Setup complete on ${SERVER_IP}"
echo "========================================================================"

if (( WANT_VLESS )); then
  cat <<SUMMARY

--- VLESS + Reality + XHTTP VPN ---
Import either link into Happ, v2rayTun, v2rayNG, or NekoBox:

  ${LINK_STREAM_ONE}

  ${LINK_PACKET_UP}

Config file: ${XRAY_CONFIG}
$( [[ -f "$SUB_FILE" ]] && echo "Subscription (base64): http://${SERVER_IP}/sub.json" )

UUID:        ${CLIENT_UUID}
Public key:  ${PUBLIC_KEY}
Short ID:    ${SHORT_ID}
SNI:         ${SNI}

Manage with: systemctl {status,restart,stop} xray
SUMMARY
fi

if (( WANT_SOCKS )); then
  cat <<SUMMARY

--- SOCKS5 Proxy ---
Host:      ${SERVER_IP}
Port:      ${SOCKS_PORT}
Username:  ${SOCKS_USER}
Password:  ${SOCKS_PASS}

Use in a browser/app SOCKS5 setting, or test from a shell with:
  curl -x socks5h://${SOCKS_USER}:${SOCKS_PASS}@${SERVER_IP}:${SOCKS_PORT} https://ifconfig.me

Manage with: systemctl {status,restart,stop} danted
SUMMARY
fi

echo "========================================================================"
