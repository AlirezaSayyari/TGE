# Edge Device Examples

V2rayTGE supports two edge-facing modes. The wizard prints the exact values to use.

## Mode 1: GRE

Use this when the edge device cannot be directly connected/routed to the VM operational NIC.

Configure on the edge device:

- GRE local IP: edge device WAN/transport IP
- GRE remote IP: V2rayTGE operational NIC IP
- GRE tunnel IP: complementary IP in the same tunnel subnet printed by the wizard
- MTU: value printed by the wizard, default `1476`
- Route or PBR: send LAN CIDRs into the GRE tunnel

Traffic path:

```text
LAN -> Edge Device -> GRE tunnel -> V2rayTGE gre-egress -> tun0 -> Internet
```

## Mode 2: Direct Operational NIC

Use this when the edge device can route or bridge traffic directly to the VM operational NIC. This avoids GRE overhead.

Configure on the edge device:

- Next hop or connected interface: V2rayTGE operational NIC
- Route or PBR: send LAN CIDRs toward the operational NIC
- No GRE tunnel is required
- No GRE MTU or MSS clamp setting is required by V2rayTGE

Traffic path:

```text
LAN -> Edge Device -> V2rayTGE operational NIC -> tun0 -> Internet
```

## VM NIC Layout

- Management NIC: SSH and v2rayA GUI access.
- Operational NIC: edge traffic ingress/egress.

Keep management and operational traffic separate whenever possible. The wizard stores these as `MGMT_NIC` and `OPS_NIC` in `/opt/v2raytge/config.env`.
