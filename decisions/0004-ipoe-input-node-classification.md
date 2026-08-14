# ADR 0004 - Subscriber classification in a dedicated IPoE input node

- Status: Accepted
- Date: 2026-08-14
- Deciders: Brandon

## Context

IPoE subscriber traffic arrives with the standard IP ethertypes
(0x0800, 0x86DD), so unlike PPPoE (0x8864) there is no protocol
ethertype to hook. Subscriber packets still need to be classified
onto per-session ipoe_session interfaces on the RX path, so that
per-session RX counters and ip4/ip6-unicast feature arc features
(CGNAT, ACLs, QoS, policing, accounting) work identically to PPPoE.
VPP has no plugin-side mechanism to override ethernet-input dispatch
per interface; adding one would need a VPP core patch, and the
project does not fork VPP.

## Decision

**Register a dedicated ipoe-input node globally for the IPv4 and
IPv6 ethertypes via ethernet_register_input_type(), with a
per-sw_if_index bitmap that fast-paths interfaces not enabled for
BNG.**

The node runs after ethernet-input, so VLAN classification is done
and enablement is scoped to single-tag S-VLAN sub-interfaces.
Registration is lazy, deferred until the first BNG interface is
enabled, so a system without IPoE pays no overhead. The buffer is at
L3 when the node runs; VPP preserves l2_hdr_offset, and the node
re-walks the Ethernet header to recover the inner VLAN and the
source MAC for the session key (sw_if_index, inner VLAN, source
MAC). The PPPoE decap path uses the same recovery pattern.

On a session hit the node rewrites sw_if_index[VLIB_RX] to the
ipoe_session interface and accumulates per-session RX counters. Two
exceptions skip the rewrite so control traffic keeps punting on the
encap sub-interface the control plane enabled: IPv4 limited
broadcast (255.255.255.255, DHCP Discover and broadcast Request)
and IPv6 multicast destinations. Routed unicast control traffic
(DHCP Renew, Release) does get rewritten, so the punt path resolves
enablement by falling back one hop to the session interface's
sup_sw_if_index, which is its encap sub-interface. On a session
miss the packet passes through to ip4-input or ip6-input unchanged.

An ipoe_session interface is not a full L3 interface: it carries no
address and no unnumbered binding in VPP. Session creation binds it
to the session VRF with ip_table_bind(), parents it on the encap
sub-interface via sup_sw_if_index, and points its L3 output at the
plugin's tunnel-output node. Address bindings arrive later through
separate per-family APIs (IPv4 /32, IA_NA /128, delegated prefix),
each installing FIB entries with the plugin's own FIB source.

## Consequences

- All IP traffic on every interface enters the node. Non-BNG
  interfaces pay one bitmap check per packet, about 1ns from L1
  cache. This is the accepted cost of the global registration.
- MPLS transit is untouched, since 0x8847/0x8848 are separate
  ethertypes.
- IPv4 directed and subnet broadcast are not special-cased; only
  the limited broadcast address skips the rewrite.
- Only single-tag S-VLAN sub-interfaces can be enabled; the config
  model does not cover QinQ enablement.

## Alternatives considered

- device-input feature arc: fires on the physical interface before
  VLAN classification, cannot be scoped per S-VLAN sub-interface; on
  a shared bond, core routing traffic would hit the node. Rejected.
- Per-subinterface ethernet-input hook: no plugin-side mechanism
  exists in VPP; would require a core patch. Rejected for
  maintainability, the project does not fork VPP.
- ip4-unicast and ip6-unicast feature arc trampoline: the miss path
  re-enters ip4-input on the same interface and loops the arc; the
  hit path double-counts IP accounting and validation; it also needs
  two separate arc registrations. Rejected.
