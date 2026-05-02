# Edge Device Examples

V2rayTGE supports two edge-facing modes while using one server NIC. The wizard prints the exact values to use.

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
LAN -> Edge Device -> GRE tunnel -> V2rayTGE gre-egress -> tun0 -> Internet
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
LAN -> Edge Device -> V2rayTGE primary NIC -> tun0 -> Internet
```

## Server NIC Layout

- Primary NIC: management access, v2rayA GUI, and edge traffic.

The wizard stores this as `PRIMARY_NIC` in `/opt/v2raytge/config.env`.
