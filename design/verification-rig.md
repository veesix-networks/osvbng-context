# Verification rig

Rule 8 says a change is done when it runs against the live rig.
This note maps that rig so a session can find and run the right
suite. The authoritative description lives with the code in
`osvbng/docs/qa/testing-methodology.md` (suite catalog, HA
testing, dataplane performance testing, release qualification);
this note does not duplicate it.

## Shape

Every integration suite is a directory under `osvbng/tests/` named
`NN-topic` (01-smoke through the l2tp, cgnat, ha, routing and api
suites, 40 plus of them) containing a containerlab topology
(`NN-topic.clab.yml`), a Robot Framework suite (`NN-topic.robot`)
and its config tree. Shared keywords live in `tests/*.robot`
(common, sessions, localauth, restart, l2gw). The topology runs
the locally built osvbng image against real peers: FRR core
routers, bngblaster subscriber simulation, FreeRADIUS, Kea for
relay and proxy, xl2tpd as an external LAC for the LNS suite.

## Running

From the osvbng repo:

    make robot-test suite=NN-topic

or directly, `./tests/rf-run.sh ./tests/NN-topic/`. The runner
creates its own venv and writes results to `tests/out/`.

## What the rig proves, and what it does not

The rig's dataplane is not built from osvbng-vpp at test time. The
image is stock VPP debs at the pinned version plus plugin binaries
committed by hand under `osvbng/test-infra/vpp-plugins/`, produced
by an osvbng-vpp release build at some past commit. That set
includes a rebuilt `af_packet_plugin.so`, which is the only way
the osvbng-vpp patch queue reaches the rig at all: the stock debs
do not carry the patches.

So a green suite proves osvbng HEAD against that binary drop, not
against osvbng-vpp main. When either repo has moved since the last
drop, a pass says nothing about the current pair. Before treating
a result as proof, check the drop's freshness
(`git log -1 -- test-infra/vpp-plugins/` in osvbng) against what
changed in osvbng-vpp, and state the dataplane provenance in the
PR's verification section. For a change in osvbng-vpp itself, the
rig only exercises it after a fresh drop built from that change.
The standing fix is todo item 2: one release build produces
version-stamped artifacts and the rig consumes those, removing the
hand-copied binaries.

## What this means for a session

CI on a pull request gates on build and unit tests only; the
integration suites run post-merge on a self-hosted runner. So
"verified" in a PR body can never mean "CI will catch it": run
the suite covering the touched area locally before calling work
done, and anything a subscriber touches runs against bngblaster.
Pick the suite by number from the catalog in the methodology doc,
or add one when no suite covers the behavior. Report results
exactly: which suite, pass or fail, what was not run, and which
dataplane drop it ran against.
