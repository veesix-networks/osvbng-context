# FRR EVPN capability audit

This note records empirically verified EVPN behavior of FRR 10.7.0,
the exact version shipped in the osvbng image. The EVPN transport
design (kernel mirror devices, netlink VTEP discovery, route-driven
failover) depends on these behaviors, and every claim here was
observed in a lab, not taken from documentation. All findings are
version-specific to FRR 10.7.0 and must be re-verified before an FRR
version bump.

## Test conditions

Two `frr:10.7.0` containers (verified `zebra version 10.7.0`) in
containerlab, point-to-point link, eBGP between AS 65001 and 65002,
`frr defaults datacenter`, kernel vxlan devices with one bridge per
VNI. Later checks ran osvbng itself against an independent FRR 10.7
VTEP with a kernel dataplane.

## No EVPN-VPWS (RFC 8214)

FRR 10.7 has no EVPN-VPWS support:

- No `vpws` or `xconnect` strings exist in the bgpd or zebra
  binaries.
- The type-1/EAD commands that do exist (`ead-es-frag`,
  `ead-es-route-target`, `disable-ead-evi-rx/tx`, interface-level
  `evpn mh es-id/es-sys-mac/es-df-pref`) are all RFC 7432
  multihoming Ethernet A-D, tied to Ethernet Segments. There is no
  per-EVI VPWS service instance model, no cross-connect semantics,
  no VPWS service labels.
- Upstream, EVPN-VPWS has been an open, unimplemented feature
  request since 2019 (FRRouting/frr issues 3328 and 3970) and is in
  no release through 10.7.

Consequence: osvbng signals E-LINE with RT-3 IMET routes, one VNI
per NNI, and programs the point-to-point VPP tunnels itself. That
model needs nothing FRR lacks.

## Local VNI detection and mirror devices

zebra learns local VNIs exclusively from kernel vxlan devices. The
working recipe per VNI: a vxlan device (`id <vni> local <vtep-ip>
dstport 4789 nolearning`) enslaved to a dedicated bridge, both up.
Bridge enslavement is mandatory; zebra ignores an unenslaved vxlan
device. The VTEP IP is taken from the device's `local` attribute.

Creating or deleting the vxlan-plus-bridge pair at runtime is picked
up via netlink within seconds, with the RT-3 originated or withdrawn
accordingly. No FRR restart or config change is needed, which is what
lets osvbng create mirror devices at config commit time (pkg/evpnmgr).

`advertise-all-vni` is global: every bridge-enslaved kernel VNI in
the netns gets advertised. osvbng creates mirrors only for
`signaling: evpn` tunnels, so this is safe, but no other kernel
vxlan devices may exist in the dataplane netns.

## RT-3 exchange, RD, and route-targets

- The l2vpn evpn address family comes up over eBGP with
  `advertise-all-vni` as the only required knob.
- RT-3 IMET routes are exchanged in both directions with ET:8, auto
  RD `<router-id>:<vlan-based-N>`, auto RT `<asn>:<vni>`.
- Auto-RT import is VNI-wildcarded. With eBGP the two sides derive
  different auto RTs (65001:10101 vs 65002:10101) yet import works,
  and an explicit export RT set on one side is still imported by a
  peer running auto. FRR matches `*:<vni>` when a VNI's import RT is
  auto. For interop with real leaf NOSes, set explicit RTs.
- Per-VNI override: a `vni <n>` context under `address-family l2vpn
  evpn` accepts `rd` and `route-target both|import|export`, applied
  live with immediate re-advertisement. Verified as an FRR
  capability; osvbng's rendered config currently uses only
  `advertise-all-vni` with auto RD/RT and does not emit per-VNI
  blocks.

## Remote VTEP consumption: netlink fdb vs vtysh JSON

Two working ways to consume learned remote VTEPs were verified:

- Netlink fdb watch. zebra installs `00:00:00:00:00:00 dst
  <remote-vtep> self permanent` flood fdb entries on the kernel
  vxlan device, one per remote VTEP. Adds and deletes are emitted as
  AF_BRIDGE RTM_NEWNEIGH/RTM_DELNEIGH netlink events (verified with
  `bridge monitor fdb`). Fully event-driven, and the same netlink
  machinery linux-cp already uses.
- vtysh JSON. `show evpn vni <n> json` and `show evpn vni json`
  return clean JSON with `remoteVteps` lists, suitable for polling.

osvbng consumes remote VTEPs through the netlink fdb watch
(pkg/evpnmgr); mirror-device reconciliation is driven from config,
not from FRR state. The vtysh JSON path is recorded here as a
verified alternative. ZAPI and the northbound API are not used.

## Withdrawal and convergence

Downing the vxlan device on one node withdraws its RT-3; the peer
removes the remote VTEP and its fdb flood entry within about 3
seconds under `frr defaults datacenter` timers. Bringing the device
back re-advertises and re-installs equally fast. The stock timer
profile is roughly 3x slower; osvbng renders its own aggressive
timers in the FRR template.

This one mechanism is both the advertise/withdraw signal for
redundancy transitions and the transport-liveness signal: a
withdrawn remote VTEP removes the local tunnel programming, and the
fabric converges on routing alone.

## Configuration traps

- The l2vpn evpn AF has no `neighbor X send-community` (EVPN always
  carries its extended communities). Worse than a plain error: in
  `vtysh -m`, which frr-reload uses for validation, the unknown
  command silently pops the parse context out of the AF node, so the
  next line (for example `advertise-all-vni`) is what gets reported
  as unknown, at the wrong line. If frr-reload reports a
  valid-looking command as unknown, suspect the line above it. The
  osvbng template deliberately renders no send-community in the
  EVPN AF.
- osvbng's rendered FRR config keeps `ebgp-requires-policy` (frr
  defaults traditional), and the EVPN AF is policy-gated like any
  other AF. eBGP EVPN peering against osvbng therefore needs
  route-policies, or iBGP.

## Other observed knobs

FRR 10.7 also supports `flooding disable` under the EVPN AF (kills
head-end replication flood entries) and `autort rfc8365-compatible`.
Neither is needed for the E-LINE model; noted for completeness.
