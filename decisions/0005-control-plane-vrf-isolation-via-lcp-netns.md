# ADR 0005 - Control-plane VRF isolation via LCP network namespaces

- Status: Accepted
- Date: 2026-08-14
- Deciders: Brandon

## Context

Every control-plane socket osvbng opens (RADIUS, DHCPv4/v6 relay,
HTTP auth, CGNAT exporter, northbound REST, Prometheus, HA gateway,
HA peer-sync) accepts a per-component `vrf` and optional `source_ip`.
Sockets bind to the named Linux VRF master device with
`SO_BINDTODEVICE`. The kernel enforces the VRF: replies arriving on a
different VRF are dropped and never reach user space.

VRF master devices do not live in the netns where the osvbngd process
runs. The VRF manager creates them through a netlink handle bound to
the LCP netns (default name `dataplane`, created by VPP's LCP plugin)
so that LCP tap shadow interfaces, the Linux side of VPP-owned NICs,
can be enslaved to them. `SO_BINDTODEVICE` resolves the device name
in the calling thread's netns, so a socket opened from the default
netns fails with `ENODEV` even though the VRF exists. This surfaced
when a production deployment bound RADIUS to a VRF and the daemon
refused to start.

## Decision

**All control-plane sockets are opened through `pkg/netbind`, which
switches the calling OS thread into the LCP netns for the socket-open
syscall, and VRF isolation relies on the kernel default
`l3mdev_accept=0` being left in place.**

`pkg/netbind` locks the OS thread, enters the LCP netns, opens the
socket, restores the original netns, and unlocks, the same pattern as
the kernel UDP transport in `internal/l2tp/`. A socket keeps its
netns after creation, so goroutines that later read or write it need
no netns awareness. Without a VRF binding the switch is skipped and
the default path is unchanged. For HTTP and gRPC clients the switch
happens inside the per-connection dial closure. The daemon wires the
netns name into `pkg/netbind` once at startup in `cmd/osvbngd/`. If
restoring the original netns fails after a switch, the thread stays
locked so it is never returned to the scheduler pool in the wrong
netns.

The `*_l3mdev_accept` sysctls stay at the kernel default of 0.
Setting them to 1 lets unbound sockets receive traffic from any VRF,
defeating the isolation the feature exists to provide. osvbng never
sets them, and deployments must not either.

DNS resolution is VRF-aware. `pkg/netbind` exports a resolver whose
transport is bound like any other socket (dialed in the LCP netns
with the VRF device binding and source IP), wired into the dialer,
the HTTP transport, gRPC dial options, and DHCP relay server
resolution, so lookups cannot leak onto the default VRF.

The DHCP relay (`pkg/dhcp/relay/`) uses per-(family, vrf, source_ip,
local_port) socket groups instead of a singleton per-family socket,
so a default-VRF binding and a VRF binding on the same port coexist.
The server cache key includes the binding, so two servers at the same
address in different VRFs stay distinct. Read loops classify errors:
fatal device errors (`ENODEV`, `ENETDOWN`, `EADDRNOTAVAIL`,
`ENETUNREACH`) close the group, unknown errors back off 100 ms, and a
closed group is recreated on next use.

Bindings are validated centrally at config commit, after VRF
reconciliation: the pass confirms the referenced VRF exists and the
source IP family matches. `source_ip` without `vrf` is allowed and
pins the source on the default routing table, matching common NOS
source-interface semantics.

## Consequences

- Isolation is kernel-enforced with no per-packet user-space
  overhead, only the kernel's normal bound-device socket lookup and
  routing checks.
- Deployments must leave `l3mdev_accept` at 0; osvbng does not
  currently self-check the sysctls at startup.
- The LCP netns is the single well-known home for VRF masters.
  Per-VRF netns isolation is not supported. Subscriber data-plane
  VRFs are unaffected; they live in VPP FIB tables.
- Netns tests need CAP_NET_ADMIN and follow the existing
  skip-if-unprivileged pattern.

## Alternatives considered

- Set `l3mdev_accept=1` at container bootstrap so unbound sockets see
  VRF traffic: rejected, it defeats the isolation model.
- Move VRF masters to the default netns: rejected, LCP tap shadow
  interfaces could no longer be enslaved to them.
- A VRF-ready gate before plugin construction: rejected, startup
  ordering was already correct; the failure was netns visibility.
- Per-plugin binding validation: rejected for a single commit-time
  pass, which auth and DHCP factories could not otherwise reach.
