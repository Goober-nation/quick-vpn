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

## Connecting to the VPN (VLESS)

The install prints two `vless://` links (`XHTTP-Stream-One` and `XHTTP-Packet-Up` — try Stream-One first, it's the more broadly compatible mode) plus a QR code for the Stream-One link. Any of these gets you connected in a client like Happ, v2rayTun, v2rayNG, or NekoBox:

- **Scan the QR code** printed in the terminal — in the client, choose "Scan QR code" and point your camera at it.
- **Paste the link** — copy one of the printed `vless://...` strings onto the device (clipboard sync, Telegram-to-self, notes app, etc.), then in the client choose "Add from clipboard" / "Import from clipboard".
- **Manual entry** — if a client wants individual fields instead of a link, use the raw values also printed in the summary: UUID, Public key, Short ID, SNI, plus the address/port from the link and `Reality` / `XHTTP` as the security/network type.

After importing, select the profile and connect. Verify it's actually routing by checking your egress IP from the device (e.g. visiting an "what's my IP" page) and confirming it matches the VPS.

## Connecting to the SOCKS5 proxy

The install prints a host, port, username, and password. Add these as a SOCKS5 proxy in whatever you're pointing at it:

- **Browser** (Firefox: Settings → Network Settings → Manual proxy configuration → SOCKS Host; Chrome/system-wide: via OS network proxy settings or an extension like Proxy SwitchyOmega) — enter the host and port, and select SOCKS5 with authentication, then supply the username/password when prompted.
- **curl / command line**:
  ```bash
  curl -x socks5h://<user>:<pass>@<host>:<port> https://ifconfig.me
  ```
- **Torrent clients / other apps** with a SOCKS5 proxy setting — same host/port/username/password.

Use `socks5h://` (not `socks5://`) wherever possible so DNS resolution happens through the proxy too, not just the connection.

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

Pass `--ipv6` to run the same checks addressing the vps over its IPv6 address instead, exercising the dual-stack listen and link-bracketing paths (`vless://uuid@[ipv6]:port`). The SOCKS5-over-IPv6 leg may fail in this mode purely because the local docker bridge network isn't IPv6-NAT'd to the real internet — that's a limitation of the test sandbox, not the install script; the VLESS tunnel check still passes because it dials out through the vps's own default route.
