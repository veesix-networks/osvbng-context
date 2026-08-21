# Dead code audit, August 2026

A dead-code audit of osvbng was written on 2026-08-18 from
`golang.org/x/tools/cmd/deadcode` at commit 4db1384 (branch
fix/ipoe-session-limit-counter-leak): 143 functions, 103 unreachable
with tests as roots and 40 kept alive only by tests, each traced to
the commit that orphaned it and classified as delete, fix instead,
keep as SDK, keep as test seam, or decide. Every claim in it was then
re-checked against the code and against this repo: commit SHAs by
`git show`, "never called" claims by pickaxe filtered to non-test
files, claimed replacements by caller grep, RFC citations against the
texts in references/, and intent against the ADRs and design notes
here and the legacy context tree (pre-ADR layout, main at 865944d,
todo.md item 10). The tool output was reproduced exactly at 4db1384
and again at origin/main b1eb14c3, 48 commits later, with no change:
nothing flagged has been deleted or wired since.

The result: every "Delete" verdict holds, and the two bugs the audit
found are real with qualifications. The prose around the verdicts is
unreliable. About a third of the history narratives are wrong, several
RFC citations are wrong, two stated mechanisms are false, and the
"protected by a documented SDK" argument is void. Three "Decide" items
are already decided in ADRs or specs. Verification found three more
defects the audit did not see; the worst sits behind a symbol the
audit marked "Delete".

This note is the durable record. Line references are to osvbng at
4db1384 and will drift; search by symbol when they do. Everything
here is desk work against code, plugin C and upstream VPP source.
Nothing was run on the rig.

No item below is actioned until a contributor has marked it approved
in the sign-off table at the end, by PR to this file. The audit text
itself is not committed: this note supersedes it, and committing
prose with known-wrong claims would feed them back into every future
session as context.

## Fix order

1. Guard the PPP dispatcher against a short declared Length. A frame
   with Length 0 to 3 passes both checks at
   `internal/ppp/dispatcher.go:92-99` (payload at least 4 bytes,
   Length not greater than payload) and panics at
   `payload[4:length]`. No `recover()` exists in cmd/ or internal/;
   the path is reached from `internal/pppoe/component.go:547` on
   punted subscriber frames. One condition. Proved on an exact copy
   of the parse, not on the rig.
