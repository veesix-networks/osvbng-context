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

## Design notes

| Doc | Topic |
| - | - |
| [osvbng-implemented-summary](design/osvbng-implemented-summary.md) | Orientation summary of the implemented system |
