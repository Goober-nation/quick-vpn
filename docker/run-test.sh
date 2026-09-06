#!/usr/bin/env bash
#
# Local end-to-end test: builds a systemd "vps" container, runs the real
# install.sh inside it (both components), then from a separate "client"
# container proves both paths actually carry traffic:
#   - SOCKS5 (dante) via a plain curl -x socks5h://user:pass@vps:1080
#   - VLESS+Reality+XHTTP via a real xray client config built from the
#     vless:// link the script prints, tunneled through a local SOCKS inbound
#
# Usage: ./docker/run-test.sh [--keep] [--ipv6]
#   --keep   leave the containers running afterwards for manual poking
#   --ipv6   address the vps over its IPv6 address instead of its hostname,
#            exercising the dual-stack listen/link-bracketing code paths

set -euo pipefail
cd "$(dirname "$0")/.."

COMPOSE="docker compose -f docker/docker-compose.test.yml"
KEEP=0
USE_IPV6=0
for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=1 ;;
    --ipv6) USE_IPV6=1 ;;
  esac
done

SOCKS_USER="testuser"
SOCKS_PASS="testpass123"

pass=0
fail=0
ok()   { printf '\033[1;32m  PASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '\033[1;31m  FAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
step() { printf '\033[1;36m==> %s\033[0m\n' "$1"; }

cleanup() {
  if [[ $KEEP -eq 0 ]]; then
    step "Tearing down containers"
    $COMPOSE down -v --remove-orphans >/dev/null 2>&1 || true
  else
    echo "Containers left running (--keep). Tear down with: $COMPOSE down -v"
  fi
}
trap cleanup EXIT

step "Building images"
$COMPOSE build

step "Starting vps (systemd) and client containers"
$COMPOSE up -d

step "Waiting for systemd inside vps to be ready"
for i in $(seq 1 30); do
  if $COMPOSE exec -T vps systemctl is-system-running --wait &>/dev/null; then break; fi
  sleep 1
done

VPS_ADDR="vps"
if [[ $USE_IPV6 -eq 1 ]]; then
  step "Resolving vps's IPv6 address on the docker network"
  VPS_ADDR="$(docker inspect auto-vpn-test-vps --format '{{range .NetworkSettings.Networks}}{{.GlobalIPv6Address}}{{end}}')"
  [[ -n "$VPS_ADDR" ]] || { echo "Could not find an IPv6 address for vps — check enable_ipv6 in docker-compose.test.yml"; exit 1; }
  echo "  vps IPv6 address: ${VPS_ADDR}"
fi

step "Running install.sh inside vps (COMPONENTS=vless,socks, SERVER_IP=${VPS_ADDR})"
INSTALL_LOG="$(mktemp)"
$COMPOSE exec -T vps bash -c "
  SERVER_IP='${VPS_ADDR}' ALLOW_PRIVATE_IP=1 COMPONENTS=vless,socks SOCKS_USER=${SOCKS_USER} SOCKS_PASS=${SOCKS_PASS} /root/install.sh
" | tee "$INSTALL_LOG"

echo
step "Checking systemd services on vps"
if $COMPOSE exec -T vps systemctl is-active --quiet xray; then
  ok "xray.service is active"
else
  bad "xray.service is NOT active"
fi

if $COMPOSE exec -T vps systemctl is-active --quiet danted; then
  ok "danted.service is active"
else
  bad "danted.service is NOT active"
fi

# For the SOCKS5/curl reachability checks, addressing the vps container is
# only interesting over its hostname or IPv4 (curl to a bare link-local-ish
# ULA over docker's bridge works fine too) — reuse VPS_ADDR either way, but
# curl needs brackets around a literal IPv6 host in a URL.
CURL_HOST="$VPS_ADDR"
if [[ $USE_IPV6 -eq 1 ]]; then
  CURL_HOST="[${VPS_ADDR}]"
fi

# Force -4 in the default (non --ipv6) run: enabling IPv6 on the docker
# network makes "vps" resolve to an AAAA record too, and that address isn't
# NAT'd to the real internet without extra host config, unlike the IPv4 one.
IP_FLAG="-4"
[[ $USE_IPV6 -eq 1 ]] && IP_FLAG="-6"

step "Testing SOCKS5 proxy from client container"
if $COMPOSE exec -T client curl -s "$IP_FLAG" --max-time 8 -x "socks5h://${SOCKS_USER}:${SOCKS_PASS}@${CURL_HOST}:1080" -o /dev/null -w '%{http_code}' https://ifconfig.me | grep -q 200; then
  ok "SOCKS5 proxy relays traffic (authenticated) through vps"
else
  bad "SOCKS5 proxy did not relay traffic"
fi

step "Confirming SOCKS5 rejects bad credentials"
if $COMPOSE exec -T client curl -s "$IP_FLAG" --max-time 8 -x "socks5h://wrong:creds@${CURL_HOST}:1080" -o /dev/null https://ifconfig.me; then
  bad "SOCKS5 accepted invalid credentials (should have failed)"
else
  ok "SOCKS5 correctly rejects invalid credentials"
fi

step "Parsing the printed vless:// link to build a client Xray config"
LINK="$(grep -m1 -o 'vless://.*' "$INSTALL_LOG" || true)"
if [[ -z "$LINK" ]]; then
  bad "Could not find a vless:// link in install.sh output"
else
  # vless://UUID@HOST:PORT?query#tag  (HOST is [bracketed] when it's IPv6)
  body="${LINK#vless://}"
  UUID="${body%%@*}"
  rest="${body#*@}"
  hostport="${rest%%\?*}"
  if [[ "$hostport" == \[*\]:* ]]; then
    HOST="${hostport#\[}"
    HOST="${HOST%%\]:*}"
    PORT="${hostport##*\]:}"
  else
    HOST="${hostport%%:*}"
    PORT="${hostport##*:}"
  fi
  query="${rest#*\?}"
  query="${query%%#*}"

  get_param() { echo "$query" | tr '&' '\n' | awk -F= -v k="$1" '$1==k{print $2}'; }
  PBK="$(get_param pbk)"
  SID="$(get_param sid)"
  SNI="$(get_param sni)"
  PATHRAW="$(get_param path)"
  XPATH="$(python3 -c "import urllib.parse,sys;print(urllib.parse.unquote(sys.argv[1]))" "$PATHRAW" 2>/dev/null || echo "$PATHRAW")"

  if [[ $USE_IPV6 -eq 1 && "$HOST" != "$VPS_ADDR" ]]; then
    bad "Link host '${HOST}' did not match expected IPv6 address '${VPS_ADDR}' (bracket parsing/bug?)"
  fi

  CLIENT_CFG="$(mktemp)"
  cat > "$CLIENT_CFG" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    { "listen": "127.0.0.1", "port": 10808, "protocol": "socks", "settings": { "udp": true } }
  ],
  "outbounds": [
    {
      "protocol": "vless",
      "settings": {
        "vnext": [
          { "address": "${HOST}", "port": ${PORT}, "users": [ { "id": "${UUID}", "encryption": "none" } ] }
        ]
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": { "serverName": "${SNI}", "publicKey": "${PBK}", "shortId": "${SID}", "fingerprint": "chrome" },
        "xhttpSettings": { "path": "${XPATH}", "mode": "stream-one" }
      }
    }
  ]
}
EOF

  docker cp "$CLIENT_CFG" auto-vpn-test-client:/tmp/client.json
  $COMPOSE exec -T client bash -c "pkill xray 2>/dev/null; nohup xray run -c /tmp/client.json >/tmp/xray-client.log 2>&1 & sleep 2"

  step "Testing VLESS tunnel from client container"
  if $COMPOSE exec -T client curl -s --max-time 8 -x socks5h://127.0.0.1:10808 -o /dev/null -w '%{http_code}' https://ifconfig.me | grep -q 200; then
    ok "VLESS+Reality+XHTTP tunnel relays traffic through vps"
  else
    bad "VLESS tunnel did not relay traffic"
    echo "--- client xray log ---"
    $COMPOSE exec -T client cat /tmp/xray-client.log || true
  fi
  rm -f "$CLIENT_CFG"
fi

rm -f "$INSTALL_LOG"

echo
step "Results: ${pass} passed, ${fail} failed"
[[ $fail -eq 0 ]]
