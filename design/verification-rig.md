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

## What this means for a session

CI on a pull request gates on build and unit tests only; the
integration suites run post-merge on a self-hosted runner. So
"verified" in a PR body can never mean "CI will catch it": run
the suite covering the touched area locally before calling work
done, and anything a subscriber touches runs against bngblaster.
Pick the suite by number from the catalog in the methodology doc,
or add one when no suite covers the behavior. Report results
exactly: which suite, pass or fail, and what was not run.
