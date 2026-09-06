# quick-vpn

One-shot Xray VPN + SOCKS5 proxy setup for a fresh Ubuntu VPS.

## Install

```bash
sudo apt update && sudo apt upgrade -y
curl -fsSL https://raw.githubusercontent.com/Goober-nation/quick-vpn/main/install.sh | sudo bash
```

> **About `sudo`**: the install script needs root to install packages, write systemd units, and manage the firewall, so it's run with `sudo bash` (or as `root` directly). It never asks for your password mid-script or does anything beyond package installs, service management (`xray`, `danted`), and firewall (`ufw`) rules — nothing in it touches your SSH keys, other users' data, or anything outside its own config files. If you'd rather review it first, download it (`curl -fsSL .../install.sh -o install.sh`), read it, then run `sudo bash install.sh`.

You'll be prompted to choose what to install:

1. VLESS + Xray + XHTTP VPN only
2. Dante SOCKS5 proxy only
3. Both (default)

Then, for whichever you picked, you'll be prompted for a few settings — press Enter on any of them to keep the default:

| Setting | Prompt | Default |
|---|---|---|
| VLESS port | `VLESS port` | `10000` |
| Reality camouflage domain | `Reality camouflage domain (SNI)` | `addons.mozilla.org` |
| XHTTP path | `XHTTP path` | `/xstream` |
| SOCKS5 port | `SOCKS5 port` | `1080` |
| SOCKS5 username | `SOCKS5 username` | random, e.g. `user4821` |
| SOCKS5 password | `SOCKS5 password` | random 20-character string |

When it finishes, it prints ready-to-use `vless://` links plus a QR code, and/or SOCKS5 host/port/user/pass — see below for how to actually connect with each.

## Connecting to the VPN (VLESS)

The install prints two `vless://` links (`XHTTP-Stream-One` and `XHTTP-Packet-Up` — try Stream-One first, it's the more broadly compatible mode) plus a QR code for the Stream-One link. Any of these gets you connected in a client like Happ, v2rayTun, v2rayNG, or NekoBox:

- **Scan the QR code** printed in the terminal — in the client, choose "Scan QR code" and point your camera at it.
- **Paste the link** — copy one of the printed `vless://...` strings onto the device (clipboard sync, Telegram-to-self, notes app, etc.), then in the client choose "Add from clipboard" / "Import from clipboard".
- **Manual entry** — if a client wants individual fields instead of a link, use the raw values also printed in the summary: UUID, Public key, Short ID, SNI, plus the address/port from the link and `Reality` / `XHTTP` as the security/network type.

After importing, select the profile and connect. Verify it's actually routing by checking your egress IP from the device (e.g. visiting a "what's my IP" page) and confirming it matches the VPS.

## Connecting to the SOCKS5 proxy

The install prints a host, port, username, and password. Add these as a SOCKS5 proxy in whatever you're pointing at it:

- **Browser** (Firefox: Settings → Network Settings → Manual proxy configuration → SOCKS Host; Chrome/system-wide: via OS network proxy settings or an extension like Proxy SwitchyOmega) — enter the host and port, select SOCKS5 with authentication, then supply the username/password when prompted.
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

---

## Automation / non-interactive use

Every prompt can be skipped by setting the matching env var before the pipe — set one and its prompt is skipped, leave the rest unset to still be asked for those:

```bash
COMPONENTS=vless,socks PORT=8443 SOCKS_PORT=1081 SOCKS_USER=myuser SOCKS_PASS=mypass \
  curl -fsSL https://raw.githubusercontent.com/Goober-nation/quick-vpn/main/install.sh | sudo bash
```

Full list: `COMPONENTS` (`vless`, `socks`, or `vless,socks`), `PORT`, `SNI`, `XHTTP_PATH`, `SOCKS_PORT`, `SOCKS_USER`, `SOCKS_PASS`, `SERVER_IP` (override public-IP auto-detection), `ALLOW_PRIVATE_IP=1` (permit a private/LAN `SERVER_IP` — for testing only), `CONFIRM_IPV6_ONLY=1` (proceed non-interactively on an IPv6-only host).

Set every relevant var and it runs with zero prompts at all — the standard shape for a one-liner deploy script or a provisioning tool.

## Re-running on a VPS you already use

The script checks, per component, whether its systemd service is already active, its config file already exists, or its port is already held by something else. If any of those is true, it **skips that component and leaves the existing setup untouched**, warning you why — it will not silently overwrite another service, restart something you already had running, or flip your firewall to default-deny if `ufw` was intentionally off. On an interactive run you'll instead be asked `Skip ... and leave the existing setup untouched? [Y/n]`.

To force a component to (re)install anyway — backing up its existing config file first — set `FORCE_VLESS=1` and/or `FORCE_SOCKS=1`.

One thing it can't safely resolve automatically: if `SOCKS_USER` collides with a real, pre-existing system account (not one this script created), it refuses to touch that account's password and aborts — pick a different `SOCKS_USER` instead.

## Testing locally (no VPS needed)

```bash
./docker/run-test.sh
```

Spins up a disposable systemd container, runs the real install script inside it, and verifies both the VLESS tunnel and the SOCKS5 proxy actually carry traffic. Pass `--keep` to leave the containers up for manual poking.

Pass `--ipv6` to run the same checks addressing the vps over its IPv6 address instead, exercising the dual-stack listen and link-bracketing paths (`vless://uuid@[ipv6]:port`). The SOCKS5-over-IPv6 leg may fail in this mode purely because the local docker bridge network isn't IPv6-NAT'd to the real internet — that's a limitation of the test sandbox, not the install script; the VLESS tunnel check still passes because it dials out through the vps's own default route.
