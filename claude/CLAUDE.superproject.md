# osvbng

Read context/CLAUDE.md before changing anything: it carries the
working rules, the ADR index and the writing style for this tree.

Layout: this repo is the control plane and orchestration; vpp/ is the
dataplane submodule (plugins and the VPP build); context/ is the
decisions submodule. Submodules check out detached: branch INSIDE the
submodule you are changing, PR that repo, then bump the submodule
pointer here in a separate focused commit.
