# quick-vpn

One-shot Xray VPN + SOCKS5 proxy setup for a fresh Ubuntu VPS.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/Goober-nation/quick-vpn/main/install.sh | sudo bash
```

You'll be prompted to choose what to install:

1. VLESS + Xray + XHTTP VPN only
2. Dante SOCKS5 proxy only
3. Both (default)

When it finishes, it prints ready-to-use `vless://` links (import into Happ, v2rayTun, v2rayNG, or NekoBox) and/or SOCKS5 host/port/user/pass.

### Non-interactive

Skip the prompt by setting `COMPONENTS`:

```bash
COMPONENTS=vless curl -fsSL https://raw.githubusercontent.com/Goober-nation/quick-vpn/main/install.sh | sudo bash
COMPONENTS=socks curl -fsSL https://raw.githubusercontent.com/Goober-nation/quick-vpn/main/install.sh | sudo bash
COMPONENTS=vless,socks curl -fsSL https://raw.githubusercontent.com/Goober-nation/quick-vpn/main/install.sh | sudo bash
```

Other overridable env vars: `PORT` (default `10000`), `SNI` (default `dzen.ru`), `XHTTP_PATH` (default `/xstream`), `SOCKS_PORT` (default `1080`), `SOCKS_USER`, `SOCKS_PASS`, `SERVER_IP`.

## Manage

```bash
systemctl {status,restart,stop} xray
systemctl {status,restart,stop} danted
```

## Testing locally (no VPS needed)

```bash
./docker/run-test.sh
```

Spins up a disposable systemd container, runs the real install script inside it, and verifies both the VLESS tunnel and the SOCKS5 proxy actually carry traffic. Pass `--keep` to leave the containers up for manual poking.
