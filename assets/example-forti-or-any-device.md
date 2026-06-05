# Edge Device Examples

V2rayTGE supports two edge-facing modes while using one server NIC. The wizard prints the exact values to use.
For egress, TGE can use v2rayA system-tun (`tun0`), WireGuard (`wg0`), or the server default gateway.

## Mode 1: GRE

Use this when the edge device should send LAN traffic through a GRE tunnel.

Configure on the edge device:

- GRE local IP: edge device WAN/transport IP
- GRE remote IP: V2rayTGE primary NIC IP
- GRE tunnel IP: complementary IP in the same tunnel subnet printed by the wizard
- MTU: value printed by the wizard, default `1476`
- Route or PBR: send LAN CIDRs into the GRE tunnel

Traffic path:

```text
LAN -> Edge Device -> GRE tunnel -> V2rayTGE gre-egress -> tun0/wg0 -> Internet
```

With server-gateway egress selected, the GRE path becomes:

```text
LAN -> Edge Device -> GRE tunnel -> V2rayTGE gre-egress -> server default gateway -> Internet
```

## Mode 2: Direct Primary NIC

Use this when the edge device can route or bridge traffic directly to the V2rayTGE primary NIC. This avoids GRE overhead.

Configure on the edge device:

- Next hop or connected interface: V2rayTGE primary NIC
- Route or PBR: send LAN CIDRs toward the primary NIC
- On V2rayTGE, set `DIRECT_EDGE_GW` to the gateway that reaches the client LANs. The wizard suggests the server default gateway automatically; keep it when that gateway is the Forti/router path back to the LANs.
- No GRE tunnel is required
- No GRE MTU or MSS clamp setting is required by V2rayTGE

Traffic path:

```text
LAN -> Edge Device -> V2rayTGE primary NIC -> tun0/wg0 -> Internet
```

With server-gateway egress selected, traffic exits through the server gateway instead of `tun0/wg0`.

## WireGuard Egress Notes

When WireGuard is selected:

- The TGE server uses a `wg-quick` interface such as `wg0`.
- The WireGuard config must use `Table = off`; the wizard enforces this so the server default route stays unchanged.
- IPv4-only WireGuard `Address` is recommended for this gateway path.
- The edge device PBR does not change: send LAN traffic toward the selected TGE edge path.

Traffic path:

```text
LAN -> Edge Device -> V2rayTGE edge -> wg0 -> WireGuard server -> Internet
```

## Server Gateway Egress Notes

Use this when the edge device handles NAT/PBR and TGE should not forward traffic to `tun0` or `wg0`.

- The wizard stores `TGE_EGRESS_MODE=server_gateway`.
- TGE routes edge traffic out via `SERVER_GATEWAY` on `SERVER_GATEWAY_IF`.
- TGE does not add `MASQUERADE` rules in this mode.
- On FortiGate, keep NAT and use PBR/static routing to send the desired traffic into the selected TGE edge path, such as the GRE tunnel.

Traffic path:

```text
LAN -> Edge Device -> V2rayTGE edge -> server default gateway -> Internet
```

## Server NIC Layout

- Primary NIC: management access, optional v2rayA GUI, WireGuard endpoint traffic, and edge traffic.

The wizard stores this as `PRIMARY_NIC` in `/opt/v2raytge/config.env`.
