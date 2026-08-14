# osvbng

The working rules, ADR workflow and writing style for this tree load
here from the context submodule:

@context/CLAUDE.md

Layout: this repo is the control plane and orchestration; vpp/ is the
dataplane submodule (plugins and the VPP build); context/ is the
decisions submodule. Read vpp/CLAUDE.md before touching dataplane
code. Submodules check out detached: branch INSIDE the submodule you
are changing, PR that repo, then bump the submodule pointer here in a
separate focused commit.
