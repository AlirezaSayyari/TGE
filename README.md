![GitHub stars](https://img.shields.io/github/stars/alirezasayyari/V2rayTGE?style=for-the-badge)
![GitHub forks](https://img.shields.io/github/forks/alirezasayyari/V2rayTGE?style=for-the-badge)
![License](https://img.shields.io/badge/license-MIT-blue?style=for-the-badge)
![Docker](https://img.shields.io/badge/docker-ready-blue?style=for-the-badge)
![Network](https://img.shields.io/badge/network-egress-orange?style=for-the-badge)

# V2rayTGE (Traffic Gateway Egress) — Production-Safe Edge → v2rayA Egress Gateway

V2rayTGE is a **production-safe** installer + CLI toolkit that turns an Ubuntu server into an **Egress Gateway**.
It receives traffic from your LAN through an edge device such as FortiGate / Router / Firewall / ...
and forwards it to the Internet through **v2rayA** by policy-routing to `tun0` (created by v2rayA running in Docker).

Supported edge modes:
- **GRE mode**: the previous design, where the edge device sends LAN traffic through a GRE tunnel.
- **Direct mode**: the VM operational NIC is the edge-facing interface directly; no GRE, GRE MTU, or MSS clamp prompt is used.

This project is designed for real production environments:
- **No iptables flush**
- **No ip rule flush**
- **No default route change**
- Fully **idempotent** (“ensure-only”; safe to run multiple times)
- **Self-healing** across reboot / docker restart / network restart

---

## Architecture

### Interfaces on EgressGW
- Management NIC: SSH and v2rayA GUI access; the host default route normally stays here.
- Operational NIC: connected toward the edge device and used for traffic operations.
- `gre-egress`: GRE tunnel interface, only in GRE mode.
- `tun0` : created by v2rayA (Docker host networking)

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

Direct mode:

LAN (one or multiple CIDRs)
↓
Edge Device (any vendor)
↓  Direct L2/L3 path
EgressGW operational NIC
↓  Policy Routing (table: v2ray)
tun0 (v2rayA)
↓
Internet

---


## Install (one-liner)

```bash
curl -fsSL https://raw.githubusercontent.com/AlirezaSayyari/V2rayTGE/main/deploy.sh | sudo bash
sudo tge
````

After install:

* Config: `/opt/v2raytge/config.env`
* Compose: `/opt/v2raytge/docker/docker-compose.yml`
* CLI: `/usr/local/sbin/tge`
* Logs: `/var/log/v2raytge/`

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
- `pref 110`: helper rule for traffic involving `tun0` → `lookup v2ray`
- `pref 101`: keep GRE subnet stable in `main` (GRE mode only)

### 3) Forwarding + NAT
To let LAN subnets behind the edge device reach the Internet via `tun0`:
- FORWARD: allow selected edge interface → `tun0`
- FORWARD: allow return `tun0` → selected edge interface for `RELATED,ESTABLISHED`
- NAT: `MASQUERADE` LAN CIDRs out of `tun0`

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
- Docker + v2rayA (we deploy docker-compose)
- root access (systemd + iptables ensure)
- Two VM NICs are recommended:
  - management NIC for SSH/v2rayA GUI
  - operational NIC for edge traffic

### On the Edge Device (Any Vendor)
You must configure one of these modes:
1. **GRE mode**: create a GRE tunnel towards the EgressGW operational NIC IP, then route/PBR LAN CIDRs into the GRE tunnel.
2. **Direct mode**: route/PBR LAN CIDRs directly toward the EgressGW operational NIC.

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
3. Activate Egress System
4. Deactivate Egress System
5. Health Check
6. Logs

---

## Configure (Wizard)

The wizard asks you step-by-step:

* management NIC selection for SSH/v2rayA GUI
* operational NIC selection for edge traffic
* edge mode: `gre` or `direct`
* GRE remote IP and tunnel IP/CIDR only when GRE mode is selected
* one or more LAN CIDRs (validated: correct format, no duplicates, no overlap)
* MSS clamp only when GRE mode is selected
* v2rayA GUI port (default 2017)

At the end it:

* saves config to `/opt/v2raytge/config.env`
* prints the **edge device** tunnel + routing requirements
* Step 0 checks whether `tun0` exists and guides v2rayA setup if missing:

  * if `tun0` is missing, wizard shows full v2rayA steps and asks re-check before continuing
* asks if you want to activate immediately

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

* selected edge interface exists (`gre-egress` in GRE mode, operational NIC in direct mode)
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
curl -fsSL https://raw.githubusercontent.com/AlirezaSayyari/V2rayTGE/main/deploy.sh | sudo bash
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
curl -fsSL https://raw.githubusercontent.com/AlirezaSayyari/V2rayTGE/main/deploy.sh | sudo bash
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

