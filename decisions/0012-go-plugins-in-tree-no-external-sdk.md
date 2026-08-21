# ADR 0012 - Go plugins are in-tree, pkg/ is not an external SDK

- Status: Accepted
- Date: 2026-08-21
- Deciders: Brandon

## Context

osvbng's `docs/architecture/PLUGINS.md` presents the Go plugin
surface as an SDK for out-of-tree authors: a cookiecutter scaffold
(veesix-networks/osvbng-plugin-cookiecutter) generates a plugin that
registers itself through `component.Register`, `conf.RegisterFactory`
and `show.RegisterFactory`, and the document prescribes 37 symbols
from `pkg/` that such a plugin calls. The dead code audit of August
2026 (design/dead-code-audit-2026-08.md) leaned on that claim to keep
several symbols with no in-tree caller, and verification showed the
claim does not hold.

How plugins actually load: `cmd/osvbngd/main.go` blank-imports
`plugins/all`, which blank-imports every plugin package, and each
plugin registers in `init()`. There is no shared-object loading, no
`plugin.Open`, no dynamic discovery. A plugin exists only if its
package is in the tree when osvbngd is built. The scaffold itself
generates into `plugins/community/` of the main repo; it was never
an out-of-tree mechanism, only a template for in-tree code.

State of the claim at the audit commit: 15 of the 37 prescribed
symbols no longer exist. The packages `pkg/cli`,
`cmd/osvbngcli/commands`, `pkg/state` and `pkg/state/paths` were
removed in May and June 2026, `logger.Component` in February, and
the document names `conf.RegisterPluginConfig` where the package is
`configmgr`. The scaffold imports the removed packages and has not
compiled against the tree since 2026-06-28 at the latest. Nobody
noticed, because no plugin was ever generated from it outside the
main repo and no repository in the workspace imports the module. The
in-tree `plugins/community/hello` plugin compiles on every build and
is the only template that has kept up.

The plugin rules in CLAUDE.md (rule 10) concern VPP dataplane
plugins, whose contract is their `.api`, node graph and shared-memory
protocols, published so any control plane can drive them. Nothing
equivalent was ever defined for the Go side: no version, no
stability policy, no CI that compiles an external consumer. A
promise with none of that behind it is a promise the tree cannot
keep, and the cost of pretending otherwise is real: dead symbols
kept "for plugin authors", a guide that misleads the next
contributor, and a scaffold that produces code that does not build.

## Decision

**Go plugins are in-tree. A plugin is a package under `plugins/`,
registered in `init()` and reached by blank import from
`plugins/all`; it lands by pull request like any other code and is
compiled by every build. `pkg/` is the tree's internal API: it
changes by PR together with its callers, carries no stability
promise to code outside the tree, and no symbol is kept alive for a
hypothetical external consumer.**

The living template is `plugins/community/hello`. PLUGINS.md is
rewritten as the in-tree plugin guide against the current tree
(osvbng#501). The cookiecutter repository is retired with a pointer
and archived. Where a dead-code decision once read "keep, documented
SDK", the only grounds to keep a symbol are an in-tree caller, a
test that asserts on live behaviour through it, or a recorded
decision with a consumer named and pending, as ADR 0009 records for
the telemetry push path.

## Consequences

- The dead-code ratchet (osvbng#502) needs no SDK exception; every
  baseline entry names its reason, and "plugin authors may call it"
  is not one.
- A third party who wants a plugin contributes it upstream under
  `plugins/community/`, where the build keeps it honest. Private,
  unpublished plugins are not supported; anyone who needs one carries
  a fork and the cost of tracking `pkg/`.
- PLUGINS.md shrinks to what the tree does: registration, config
  registration, handler factories, the show and conf path types, and
  the hello plugin as the worked example. The 15 stale symbols go
  with the rewrite (osvbng#501).
- The cookiecutter's README points here and at the hello plugin;
  archiving the repository is a maintainer action, as it was for the
  plugin repos that moved into osvbng-vpp.
- Offering an external Go SDK later is a new ADR, and it starts with
  what this one found missing: a stability policy for the exported
  surface, a versioned release of it, and CI that compiles a
  consumer outside the tree on every change.

## Alternatives considered

- **Maintain the SDK properly:** compile the scaffold's output in CI
  on every change and adopt a stability policy for `pkg/`. Rejected:
  seven months without a consumer; complexity with no current
  requirement behind it (rule 1).
- **Load plugins as shared objects (Go `plugin` package):** rejected.
  It pins the plugin to the exact toolchain and dependency versions
  of the host binary, so it is in-tree in every way that matters,
  with cgo coupling added; and nothing asked for it.
- **Keep the claim and fix the 15 symbols:** rejected. The scaffold
  rotted in four months with no consumer to notice; without a
  consumer it will rot again, and the guide would mislead the next
  contributor the same way.
