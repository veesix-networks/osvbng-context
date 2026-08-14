# osvbng context

Architecture decisions, design notes and working rules for
[osvbng](https://github.com/veesix-networks/osvbng). Rides as a
submodule of the main repo; LLM-assisted contributors start with
CLAUDE.md here before touching anything in the tree.

## Layout

- `CLAUDE.md` - rules for LLM sessions: workflow, engineering rules,
  writing style. The entry point.
- `decisions/` - ADRs, numbered and append-only. Index below.
- `design/` - living design notes for things being built.
- `references/` - protocol spec texts (RFCs). Protocol code is
  written with these open and cites sections.
- `todo.md` - the working queue between sessions.
- `scripts/check-adr-index.sh` - CI check that this index is
  complete.

## Decisions

| ADR | Title | Status |
| - | - | - |
| [0001](decisions/0001-repo-topology-and-llm-workflow.md) | Three-repo topology with public, LLM-first context | Accepted |
| [0002](decisions/0002-vpp-from-pinned-source-with-patch-queue.md) | VPP built from pinned source with a maintained patch queue | Accepted |
| [0003](decisions/0003-session-setup-primitive-with-opdb-inventory.md) | One session setup primitive with opdb as authoritative inventory | Accepted |
| [0004](decisions/0004-ipoe-input-node-classification.md) | Subscriber classification in a dedicated IPoE input node | Accepted |
| [0005](decisions/0005-control-plane-vrf-isolation-via-lcp-netns.md) | Control-plane VRF isolation via LCP network namespaces | Accepted |
| [0006](decisions/0006-cgnat-port-block-allocation.md) | CGNAT port-block allocation architecture | Accepted |
| [0007](decisions/0007-cpu-partitioning-intent-config.md) | CPU partitioning config expresses intent, not core IDs | Accepted |
| [0008](decisions/0008-async-vpp-transport.md) | Async VPP binary API transport with reconciliation in the session layer | Accepted |

## Design notes

| Doc | Topic |
| - | - |
| [osvbng-implemented-summary](design/osvbng-implemented-summary.md) | Orientation summary of the implemented system |
| [vpp-dataplane](design/vpp-dataplane/README.md) | How VPP moves packets, code-grounded against the pinned version |
| [control-dataplane-seam](design/control-dataplane-seam.md) | Responsibility split between the Go control plane and VPP plugins |
| [subscriber-access-model](design/subscriber-access-model.md) | Access handover shapes, per-subscriber interfaces, IP bindings |
| [aaa-provisioning-model](design/aaa-provisioning-model.md) | Provisioning-first AAA, attribute model, service groups |
| [qos-architecture](design/qos-architecture.md) | Per-subscriber policers and CAKE scheduling |
| [qos-aggregates](design/qos-aggregates.md) | Hierarchical aggregate shaping: subscriber, S-VLAN, port |
| [ha-architecture](design/ha-architecture.md) | SRGs, virtual MAC failover, session sync, opdb, recovery |
| [wholesale-l2gw](design/wholesale-l2gw.md) | L2 wholesale gateway: circuits, VLAN rewrite, handoff groups |
| [frr-evpn-capability-audit](design/frr-evpn-capability-audit.md) | Empirically verified FRR 10.7 EVPN behavior |
