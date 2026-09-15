# ADR 0013 - CGNAT session lifecycle runs through one writer per subscriber key

- Status: Accepted
- Date: 2026-09-12
- Deciders: Brandon

## Context

The CGNAT component (`internal/cgnat/`) programs the dataplane from
session events. Activate arrives on the programmed and restored
topics, release on the lifecycle topic, and the local event bus runs
every handler on its own goroutine (`pkg/events/local`). Nothing
upstream orders a subscriber's activate against its release.

The allocator identity is `(inside_vrf_id, inside_ip)` (ADR 0006),
while events are keyed by session id. With a sticky DHCP lease a
subscriber that releases and rediscovers gets the same address back
(the address allocator is last-in-first-out), so the old session's
release and the new session's activate meet on one allocator key
under different session ids. Audit findings D1, D2 and D6
(design/cgnat-audit-2026-08.md) and osvbng issue 484 record what
followed: the new session found the old block by address and
committed, then the old session's release deleted the dataplane
mapping and freed the block, leaving a committed control-plane
mapping with no dataplane entry and a block the allocator would hand
to someone else. Three sibling windows had the same root: a release
between the synchronous block reservation and the asynchronous add
callback let the callback commit for a dead session; the 64-stream
async transport has no per-key ordering, so a same-address flap could
land the delete after the add; and a failed delete freed the block
locally anyway. On restart, the preserved-for-retry path re-added a
block with no owner, so the session that later activated came up
believed translated with nothing programmed, no concurrency required.

ADR 0008 states that ordering holds because sequential per-session
VPP operations are enqueued from inside the previous callback and
sessions own separate state. That holds for IPoE and PPPoE, where a
session owns its interface. It does not hold for CGNAT, where two
sessions can share one allocator key. The session-id activation
guard that existed (`beginActivation`) serialised the wrong identity.

todo.md item 13 names admission serialised per subscriber key as a
general direction. This decision is the CGNAT instance of it and
does not wait for the bus rework in item 11.

## Decision

**Everything that programs the dataplane for one subscriber key goes
through a single writer for that key. Events only record which
session should hold the key; the writer converges the programmed
state toward that with at most one dataplane call in flight per key,
re-evaluating when each call completes. A release changes the wanted
state only when the releasing session is the one that holds the key,
and the allocator block is freed only from the delete callback on
success.**

Concretely, per key the component keeps want (the session that should
hold it), have (the session whose programming the dataplane reflects),
the block the allocator holds for it, and a busy flag. Activate sets
want; release clears want if it names the current holder; either then
runs converge. Converge picks one step from the pair (set up, tear
down, refresh the block onto a new holder or interface, or adopt a
change that needs no dataplane call), marks the key busy, issues the
call, and the callback applies the outcome and re-enters converge.
There is no queue: a burst of events for one key collapses into its
latest want, so the writer is bounded by construction and spawns no
goroutines (CLAUDE.md rule 12).

A key changing hands keeps its block: the add refreshes the plugin's
stored interface, the opdb record is re-keyed from the old session to
the new one, and the HA mapping events say so. A failed add releases a
freshly allocated block and leaves a reused one where it was. A failed
delete leaves the block allocated and the opdb record in place; the
next holder of the key reuses and refreshes it, and the next restart's
restore sees it. A block the restore loop preserved for a session it
could not find has no holder: the session's restored event programs
it, the session's release tears it down through the same delete path
(the plugin's delete of a missing entry succeeds, which covers the
daemon-only restart where VPP still holds it), and a release by any
other session leaves it alone.

## Consequences

- Activate and release for the same subscriber cannot interleave, on
  any path, whatever the bus or the async transport reorder.
- A reused block is always programmed for its new holder, and the
  old session's release after a handover is a no-op instead of a
  teardown of the new session's mapping.
- The subscriber's opdb record follows the holder, so a session that
  took over a block survives a restart; before, the record stayed
  under the departed session and the takeover was lost on restore.
- The writer state is one small struct per subscriber with a mapping
  or a wanted one; keys with nothing wanted, programmed or held are
  dropped.
- Deterministic and bypass sessions go through the same writer for
  ordering and ownership. Deterministic mode still passes no traffic
  (ADR 0006 conformance note); the writer changes nothing about that.
- Not covered here: the bus still fans out a goroutine per event per
  subscriber (todo item 11); the watchdog's RecoverDataplane still
  runs beside live handlers (audit D6); nothing yet reconciles the
  plugin's mapping table against the allocator, which remains the
  safety net for a delete that failed at the transport.

## Alternatives considered

- **A per-key FIFO of operations:** needs a depth bound and a drop
  policy; a dropped release leaks a block until restart and a dropped
  activate leaves the subscriber untranslated. Collapsing to the
  latest wanted state has no such choice to make.
- **One mutex held across the dataplane round trip:** serialises every
  subscriber behind every other and holds a lock across I/O, which
  rule 12 bans.
- **Keying release by session id and leaving the rest:** fixes the
  handover teardown but not the release that lands inside the add
  window or the delete reordered behind the add.
- **Waiting for the bounded per-subscriber bus delivery (todo 11):**
  ordering at the bus would still leave the async callback windows
  and the ownership question open; the writer is needed either way.
