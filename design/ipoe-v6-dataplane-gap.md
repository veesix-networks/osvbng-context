# IPoE IPv6 dataplane gap, investigation evidence

Open product issue found 2026-08-17 while chasing suite failures.
Suites 32, 42 and 47 fail intermittently on subscriber-initiated
IPv6 (the through-path to the core, sometimes the gateway) while
IPv4 and all PPPoE twins pass. This note records the verified
evidence chain so the fix session starts from facts, not
recollection. The failing state was reproduced live on the rig.

## Evidence, in observation order

1. Asymmetry: core-initiated v6 pings to a subscriber complete
   round-trip (proving both forwarding directions), while
   subscriber-initiated pings to the same addresses fail. The
   subscriber can transmit replies but not originate.
2. A VPP packet trace of subscriber IPv6 shows
   `ipoe-input: ip6 -> pass-through`: the session classifier does
   not match subscriber v6 traffic into the session context. The
   daemon-side session state is fully bound (API shows the IANA
   address, nonzero sw_if_index) and `IPoESetSessionIPv6Async` is
   called on the live bind path (internal/ipoe/dhcpv6.go,
   handleDHCPv6Reply), so the gap is between that call and the
   plugin's classifier state.
3. The same trace shows
   `osvbng-punt-ipv6-nd: sw_if_index 5 not-enabled` for an RS
   arriving from the subscriber: ND punt was never enabled for
   the subscriber-facing sub-interface, so the daemon's RS and NS
   handlers (nd_ra.go) are bypassed and VPP's native ND serves
   subscribers (`router advertisements sent` counters on
   ip6-icmp-input confirm). Whether enablement is recorded
   against the parent interface while the node checks the RX
   sub-interface index is the granularity question to answer.
4. Flake mechanism consistent with all runs: v6 origination works
   only while the parent-interface fallback path and neighbour
   state happen to line up, which varies with timing; restarts
   shift the timing, which is why the restore suites catch it
   most.

## What was fixed alongside, and what was not

- osvbng-vpp PR 18 registers NS punt with per-type passthrough;
  correct for punt-enabled interfaces, inert while enablement is
  broken.
- osvbng PR 451 sends unsolicited NA after session restore per
  RFC 4861 section 7.2.6, the gap suite 32's 2b case documents;
  it does not cure these failures.
- Not fixed, needs a maintainer decision: where ND punt
  enablement is keyed (parent vs sub-interface) and why
  ipoe-input does not classify v6 for a session whose binding the
  daemon programmed. Suites 32, 42 and 47 sit in
  tests/skip-suites.txt referencing this note until then.

## Reproduction

Deploy tests/32-ipoe-opdb-restore, wait for the dual-stack lease,
then from the subscriber ping the core router v6 address. Trace
with `trace add af-packet-input` on the BNG (CLI socket
/run/osvbng/cli.sock) and read the ipoe-input and
osvbng-punt-ipv6-nd lines.
