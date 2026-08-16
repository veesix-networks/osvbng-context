# osvbng context - working notes for Claude and every other LLM

This repo is the entry point for LLM-assisted work on osvbng. Check it
out first (it rides as a submodule of the main osvbng repo), read this
file fully, and read the ADR index before changing anything anywhere
in the osvbng tree. Decisions made here bind all three repos: osvbng
(control plane and orchestration, mostly human-driven), osvbng-vpp
(dataplane plugins and the VPP build), and this one.

## Where to open the agent, and session config

Open Claude at the root of the main osvbng checkout (the superproject),
so one session sees the control plane, the vpp/ submodule and this
context/ submodule together. Run `context/scripts/setup-claude.sh`
once after cloning: it installs the versioned `.claude/settings.json`
and a short root `CLAUDE.md` (both gitignored in the superproject, so
they never spam its history) from `context/claude/`. Session config is
version-controlled HERE and re-running the installer is how drift gets
fixed. Submodules check out detached: branch inside the submodule you
are changing, PR that repo, then bump the pointer in the superproject
as a separate focused commit.

## How work flows

- Decisions are ADRs in `decisions/`: numbered, append-only, one file
  per significant or hard-to-reverse decision, indexed in README.md
  (checked by scripts/check-adr-index.sh). A changed decision is a NEW
  ADR superseding the old one. When a session makes an architectural
  decision, it writes the ADR in that session, not later.
- Living design notes go in `design/`; the working queue is todo.md.
- There is no spec-NNN workflow. It is replaced by ADRs plus
  purposeful comments at the point of use: code should carry enough
  context that a fresh session can re-orient by reading it.
- LLM-heavy work (plugins, docs, decisions, tooling) lands in
  osvbng-vpp and this repo. The main osvbng repo receives focused,
  human-reviewed PRs; keep its history quiet.
- osvbng pins vpp and context at exact commits. After a change merges
  in either, osvbng still builds the old one until the pin moves: run
  `make bump-submodules` in the superproject, then PR the bump. Pins
  move deliberately, not on every child commit, so a checkout stays
  reproducible.

## Rules for LLM sessions (non-negotiable)

1. **Never over-engineer.** Complexity buys its way in with a current,
   stated need. When two designs work, ship the one with less
   machinery.
2. **Know the problem being solved.** If you cannot say in one
   sentence what breaks or who is blocked without a change, stop and
   find out. PRs lead with the problem.
3. **No protocol code from memory.** The spec text (RFCs in
   `references/`) is open while writing, and every behavioral branch
   cites its section. This includes code that looks finished: verify
   claims against the text, not recollection.
4. **No invented policy.** When the design has a gap (a default, an
   identity, a limit nobody chose), the code refuses the case honestly
   and the gap goes to a maintainer or an ADR. Never fill it inline.
5. **Code lives with its domain; main packages are wiring only.**
   Anything that parses, validates, transforms or decides belongs to
   the package that owns the concept, where it has tests. Enforce
   mechanically where the language allows (import-boundary and
   wiring-only tests in CI, uncached).
6. **Identity is never node-local.** Nothing that names a subscriber,
   circuit, port or session outside one machine may be an interface
   index, a pool index, or a per-box name. Operator-assigned role
   names cross machine boundaries; each machine keeps its own mapping
   private. Test: if this workload moved to another node, does the
   value still mean the same thing?
7. **No scripted source transforms.** Never rewrite source files with
   python/sed/regex pipelines; edits go through proper editing tools,
   file by file, reviewable.
8. **Verify against reality.** A change is done when it runs against
   the live rig (containerlab plus bngblaster for anything a
   subscriber touches), not when it compiles or its unit tests pass.
   Report outcomes exactly: failed means failed, skipped means
   skipped.
9. **Upstream what belongs to VPP.** A fix or feature that is about
   VPP itself, not about osvbng, goes to fd.io first; it lives in our
   patch queue only until it merges upstream, and the patch header
   records the gerrit link and status. Local-only needs a stated
   reason. We take from the commons, so we give back to it, and a
   short queue is a queue that survives version bumps (ADR 0002).
10. **Plugins serve any control plane, not just osvbng.** A plugin is
    a general VPP dataplane building block: its .api, node graph and
    shared-memory protocols are the whole contract, and nothing in a
    plugin may assume osvbng specifically is the control plane above
    it. Every plugin carries a capability/version query so any control
    plane can discover it; osvbng-specific policy lives in the control
    plane, never baked into the dataplane. This keeps the plugins
    reusable and forces the clean control/dataplane seam that makes
    them correct.
11. **Public thread comments identify the model and keep the agent's
    voice.** Any comment, review, or reply an LLM session posts on a
    public issue or pull request names the model plainly, for example
    "Reviewed with Claude Fable 5", so contributors always know when
    they are reading an agent and every session does it the same way.
    The comment speaks as the agent: findings, verification results
    and requests, stated plainly. It never makes offers or
    commitments in the maintainer's voice ("happy to add this",
    "we will fix that"); scheduling follow-up work is the
    maintainer's, unless they directed the commitment. This is the
    one deliberate exception to the no-AI-markers rule, which keeps
    governing commits, code, docs and PR descriptions.
12. **Hot paths respect the core budget.** The whole control plane
    runs on about one core (ADR 0007); anything per packet, per
    session or per event competes for it during a storm. A hot
    path never blocks on observability or on a lock held across
    I/O; every queue is bounded with a chosen full behavior; no
    goroutine per packet, session or event; storm-shaped logging
    is sampled, never per-event. The rules and the profiling
    evidence behind them are in design/performance-and-logging.md;
    profile before optimizing.

## Writing style (code comments, commits, PRs, docs)

Plain engineering language, written for the next reader, not for
show. Comments exist only for what code cannot say: the invariant,
the why, the constraint, the ADR or RFC section that governs.

Banned everywhere: narrating what a line does; filler ("simply",
"just", "basically", "note that", "in order to", "it's worth
noting"); marketing adjectives ("robust", "elegant", "powerful",
"seamless", "comprehensive"); rhetorical scaffolding ("Importantly",
"Additionally" chains); restating a function's signature above it; em
dashes, en dashes, arrows, checkmarks, emoji. Hyphens and commas.

The keep test for any comment: delete it, and if the reader lost no
fact, leave it deleted.

Commits are Conventional Commits, title only, imperative, lowercase
scope, no attribution trailers of any kind, no AI markers. PRs state
the problem first, then the change, then how it was verified,
including what was NOT verified.

Line wrapping follows what renders the text. Wrap plain text a
terminal shows raw: commit message bodies at about 72 columns. Do not
hard-wrap what a renderer reflows for the reader: PR and issue
descriptions are Markdown on the web, so write them as one line per
paragraph and let the column reflow, because a hard newline
mid-paragraph only fights the renderer. In a committed .md, follow the
file's existing convention; do not reflow a wrapped file or wrap an
unwrapped one to change its style.

## Public repositories

Everything in the osvbng tree is public GPL-3.0-or-later. Write in
the project's voice; nothing may read as machine-generated. No
internal or business references of any kind: no customer names, no
private-repo mentions, no absolute local paths. Vendor documentation
is never committed (redistribution); RFC texts are fine
(IETF-licensed for reproduction).
