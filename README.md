![GitHub stars](https://img.shields.io/github/stars/AlirezaSayyari/TGE?style=for-the-badge)
![GitHub forks](https://img.shields.io/github/forks/AlirezaSayyari/TGE?style=for-the-badge)
![License](https://img.shields.io/badge/license-MIT-blue?style=for-the-badge)
![Docker](https://img.shields.io/badge/docker-ready-blue?style=for-the-badge)
![Network](https://img.shields.io/badge/network-egress-orange?style=for-the-badge)

# TGE (Traffic Gateway Egress) — Production-Safe Edge → v2rayA/WireGuard/Server-Gateway Egress

V2rayTGE is a **production-safe** installer + CLI toolkit that turns an Ubuntu server into an **Egress Gateway**.
It receives traffic from your LAN through an edge device such as FortiGate / Router / Firewall / ...
and forwards it to the Internet through **v2rayA system-tun** (`tun0`), **WireGuard** (`wg0`), or the **server default gateway**.

Supported edge modes:
- **GRE mode**: the previous design, where the edge device sends LAN traffic through a GRE tunnel.
- **Direct mode**: the server primary NIC is the edge-facing interface directly; no GRE, GRE MTU, or MSS clamp prompt is used. The wizard suggests the server default gateway as the edge next-hop; keep it if that gateway is the Forti/router path back to client LANs.

Supported egress backends:
- **v2rayA system-tun**: policy-routes LAN traffic to `tun0` created by v2rayA.
- **WireGuard**: policy-routes LAN traffic to a `wg-quick` interface such as `wg0`; the wizard enforces `Table = off` so the server default route is not changed.
- **Server default gateway**: bypasses `tun0`/`wg0`, MASQUERADEs configured LAN CIDRs and gateway-originated probes to the server IP, and forwards them with the host `main` default route. The upstream gateway therefore needs no LAN-source-specific return route or RPF exception.

This project is designed for real production environments:
- **No iptables flush**
- **No ip rule flush**
- **No default route change**
- Fully **idempotent** (“ensure-only”; safe to run multiple times)
- **Self-healing** across reboot / docker restart / network restart

---

## Architecture

### Interfaces on EgressGW
- `ensXXX` : Primary NIC (management + edge traffic; default route stays here)
- `gre-egress` : GRE tunnel interface, only in GRE mode
- `tun0` : created by v2rayA when using v2rayA system-tun
- `wg0` : created by `wg-quick` when using WireGuard mode

### Traffic Flow

GRE mode:

LAN (one or multiple CIDRs)
↓
Edge Device (any vendor)
↓  GRE tunnel
EgressGW (gre-egress)
↓  Policy Routing (table: v2ray)
tun0 (v2rayA)
↓
Internet

WireGuard egress:

LAN (one or multiple CIDRs)
↓
Edge Device (GRE or direct)
↓
EgressGW selected edge interface
↓  Policy Routing (table: v2ray)
wg0 (WireGuard)
↓
Remote WireGuard server
↓
Internet

Direct mode:

LAN (one or multiple CIDRs)
↓
Edge Device (any vendor)
↓  Direct path
EgressGW primary NIC
↓  Policy Routing (table: v2ray)
tun0 (v2rayA)
↓
Internet

Server-gateway egress:

LAN (one or multiple CIDRs)
↓
Edge Device (GRE or direct)
↓
EgressGW selected edge interface
↓  Linux forwarding (main default route)
Server default gateway on primary NIC
↓
Internet

---


## Install (one-liner)

```bash
curl -fsSL https://raw.githubusercontent.com/AlirezaSayyari/TGE/main/deploy.sh | sudo bash
sudo tge
````

After install:

* Config: `/opt/v2raytge/config.env`
* Compose: `/opt/v2raytge/docker/docker-compose.yml`
* CLI: `/usr/local/sbin/tge`
* Logs: `/var/log/v2raytge/`

Repository source precedence for advanced or mirrored installs:

1. Explicit `GH_REPO` plus `REPO_RAW` (both must identify the same GitHub repository).
2. Explicit `REPO_RAW` alone (a GitHub raw URL derives repository metadata; a custom URL disables Release lookup).
3. Explicit `GH_REPO` alone (raw URLs are derived from it and the selected ref).
4. Automatic discovery: `runovelhq/tge`, then `AlirezaSayyari/TGE`, then the historical `AlirezaSayyari/V2rayTGE` fallback.

Each operation resolves its repository once. Automatic fallback continues only when GitHub definitively returns HTTP 404. Network errors, rate limits, server errors, and malformed responses stop resolution instead of silently selecting an older source. Redirected repositories use the canonical identity returned by GitHub.

GitHub raw overrides accept a simple branch or tag such as `main` or `v1.2.0`. A raw URL cannot unambiguously encode a slash-containing ref as a base URL, so such raw overrides are rejected; use `GH_REPO` with `TGE_SOURCE_REF` for an explicit slash-containing branch. When `REPO_RAW` and `TGE_SOURCE_REF` are both supplied, their refs must match exactly. Query strings, fragments, embedded credentials, malformed repositories, and mismatched override pairs are rejected. A custom non-GitHub `REPO_RAW` is installation-only and cannot be used by `tge upgrade`.

Pass overrides across the `sudo` boundary on the `sudo` command itself:

```bash
curl -fsSL https://raw.githubusercontent.com/AlirezaSayyari/TGE/main/deploy.sh |
  sudo GH_REPO=owner/repository REPO_RAW=https://raw.githubusercontent.com/owner/repository/main bash
```

An explicit ref is installed or upgraded exactly from that ref; latest Release/tag discovery cannot replace it. Stable tag refs use installed-version verification, while branch refs require a successful installer and the expected installed files. Once selected, metadata and every downloaded project file use the same repository and ref. Stable versions use `vMAJOR.MINOR.PATCH` or `MAJOR.MINOR.PATCH`, with at most nine decimal digits per component. Discovery examines the first 100 GitHub tags; prerelease and non-version tags are ignored. The future canonical repository is `runovelhq/tge`.

---

## Key Design Principles

### 1) We do NOT touch the system default route
Your server keeps its default route on `ensXXX`.  
V2rayTGE only:
- ensures a separate routing table (`v2ray`)
- ensures policy rules for traffic entering via the selected edge interface

### 2) Policy Routing Rules
V2rayTGE ensures these rules exist (and does not delete/flush others):
- `pref 100`: traffic **incoming on selected edge interface** → `lookup v2ray`
- `pref 110`: helper rule for traffic involving the selected egress interface → `lookup v2ray`
- `pref 101`: keep GRE subnet stable in `main` (GRE mode only)

These policy rules are only used by the `v2raya_tun` and `wireguard` backends. In `server_gateway` mode, TGE removes its old `pref 100/110` rules, empties its dedicated table, and uses the host `main` default route.

### 3) Forwarding + NAT
To let LAN subnets behind the edge device reach the Internet:
- FORWARD: allow selected edge interface → selected egress interface
- FORWARD: allow return selected egress interface → selected edge interface for `RELATED,ESTABLISHED`
- NAT: `MASQUERADE` configured LAN CIDRs out of the selected egress interface in all three backends, including the server primary NIC in server-gateway mode.

### 4) MSS Clamp (fix “ping works but HTTPS/TLS hangs”)
A very common real-world issue:
- ICMP ping works
- HTTPS/TLS stalls after ClientHello

This is typically a **PMTU blackhole** on GRE paths:
large packets with DF=1 can’t pass a smaller MTU link.

✅ Fix used here:
- clamp MSS on **SYN** for `gre-egress → tun0` to **1436** (default),
  assuming GRE MTU **1476** (default).

Defaults:
- `GRE MTU = 1476`
- `MSS Clamp = 1436` (≈ MTU - 40)

Direct mode skips GRE MTU and MSS clamp configuration.

---

## Requirements

### On EgressGW (Ubuntu)
- Ubuntu Server
- Docker + v2rayA for v2rayA system-tun mode, or WireGuard config for WireGuard mode
- `wireguard-tools` for WireGuard mode
- root access (systemd + iptables ensure)
- One primary NIC for both management and edge traffic

### On the Edge Device (Any Vendor)
You must configure one of these modes:
1. **GRE mode**: create a GRE tunnel towards the EgressGW primary NIC IP, then route/PBR LAN CIDRs into the GRE tunnel.
2. **Direct mode**: route/PBR LAN CIDRs directly toward the EgressGW primary NIC, and set the edge next-hop IP to the gateway that reaches those LANs. In many deployments this is the server default gateway.

V2rayTGE is **vendor-neutral** and does not assume FortiGate.

---

## CLI Dashboard

Run:

```bash
sudo tge
```

Menu:

1. Help & Introduction
2. Configure Egress System (Wizard)
3. Edit Egress System Configuration
4. Activate Egress System
5. Deactivate Egress System
6. Health Check
7. Logs
8. Upgrade Egress System
9. Backup / Restore Config

Useful direct commands:

```bash
sudo tge edit
sudo tge upgrade
sudo tge backup
sudo tge restore
tge version
```

---

## Configure (Wizard)

The wizard asks you step-by-step:

* egress backend by number: v2rayA system-tun, WireGuard, or server default gateway
* primary NIC selection (used to discover local server IP)
* edge mode: `gre` or `direct`
* GRE remote IP and tunnel IP/CIDR only when GRE mode is selected
* Forti/edge next-hop IP only when direct mode is selected; the server default gateway is suggested automatically
* one or more LAN CIDRs (validated: correct format, no duplicates, no overlap)
* MSS clamp only when GRE mode is selected
* v2rayA GUI port (default 2017) only for v2rayA mode
* WireGuard interface/config source only for WireGuard mode
* server gateway IP only for server-gateway mode; the default gateway is suggested automatically

At the end it:

* saves config to `/opt/v2raytge/config.env`
* prints the **edge device** tunnel + routing requirements
* In v2rayA mode, Step 0 checks whether `tun0` exists and guides v2rayA setup if missing:

  * if `tun0` is missing, wizard shows full v2rayA steps and asks re-check before continuing
* asks if you want to activate immediately

In WireGuard mode, activation starts `wg-quick@<interface>`, skips v2rayA startup, and uses the WireGuard interface as the egress tunnel.

In server-gateway mode, activation skips both v2rayA and WireGuard startup, MASQUERADEs configured LAN CIDRs plus probes sourced by the upstream gateway, and forwards them with the host main default route. This allows FortiGate SD-WAN health checks to traverse TGE without gateway-specific source routing or RPF exceptions.

### Edit Configuration

Use menu option 3 or:

```bash
sudo tge edit
```

The editor changes one saved config value at a time without forcing the full wizard flow. It creates a backup before each saved edit and can apply the saved configuration from inside the editor.

### Upgrade

Use menu option 8 or:

```bash
sudo tge upgrade
```

The upgrade flow checks the latest GitHub release/tag, backs up `/opt/v2raytge/config.env`, downloads the selected archive, and runs the installer with the correct release raw URL so tagged upgrades do not accidentally install `main`.

Release note: keep the root `VERSION` file equal to the GitHub tag you publish, for example `v1.2.0`. Installed systems read `/opt/v2raytge/VERSION` first, with `meta.env` kept as fallback metadata.

### Backup / Restore

Use menu option 9 or:

```bash
sudo tge backup
sudo tge restore
```

Config backups are stored under `/var/backups/v2raytge`.

---

## v2rayA GUI

v2rayA runs in Docker with host networking and creates `tun0` on the host.

Default GUI:

```
http://<EgressGW-IP>:2017
```

In v2rayA (Step 0 guide used by wizard):

1. Open V2rayA GUI: `http://<EgressGW-IP>:2017`
2. Import Connection Config/Subscription
3. From Right-Above Dashboard click Setting
4. Set Transparent Proxy/System Proxy -> On: Do Not Split Traffic
5. Set Transpatent Proxy/System Proxy Implementation -> system tun
6. Set Prevent DNS Spoofing -> Forward DNS Request
7. (optional) Set Automatically Update Subscriptions -> Update When Service Start
8. Click Save and Apply
9. In Dashboard click [Select] on desired connection
10. From Left-Above Dashboard click Ready/Start
11. Return to server CLI and continue setup wizard
12. V2rayTGE services then apply routing/firewall rules automatically

---

## Activate / Deactivate

### Activate

From CLI menu, or:

```bash
sudo tge-ctl --activate
```

Activate does:

* runs firewall backend preflight (`legacy` by default)
* starts v2rayA via docker compose
* enables systemd units (GRE ensure only in GRE mode, plus apply + path + timer)
* runs an immediate safe ensure pass

### Deactivate

```bash
sudo tge-ctl --deactivate
```

Deactivate is safe:

* disables units
* removes only the project’s own known rules (no flush)

---

## Self-Healing (systemd)

Installed units:

* `tge-gre.service`
  Ensures GRE tunnel exists in GRE mode; no-op in direct mode (**idempotent, no delete**)
* `tge-apply.service`
  Ensures policy routing + iptables, plus GRE MSS fix when applicable (**no flush**)
* `tge-apply.path`
  Triggers apply when `tun0` appears
* `tge-apply.timer`
  Periodic safe ensure (failsafe)

So it survives:

* reboot ✅
* docker restart ✅
* network restart ✅

---

## Health Check

```bash
sudo tge-health
```

Checks:

* selected edge interface exists (`gre-egress` in GRE mode, primary NIC in direct mode)
* direct-mode LAN return routes use the configured edge next-hop when set
* `tun0` exists
* required `ip rule` entries exist
* `v2ray` table routes exist
* MSS clamp rule exists in GRE mode; skipped in direct mode
* optional quick curl test from the gateway

---

## Firewall Backend (Recommended: legacy)

V2rayTGE is optimized for gateway stability with **iptables-legacy** as the default/recommended backend.

Why:

* Docker + nft backend combinations can create backend mismatch conditions where packets are accepted in one stack but expected in another.
* On GRE/tun gateway paths, this mismatch can cause intermittent or full traffic drops even when routes/rules look correct.

Backend mode knob:

* Default: `TGE_FIREWALL_BACKEND=legacy`
* Advanced/experimental: `TGE_FIREWALL_BACKEND=nft`

If you explicitly choose nft mode, V2rayTGE will not force backend alternatives and will continue with warnings.

### Interactive legacy-switch flow during install

When mode is `legacy` and backend is not legacy, deploy script now does this:

1. Prints the exact commands it will apply.
2. Asks for confirmation before switching alternatives.
3. Applies switch and verifies backend.
4. Asks for reboot confirmation.
5. Shows command to run after reboot:

```bash
curl -fsSL https://raw.githubusercontent.com/AlirezaSayyari/TGE/main/deploy.sh | sudo bash
```

> Prompt input is read from `/dev/tty`, so confirmations still work with `curl ... | sudo bash`.


## Troubleshooting: traffic not passing after install

1. Check backend:

```bash
iptables --version
update-alternatives --display iptables
```

2. If backend is not legacy, switch safely:

```bash
sudo update-alternatives --set iptables /usr/sbin/iptables-legacy
sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
```

3. Restart Docker after backend switch:

```bash
sudo systemctl restart docker
```

4. Reboot if backend was switched, then rerun deploy:

```bash
curl -fsSL https://raw.githubusercontent.com/AlirezaSayyari/TGE/main/deploy.sh | sudo bash
```

5. Re-apply TGE rules/services:

```bash
sudo systemctl restart tge-apply.service
```

6. Verify health and rules:

```bash
sudo tge-health
ip -o rule show | egrep '^(100|101|110):'
```

---

## Safety Notes

V2rayTGE avoids destructive operations by design:

* no `iptables -F`, no `iptables -X`
* no `ip rule flush`
* no default route changes
* ensures only the exact rules it owns

---

## Uninstall (Safe)

1. Deactivate:

```bash
sudo tge-ctl --deactivate
```

2. Disable units:

```bash
sudo systemctl disable --now tge-apply.timer tge-apply.path tge-apply.service tge-gre.service
```

3. Remove files:

```bash
sudo rm -rf /opt/v2raytge /var/log/v2raytge
sudo rm -f /usr/local/sbin/tge /usr/local/sbin/tge-*
sudo rm -f /etc/systemd/system/tge-*.service /etc/systemd/system/tge-*.timer /etc/systemd/system/tge-*.path
sudo systemctl daemon-reload
```