2. Decode HA CGNAT checkpoints with the codec that wrote them.
   `pkg/ha/sync_receiver.go:260` stores `proto.Marshal(cp)`;
   `internal/cgnat/component.go:595` reads it back with
   `json.Unmarshal`, which always fails, so `tryRestoreSyncedMapping`
   always returns false and HA-synced mappings are never restored on
   the new active. Both sides from f04e43ce (#188), unchanged on
   main. Suites 12 and 13 release sessions before switchover, so
   they never exercise it. The audit's "Delete" item
   `pkg/ha/cgnat_sync.go checkpointToMapping` is the missing decode
   step.
3. Call `logger.Sync()` on daemon shutdown. Both log formats go
   through a diode ring (100000 entries, 10 ms poll); `Sync` is
   `diodeWriter.Close()`, which drains before returning. Never called
   in any commit since c980a891 (#217). Shutdown
   (`cmd/osvbngd/main.go:719-740`) flushes telemetry and nothing for
   logs, so "osvbng stopped" and any error from `orch.Stop` or
   `vpp.Close` almost never reach stdout. The legacy async-logger
   decisions named graceful shutdown as a purpose of `Sync`.
   `log.Fatalf` exits bypass the diode too; a deferred Sync does not
   help those.
4. Reverse service-group state at session teardown, in the owning
   component. No Go code removes uRPF or ACLs after
   `svcgroup.ApplyToSession`. On PPPoE the plugin parks the interface
   (down, HIDDEN, hw_if_index on a reuse list,
   `osvbng_pppoe.c:505-541`), no delete callback fires, and the next
   subscriber on that interface inherits the previous uRPF mode when
   its own group has uRPF off (`apply.go:52-53` issues no call for
   off). On IPoE the plugin deletes the interface and VPP clears
   feature arcs, but the urpf plugin keeps
   `urpf_cfgs[af][dir][sw_if_index]` with no interface hook, so on
   index reuse in the same VRF with the same mode `urpf_update` takes
   the no-change path and the feature is never re-enabled: the new
   session silently has no uRPF. ACLs cannot leak today on either
   plugin because `aclRegistry` is never populated (`RegisterACL` has
   no callers). The audit's proposed fix site,
   `internal/subscriber/component.go releaseSession`, is wrong: it
   holds only the group name, not the resolved group with
   AAA-supplied `urpf`, and both components delete the VPP interface
   before publishing Released. Spec 93 and ADR 0003 put the inverse
   in component teardown. The IPoE half needs the rig and probably an
   upstream urpf fix (rule 9). VPP read at upstream master and a
   26.06 tree, not the pinned build.
5. Fix the L2TP CDN result codes. `pkg/l2tp/result_codes.go` has
   NoDialTone=8, Timeout=9, NoFramingDetected=10; RFC 2661 section
   4.4.2 has busy=8, no dial tone=9, timeout=10, no framing=11. Busy
   is missing and `CDNString` mislabels three codes.
   docs/configuration/l2tp.md:70's trigger list (02,04,05,06,10)
   disagrees with the legacy RND section 11, with `DenylistForCDN`
   (4,5,6) and with the spec YAML. todo.md item 7's scope; do it
   before the denylist work that builds on it.
6. The mechanical deletion PR, with the corrected list below.
7. Finish the L2TP surface the code already half-carries (section
   "L2TP"): outbound StopCCN and CDN, the denylist feed, the LAC
   ppp-framing wire-up. The v3 reject is dropped (decision 9).
8. The decisions at the end, each its own ADR or todo line.
9. A deadcode ratchet in osvbng CI: `deadcode -test ./...` diffed
   against a committed baseline, fail when a PR adds a symbol, so
   residue is removed in the PR that introduced it. The baseline
   shrinks with item 6; what is deliberately kept stays in it with a
   one-line reason.

## Found during verification, not in the audit

Items 1, 2, 4 (IPoE half) and 5 above. Smaller:

- `pkg/models/system/system.go:4` has a malformed struct tag
  (`json: "threadId`, a space after the colon) that encoding/json
  silently ignores.
- `.golangci.yml` excludes a non-existent `tools/generate_plugin`;
  `api/proto` is exempt only by generated-header detection.
- `docs/architecture/PLUGINS.md` prescribes 37 symbols of which 15 no
  longer exist: the packages pkg/cli, cmd/osvbngcli/commands,
  pkg/state and pkg/state/paths, plus `logger.Component` and
  `conf.RegisterPluginConfig` (the package is configmgr). The
  cookiecutter scaffold (veesix-networks/osvbng-plugin-cookiecutter,
  2026-02-01) imports those deleted packages and has not compiled
  against the tree since 2026-06-28 at the latest.
- `docs/architecture/COMPONENTS.md:151` names `auth.RegisterProvider`
  and `cache.RegisterProvider`; neither exists.
- `docs/configuration/l2tp.md:3-5` still says the LNS role is on the
  roadmap. `pkg/l2tp/avp_catalog.go:12` cites RFC 2661 section 4.1
  for unknown-mandatory-AVP handling; it is 4.2.
  `internal/l2tp/dispatch.go:30-31` says v3 detect-and-reject is
  handled by the punt plugin; the punt plugin only demuxes on the T
  bit.
- Legacy spec 99 DECISIONS F2 chose `ppp.MakeLinkLocalAddress` over
  the negotiated IPv6CP interface ID as the RA source; #385 used
  `ra.LinkLocalFromMAC(bngMAC)` instead, unrecorded. Equal by
  construction today; a peer Configure-Nak of the BNG's IID would
  desynchronise them. F2 accepted that risk for a standard CPE.

## Corrections to the audit's action plan

- Deletion PR: remove `checkpointToMapping` from the list (it is the
  fix for item 2). `WithGARPCollector` reverses a recorded decision
  (legacy HA_GARP_SPEC.md:75 kept it as a test seam); decision 13
  below deletes it and this note is the record of the reversal. Also
  delete
  `operations.Dataplane` (interface, not flagged because tools do not
  report unused interfaces); the legacy SOUTHBOUND_SDK_REFACTOR.md
  Phase 5 scheduled its removal and the audit calls it optional. The
  `paths.Build/Extract` wrappers can go without an ABI caveat; the
  only external consumer uses the `Path` type alone and is already
  broken.
- Bug fixes: the uRPF fix belongs in component teardown, not
  `releaseSession`; the ppp-framing LAC wire-up belongs in
  `internal/l2tp/lac.go tryLACTunnel` next to
  `lookupConfiguredSourceIP` (:465), not in aaa.go, because
  `ParseTunnelSpecs` has no config access.
- "Decide" items already decided: the telemetry push path is in ADR
  0009's Decision section (keep unless a superseding ADR says
  otherwise); the VRF validator hook is a rejected alternative in ADR
  0005 (delete); the GARP seam was kept by HA_GARP_SPEC (reversed by
  decision 13). The PPPoE error tags are not an RFC-completeness
  marker (see below); the gap is the absent Service-Name policy,
  which no spec planned.
- The only genuinely open questions were whether `pkg/` is a
  supported out-of-tree SDK at all, and whether the telemetry push
  path stays. Both are decided below; the SDK answer becomes an ADR.

## Per-cluster verdicts

CONFIRMED: the action and its stated reasons hold. PARTIAL: the
action holds, a stated fact is wrong or a material fact is missing.
WRONG: the action or a load-bearing claim is wrong.

### cmd/osvbngcli and dataplane adapters

| Symbol | Audit | Verdict | Notes |
| - | - | - | - |
| cmd/osvbngcli/tree.go, 9 funcs | Delete | CONFIRMED | f6e4609 intro, never edited; callers gone in a66a7a3 (#275); d694f98 (#389) missed it; successors live. Legacy archive/architecture/old/cli.md and spec 26 corroborate (spec 26 planned to modify tree.go; the implementation replaced it). The file also holds ArgumentType and three ArgKeyword constants. |
| operations.MockDataplane | Delete | PARTIAL | History wrong: NewConfigManager never took a dataplane parameter in any commit; the configmgr test referencing the mock never compiled until acd84d4 (#218), the commit that first ran go test in CI. |
| vpp.getInterfaceAddresses | Delete | CONFIRMED | ba8b594 (#105); the ip_types import becomes unused. |
| northbound Adapter.valueToString | Delete | CONFIRMED | 86e9883; the encoding/json import becomes unused. |

### pkg/telemetry

| Symbol | Audit | Verdict | Notes |
| - | - | - | - |
| help, labelNames on Counter/Gauge/Histogram, fakeMetric | Delete | CONFIRMED | Line ref is metric.go:75-76, not 78-79. |
| RegisterCounter/Gauge/Histogram, MustRegisterHistogram, AppendSnapshot | Delete | CONFIRMED | "Referenced only by docs" overstated: only RegisterCounter and AppendSnapshot appear in TELEMETRY.md; registry.go:16-18,35-37 comments still prescribe the package-level functions (legacy spec 49 D8 convention, never followed). |
| Subscribe, SetTickInterval | Decide | PARTIAL | Zero production consumers confirmed. The dirty-flag tick is in ADR 0009's Decision section; ADR 0009 Consequences and design/telemetry.md:35-41 record it as built and waiting for gRPC/gNMI exporters (todo.md item 4). Removal is a superseding ADR. "~150 lines" understates: markDirty is inlined in every emit path, two internal metrics and Shutdown depend on it. |
| SetUnboundedLabels | Keep SDK | PARTIAL | TELEMETRY.md:94 says the list "can be replaced", not an instruction. Legacy spec 49 D7 and ADR 0009 say tunables are wired from osvbngd main, which never happened. design/telemetry.md rule 2 says do not weaken the reject list; this is the one call that can. |
| WithDecoder | Keep SDK | PARTIAL | Keep is right: legacy spec 59 kept it deliberately as the documented stop-gap. Two reasons wrong: obsoleted by spec 59's typed FRR surfaces (f0fdc422, d4f53cb9), not by the walker in 6173696; the walker does not panic on non-struct types, it skips them (show_walker.go:305-337) and polls are recover-wrapped (show.go:164-168). |

### Registries and component

| Symbol | Audit | Verdict | Notes |
| - | - | - | - |
| provider.Registry | Delete | PARTIAL | "Never had a caller" wrong: pkg/auth was built on it from the initial commit until 31c915c1 (#13), and its Factory signature matched the original auth factories. Orphaned since #13. |
| opdb.ProviderRegistry | Delete | CONFIRMED | Legacy archive/ha-design/OPDB.md design, superseded by spec 93 and ADR 0003. IPoE and PPPoE restore via RecoverSessions from main.go; only CGNAT in Start(). |
| vrfmgr.Get, Set | Delete | CONFIRMED | Legacy spec 40 DECISIONS C2 prescribes injection; ed9e597 (#296) dropped the designed post-vrfmgr validation pass for cfg.VRFLookup(), leaving Get with no consumer. |
| component.Get, List, AllMetadata | Delete | CONFIRMED | Range ":67-105" wrongly spans the live GetMetadata (:86-92). |
| component.WithConfig | Delete | CONFIRMED | Dead at birth (same commit 31de0174 as the reflect registry), not replaced. |
| auth.Get, List | Decide | CONFIRMED | Both had callers until #13 (List only for an error message). No plan for a provider listing in either tree. |
| StateFileWriter.Path | Delete | CONFIRMED | |
| ReadStateFile | Keep test | PARTIAL | The duplicate reader is pkg/upgrade/health.go:255 (not :102, the struct); 7 test call sites, not 5. |

### L2TP

| Symbol | Audit | Verdict | Notes |
| - | - | - | - |
| BuildStopCCN, BuildCDN | Fix instead | PARTIAL | Nothing sends StopCCN or CDN, in Go or in the plugin (the control channel is entirely userspace). Stronger than stated: RFC 2661 section 7.2.1, local termination MUST send StopCCN; legacy IMPLEMENTATION_SPEC:330-331,579-580 and RND.md:276-278 specified outbound StopCCN for SCCRQ reject (result code 4) and challenge mismatch; lns.go:44 promises "the caller emits StopCCN" and dispatch.go:146-152 does not. Profile.SessionLimit is never read. Spec-named suites lns_unknown_peer_reject, lns_v3_reject, lac_tunnel_auth_fail do not exist. Section numbers wrong: StopCCN is 6.4, CDN is 6.12 (the audit's 6.7 and 6.9 are ICRP and OCRQ). |
| BuildV3RejectStopCCN, appendResultCodeAVP | Fix instead | PARTIAL | Stub confirmed (dispatch.go:171-177 returns ErrV3Unsupported). The v3 reject is a project decision (legacy RND section 14, D13, DECISIONS G2), not RFC-mandated (section 3.1: unknown Ver MUST be discarded). Not a small change: the builder emits a full datagram and SendControlFn prepends its own header. |
| DenylistForStopCCN, DenylistForCDN, ResultCode strings | Fix instead | CONFIRMED, defects missed | PeerDenylist live (lac.go:84,88); Add and Remove uncalled; the Result Code AVP is never parsed; DenylistConfig read nowhere. Legacy RND.md:358-368, DECISIONS C6, README Phase 5.7; Phases 5.8-5.10 "Not started", never descoped. Missed: the classifiers return DenylistTunnel but PeerDenylist is IP-keyed, so wiring needs a design decision; CDN constants off by one (fix order item 5). |
| ResolvePPPFramingLAC | Fix instead | PARTIAL | No-op confirmed and the knob is real (lac.go:160,380; the plugin's l2tpv2_encap_raw.c:153-157 acts on ppp_hdr_skip). Fix site is tryLACTunnel, not aaa.go. design/l2tp-architecture.md:74-77 covers the LNS server knob, which is LAC-side config. |
| KernelUDPTransport.Feed, Close | Delete | CONFIRMED | The Close deadlock holds only because Feed is never started. Legacy spec 40 cites the file only as the netns pattern. |
| BuildSCCCNWithParams, MessageTypeName, DecodeUint32 | Delete | PARTIAL | "3 small tests" wrong: one dedicated test, one assertion, none for BuildSCCCNWithParams. |

### pkg/ppp

| Symbol | Audit | Verdict | Notes |
| - | - | - | - |
| ParsePAPPacket, ParseCHAPPacket, ParseIPv6CPPacket, error types | Delete | CONFIRMED | Never called in any commit. These were never the live parse: b04c735 shipped the inline parse in session.go:69-79 and dae651d only moved it to internal/ppp/dispatcher.go (legacy L2TP spec D4). Orphans 4 tests, not 3. Same short-Length bug as the dispatcher (fix order item 1). |
| EchoHandler | Delete | CONFIRMED | Not line-for-line: the prod copies match each other and EchoHandler drops sub-4-byte requests. ADR 0011 moves echo into osvbng_pppoe, so the prod Go echo path is itself transitional. |
| MakeLinkLocalAddress | Delete | PARTIAL | Not the same algorithm as ra.LinkLocalFromMAC (caller-supplied IID vs MAC EUI-64); see the spec 99 F2 note above. Safe to delete: prod never converts a negotiated IID. |
| ParseCompression, ParseMAC | Delete | CONFIRMED | |
| ParseMRU, ParseMagic, ParseAuth, ParseIPAddress, ParseDNS, ParseInterfaceID | Keep test | CONFIRMED | 15 call sites, 12 asserting on live encoder output. |

Totals: test lines 233 not ~215, production ~95 not ~103. No Go
test in internal/pppoe or internal/l2tp references LCP echo; robot
coverage is indirect through bngblaster keepalive settings.

### DHCP, ARP, PPPoE

| Symbol | Audit | Verdict | Notes |
| - | - | - | - |
| dhcp.BuildUDPPacket, checksum helpers | Delete | PARTIAL | Born dead in f6e46097; a3992d2 (#216) never touched it. gopacket is still the serializer in internal/ipoe/dhcpv4.go:846-868, ra, arp, pppoe and shm ingress; todo.md item 11 plans single-parse through gopacket. A third IPv4/UDP builder (dhcpv4.go:846-868) was not counted. |
| pkg/arp | Delete | PARTIAL | "ARP moved to internal/arp" wrong: both were in the bootstrap; pkg/arp only served a duplicate responder inside internal/ipoe removed in e690c1a (#41). ADR 0010 puts internal/arp on the retirement path once the dataplane responder ships. |
| relay.GetGIAddr, GetHops | Delete | PARTIAL | "Reply routing uses OptServerID" conflates the reply source IP with XID correlation. No RFC 1542 hop check was ever planned. |
| TagBuilder.AddServiceNameError, AddACSystemError | Decide | WRONG on the RFC | RFC 2516 section 5.2: an AC that cannot serve a PADI MUST NOT respond with a PADO, so both PADI drops are conformant. The only MUST is Service-Name-Error in a PADS when the AC rejects the PADR's Service-Name, and osvbng never evaluates Service-Name (it echoes it, component.go:847,874). AC-System-Error is MAY. "Parse side live" is hollow: tags.Errors is written and never read. |

### pkg/upgrade

| Symbol | Audit | Verdict | Notes |
| - | - | - | - |
| SignalGuard | Delete | PARTIAL | Facts hold. Framing wrong: legacy spec 102 IMPLEMENTATION_SPEC:436-471,981,1011 specified signal.go and the CLI hook as one design; the implementation wired only the CLI side. |
| NewHealthChecker, NewSupervisor, NewExecCommander | Delete | CONFIRMED | 18 lines not ~21; NewExecCommander's doc says "Use this in production". |
| RecordingReporter | Keep test | CONFIRMED | Dropping HasEvent means editing TestRecordingReporterCapturesEverything. |

The "5-scenario QEMU suite" is from 539d09b2 (#375), local-only, and
its README records scenario 01 as blocked; it is not evidence of a
production-active path. Tier B is untouched.

### config, configmgr, paths, handlers

| Symbol | Audit | Verdict | Notes |
| - | - | - | - |
| configmgr.ResolveWildcardKeys | Delete | CONFIRMED | c2225cde; legacy spec 59 D11 replaced the need and its deletion list omitted wildcard.go. |
| configmgr.DecodeCandidatePluginConfig | Delete | CONFIRMED, caveat WRONG | "May be intended to return" is contradicted by ADR 0005, which records the per-plugin hook as a rejected alternative. |
| configmgr.parsePrefix | Delete | CONFIRMED | |
| configmgr.FormatDiff | Delete | PARTIAL | Never had a caller at any commit; "the CLI renders client-side" has no code behind it (cmd/osvbngcli has no diff consumer at HEAD or in history). |
| GetAllPluginConfigs, ParseUint16, ParseInt, ExtractInterfaceName, GenerateDaemons, boolPtr | Delete | CONFIRMED | ParseUint32 has 14 callers, not ~30. boolPtr is an unused test helper. |
| paths Build/Extract wrappers, pkg/paths.Path, ShouldEncode | Decide | PARTIAL | "Callers settled on methods for Build" is true only for conf; oper and show never had a Build method. ShouldEncode was not re-implemented as show/paths/wildcards.go (that file is a WildcardType enum duplicating encoding.go:10-27, divergently). The plugin-ABI caveat is unsupported: PLUGINS.md and the cookiecutter use only the Path type. |
| DataplaneConf.Generate | Keep test | CONFIRMED | |

### Scattered

| Symbol | Audit | Verdict | Notes |
| - | - | - | - |
| logger.Sync | Fix | CONFIRMED | Fix order item 3. |
| svcgroup.ReverseFromSession | Fix | PARTIAL | Fix order item 4. |
| subscriber countActiveSessions, interfaceExists | Delete | PARTIAL | Born dead in f6e46097, never "the original counter". Range is 593-647. |
| ha.checkpointToMapping | Delete | WRONG | The missing half of fix order item 2. |
| ha.WithGARPCollector | Delete | PARTIAL | Never wired, but legacy HA_GARP_SPEC.md:75 decided to keep it as a test seam. |
| allocator.prevAddr | Delete | CONFIRMED | Adopted in #164 and orphaned by #213, not "never adopted". |
| MakeIPoESessionID, MakePPPSessionID, models.SessionStats, BindingType.String, logger.WithSession, NewRADIUSStatsWithRegistry, auth/http FormatError | Delete | CONFIRMED | |
| logger.NewTest | Keep test | CONFIRMED | 22 sites. |
| allocator.ResetGlobalRegistry, NewTestRegistry | Keep test | PARTIAL | Each serves one package; NewTestRegistry does not touch the singleton. |

### Blind spots and method

| Claim | Verdict | Notes |
| - | - | - |
| Build tags, GOOS | CONFIRMED | One `//go:build ignore`. Linux-only via netlink NeighSubscribe (pkg/evpnmgr), SetPromisc and SO_BINDTODEVICE; cgo via the typed use of go-sqlite3 in pkg/opdb/sqlite, no in-module `import "C"`. |
| "58 Robot suites", zero Go | PARTIAL | Zero Go holds; 60 .robot files, 54 with test cases, 55 numbered directories. |
| Reflection, templates, StaticVRFs | CONFIRMED | 170 template identifiers reproduced; StaticVRFs is address-taken in a FuncMap literal, so reachability analysis keeps it. |
| Generated code exempt | PARTIAL | api/proto is exempt by header detection only. |
| linkname, RPC dispatch, init() registries | CONFIRMED | All 349 registry calls are inside init(). |
| Cookiecutter SDK protection | WRONG | The scaffold has not compiled since June and uses no flagged symbol. The telemetry symbols are prescribed by TELEMETRY.md, which equally prescribes the flagged AppendSnapshot, SetTickInterval and RegisterCounter. No ADR or design note declares pkg/ a supported out-of-tree SDK. |
| No other repo imports the module | CONFIRMED | |
| Toolchain | PARTIAL | The audit ran in a go 1.25 container; the project pins 1.24.0. No difference at 1.24.11. |

## Not verified

- Nothing ran on the live rig. Every defect above is a static
  reading.
- VPP plugin behaviour (urpf, acl, feature arcs) was read at upstream
  master and a 26.06 tree, not the pinned build.
- Out-of-tree consumers other than the cookiecutter were not searched
  for.
- The five QEMU upgrade scenarios were not run.

## Decisions, 2026-08-21

Made by the maintainer against the recommendations in this note.
Each entry carries where to start and how it is verified, so a
fresh session can take an item without the audit. Item numbers
match the sign-off table.

1. PPP short-Length guard: approved. Start at
   `internal/ppp/dispatcher.go:99`: reject Length below 4 beside the
   existing Length-above-payload check; unit test in
   dispatcher_test.go with Length 0 to 3 and a valid frame.
   Verification is the unit test and green suites; bngblaster cannot
   craft the malformed frame.
2. HA CGNAT decode: approved. Start at
   `internal/cgnat/component.go:595`: `proto.Unmarshal` into
   `hapb.CGNATMappingCheckpoint`, then `checkpointToMapping` from
   pkg/ha (export it or move it). Verification on the HA rig: a
   variant of suite 12 or 13 that keeps sessions established across
   switchover and asserts the mapping is restored on the new active.
3. logger.Sync: approved. Start at `cmd/osvbngd/main.go` after
   `logger.Configure`: `defer logger.Sync()`. Verification: "osvbng
   stopped" in the container log after a graceful stop.
4. Service-group reversal at teardown: approved. Start in the
   internal/pppoe and internal/ipoe teardown paths, before the VPP
   interface call, using `svcgroup.ReverseFromSession` with the
   resolved `svcgroup.ServiceGroup` the session was set up with
   (carry it on the session; do not re-resolve from config, AAA can
   supply `urpf`). Verification on the rig: a subscriber with urpf
   strict disconnects, the next subscriber on the reused interface
   with urpf off forwards traffic a strict check would drop.
5. IPoE uRPF on index reuse: approved, two parts. Item 4's reversal
   before delete covers osvbng. The urpf plugin's missing
   `VNET_SW_INTERFACE_ADD_DEL` hook goes to fd.io gerrit per rule 9,
   with the patch in the osvbng-vpp queue until it merges (ADR 0002).
6. L2TP CDN result codes: approved. Start at
   `pkg/l2tp/result_codes.go` with RFC 2661 section 4.4.2 open: add
   busy=8 and shift the three that follow; fix `CDNString`; in
   docs/configuration/l2tp.md:70 replace the trigger list with the
   RFC names and mark the denylist block as not wired until item 10
   lands. Unit test on the constants.
7. Deletion PR: approved, one PR. The list is the 103 from
   `deadcode -test ./...` at 4db1384 minus what other decisions keep:
   `checkpointToMapping` (2), `logger.Sync` (3),
   `ReverseFromSession` (4), `BuildStopCCN` and `BuildCDN` (8),
   `ResolvePPPFramingLAC` (11), `Subscribe` and `SetTickInterval`
   (12). Plus, from the 40 alive only by test: the pkg/ppp packet
   parsers with their error types, `EchoHandler`,
   `MakeLinkLocalAddress`, `ParseCompression`, `ParseMAC`,
   `SignalGuard` with signal_test.go, `MessageTypeName`,
   `DecodeUint32`, `BuildV3RejectStopCCN` (9), `SetUnboundedLabels`
   (12), and `containsSub` collapsed to `strings.Contains`. Plus the
   unflagged `operations.Dataplane` interface, and
   `WithGARPCollector` with its type, field and nil branch (13).
   Kept: the pkg/ppp option decoders, `DataplaneConf.Generate`,
   `ReadStateFile`, `RecordingReporter`, `logger.NewTest`, the
   allocator test helpers, `WithDecoder`, `appendResultCodeAVP`,
   `DenylistForStopCCN`, `DenylistForCDN` and the ResultCode and
   ErrorCode strings (10). Every orphaned test goes with its
   function. Verification: compile, vet, unit tests, the three CI
   tiers.
8. Outbound StopCCN and CDN: approved, after items 1 to 7, under
   todo.md item 7. Start at `internal/l2tp/dispatch.go:146-152`
   (SCCRQ reject, result code 4), `lns.go:150-154` and
   `lac.go:235-240` (challenge mismatch), `runner.go:135-138` (dead
   channel), `component.go:190` (Stop), with RFC 2661 sections 6.4,
   6.12 and 7.2.1 open; the builders are
   `pkg/l2tp/messages.go:133,217`. Verification: the three suites the
   legacy spec named and never got, lns_unknown_peer_reject,
   lac_tunnel_auth_fail and a teardown case, against bngblaster.
9. v3 graceful reject: rejected. RFC 2661 section 3.1 discards an
   unknown Ver, and a v2-format StopCCN is unreadable to an RFC 3931
   peer, so the reject does nothing on the wire. Delete
   `BuildV3RejectStopCCN` in item 7, keep the drop and its counter,
   and correct the comment at `internal/l2tp/dispatch.go:30-31`.
   Legacy D13 is superseded by this entry.
10. Denylist feed: approved, peer scope only. Where inbound StopCCN
    and CDN are handled (`internal/l2tp/lns.go:253,261` today; the
    LAC is the consumer at `lac.go:84`, so the LAC path must feed
    it): parse the Result Code AVP, classify with
    `DenylistForStopCCN` and `DenylistForCDN`, `denylist.Add` keyed
    by peer IP with the `DenylistConfig` TTLs. Drop the
    DenylistTunnel distinction (rule 1). Verification on the rig:
    bngblaster as LNS returning a denylist result code, the LAC
    skips that peer for the TTL.
11. ppp-framing at the LAC: approved. Start at
    `internal/l2tp/lac.go tryLACTunnel` beside
    `lookupConfiguredSourceIP` (:465): resolve with
    `ResolvePPPFramingLAC` and set `TunnelSpec.PPPHdrSkip`; drop the
    hardcode at `aaa.go:54`. Verification: suite 31 with a per-LNS
    override and a bngblaster LNS configured to match.
12. Telemetry: keep the push path under ADR 0009 and keep
    `WithDecoder` (legacy spec 59). `Subscribe` and `SetTickInterval`
    enter the ratchet baseline with the reason "ADR 0009 push path,
    consumer pending, todo item 4". Delete `SetUnboundedLabels`, its
    test and TELEMETRY.md:94: it was never wired and
    design/telemetry.md says the reject list must not be weakened.
13. GARP collector seam: delete with item 7. Legacy
    HA_GARP_SPEC.md:75 kept it as a test seam; no test uses it and
    the session iterators replaced it. This entry records the
    reversal.
14. `pkg/` as an out-of-tree SDK: retire the claim by a short ADR
    here. Go plugins are in-tree, compiled into osvbngd through blank
    imports with no shared-object loading, so an external plugin
    cannot exist without a fork; `pkg/` carries no external stability
    promise. PLUGINS.md becomes the in-tree plugin guide (item 16)
    and veesix-networks/osvbng-plugin-cookiecutter is archived.
15. `auth.Get/List`, the paths wrappers with `pkg/paths.Path` and
    `ShouldEncode`, the PPPoE error-tag builders, the DHCP relay
    getters: delete with item 7. None has a plan or an RFC behind it;
    Service-Name policy, if ever wanted, is a feature, not these
    eight lines.
16. Docs pass: approved, after item 14 for PLUGINS.md. The rest does
    not wait: COMPONENTS.md:151, TELEMETRY.md:94 (12),
    docs/configuration/l2tp.md:3-5 and :70 (6), the dispatch.go:30-31
    comment (9), `avp_catalog.go:12` section number.
17. deadcode ratchet: approved, right after item 7. In osvbng:
    `scripts/deadcode-check.sh` runs `deadcode -test ./...` with
    CGO_ENABLED=1 and diffs against a committed baseline; CI fails on
    any addition; each baseline entry carries its reason on the same
    line. The first baseline is what item 7 keeps.

## Sign-off

An item is actioned only after a contributor sets it to approved
here, by PR to this file. Status is one of proposed, approved,
rejected, done. Landed is the PR that closed it.

| # | Item | Kind | Status | Signed off | Landed |
| - | - | - | - | - | - |
| 1 | PPP dispatcher short-Length guard | fix, osvbng | approved | BSpendlove, 2026-08-21 | - |
| 2 | HA CGNAT checkpoint decode (proto, not JSON) | fix, osvbng | approved | BSpendlove, 2026-08-21 | - |
| 3 | logger.Sync at daemon shutdown | fix, osvbng | approved | BSpendlove, 2026-08-21 | - |
| 4 | Service-group reversal at teardown, PPPoE uRPF inheritance | fix, osvbng | approved | BSpendlove, 2026-08-21 | - |
| 5 | IPoE uRPF re-enable on sw_if_index reuse, item 4 plus an upstream urpf patch | fix, osvbng-vpp and upstream | approved | BSpendlove, 2026-08-21 | - |
| 6 | L2TP CDN result codes and the l2tp.md:70 trigger list | fix, osvbng | approved | BSpendlove, 2026-08-21 | - |
| 7 | Mechanical deletion PR, list as in decision 7 | delete, osvbng | approved | BSpendlove, 2026-08-21 | - |
| 8 | L2TP outbound StopCCN and CDN send path | finish, osvbng | approved, after 1 to 7 | BSpendlove, 2026-08-21 | - |
| 9 | L2TP v3 graceful reject at the dispatch stub | finish, osvbng | rejected, builder deleted in 7 | BSpendlove, 2026-08-21 | - |
| 10 | L2TP denylist feed, peer scope | finish, osvbng | approved | BSpendlove, 2026-08-21 | - |
| 11 | L2TP ppp-framing LAC wire-up in tryLACTunnel | finish, osvbng | approved | BSpendlove, 2026-08-21 | - |
| 12 | Telemetry: push path and WithDecoder stay, SetUnboundedLabels goes | decision | approved | BSpendlove, 2026-08-21 | - |
| 13 | GARP collector seam: deleted, HA_GARP_SPEC reversed here | decision | approved | BSpendlove, 2026-08-21 | - |
| 14 | pkg/ is not an out-of-tree SDK: ADR, PLUGINS.md rewrite, archive the cookiecutter | decision, ADR | approved | BSpendlove, 2026-08-21 | - |
| 15 | auth.Get/List, paths wrappers, PPPoE error tags, DHCP relay getters: delete with 7 | decision | approved | BSpendlove, 2026-08-21 | - |
| 16 | Docs pass: PLUGINS.md after 14, COMPONENTS.md:151, TELEMETRY.md, l2tp.md, dispatch.go comment | docs, osvbng | approved | BSpendlove, 2026-08-21 | - |
| 17 | deadcode ratchet in osvbng CI with a committed baseline | tooling, osvbng | approved, after 7 | BSpendlove, 2026-08-21 | - |
