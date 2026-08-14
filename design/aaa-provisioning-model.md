# AAA and provisioning model

This note describes how osvbng provisions subscriber sessions: AAA is
the source of truth for addresses, routing, and policy, and the
access protocols consume its output. Read it before working on AAA
providers, service groups, DHCP profiles, the shared allocator, or
the IPoE and PPPoE session paths.

## Provisioning-first

AAA, whether local, HTTP, or RADIUS, is the source of truth for
subscriber IP allocation, service parameters, and session policy.
DHCP and IPCP/IPv6CP are protocol adapters that synthesize
protocol-specific responses from provisioned attributes.

The primary path is AAA returning the provisioning data: IP, DNS,
gateway, VRF, service group. Local pool allocation is a convenience
fallback, a built-in provisioning source for lab, dev, and small
deployments without an OSS/BSS backend. A profile with no pools is
valid: if AAA returns no address and no pools exist, the session is
rejected. The BNG cannot provision what it does not know.

The allocator in pkg/allocator/ is shared and protocol-agnostic:
DHCP and PPPoE use the same allocator instances for a profile's
pools, so pool logic is not duplicated across protocols.

## Internal attribute model

All internal attribute names are string constants in pkg/aaa/. They
are the contract between auth providers and the control plane, and
they are osvbng's own canonical namespace, not RADIUS attribute
names. Groups:

- Network: ipv4_address, ipv4_netmask, ipv4_gateway, dns_primary,
  dns_secondary, ipv6_address, ipv6_prefix, ipv6_wan_prefix,
  ipv6_dns_primary, ipv6_dns_secondary
- Service and routing: service-group, vrf, unnumbered, urpf,
  routed_prefix (from Framed-Route)
- ACL and QoS: acl.ingress, acl.egress, qos.ingress-policy,
  qos.egress-policy, qos.upload-rate, qos.download-rate
- Session: session_timeout, idle_timeout, acct_interim_interval
- Pool and profile overrides: pool, iana_pool, pd_pool
- Credentials: username, password, chap-id, chap-challenge,
  chap-response
- Identity passed to providers: circuit_id, remote_id, hostname
- L2 wholesale: the l2gw.* namespace (see the wholesale L2 note)

Each provider owns a translation layer that maps its native attribute
format to these constants. The HTTP provider extracts values from
response JSON via JSONPath, with default mappings for RADIUS-like
field names (framed_ip_address maps to ipv4_address) plus
per-deployment custom mappings. The RADIUS provider maps AVPs in
three tiers: RFC standard attributes (hardcoded), MS-DNS vendor 311
(hardcoded), and user-defined mappings via raw vendor_id/vendor_type
with optional regex extraction, which covers vendor AVPair-style
attributes. The local provider stores internal names directly.
Protocol handlers and the service group resolver see only the
internal constants, never provider formats.

## Three-layer override merge

The service group resolver in pkg/svcgroup/ merges three layers,
lowest priority first:

1. Default service group from subscriber group config (static YAML,
   default-service-group)
2. Service group named by the AAA service-group attribute
3. Per-field AAA attributes (vrf, acl.ingress, qos.download-rate,
   and so on)

Per-field attributes always win. The merge is field-level: only
attributes the provider explicitly returned override, unset fields
inherit from the service group. AAA can therefore return a service
group plus any combination of per-subscriber exceptions, or skip the
service group entirely and set individual fields. This applies
equally to RADIUS VSAs and local provider attributes.

## Service groups

A service group is a named bundle of per-subscriber forwarding
policy: vrf, unnumbered (gateway loopback), urpf mode, ingress and
egress ACLs, ingress and egress QoS policies, and upload and download
rate limits. All fields optional. Directions are wire directions on
the session interface: egress is toward the subscriber (download)
and ingress is from the subscriber (upload); the split allows
asymmetric policy.

AAA returns a name, osvbng resolves it locally. Without this, AAA
would have to return raw infrastructure attributes (VRF names,
loopback numbering) for every subscriber, which is fragile,
repetitive, and makes infrastructure renames a per-subscriber AAA
change. Vendor BNGs solve the same problem with dynamic templates
(IOS-XR), dynamic profiles (Juniper), and subscriber/SLA profiles
(Nokia).

Subscriber groups define the access side (VLAN match, profiles,
BGP); service groups define per-subscriber forwarding policy. At
session programming time the resolved group drives VPP: the VRF name
resolves to a FIB table ID, the unnumbered loopback supplies the
gateway, and QoS, ACLs, and uRPF are applied to the session
interface. Config load validates that referenced VRFs, loopbacks,
ACLs, QoS policies, and default-service-group names exist.

## Allocator context, the AAA to DHCP bridge

pkg/allocator/ carries a Context built from the AAA response plus
subscriber group config: session identity (MAC, VLANs), VRF,
subscriber group, service group, profile names, provisioned
addresses, DNS, gateway, and pool override names.

- If AAA returned ipv4_address or ipv6_prefix, pool allocation is
  bypassed entirely. If the address falls inside a pool range it is
  reserved so the pool cannot double-allocate it.
- If AAA returned pool, iana_pool, or pd_pool, those override the
  profile's default pool selection.
- DNS, gateway, and netmask from AAA pass through to response
  synthesis and override profile defaults.

DHCP profiles supply the delivery defaults AAA did not: gateway
(typically the unnumbered loopback IP), DNS, lease and preferred and
valid times, address model (unnumbered-ptp /32 with RFC 3442 Option
121 default route, or connected-subnet), and fallback pools. Profile
selection is static on the subscriber group; AAA can override fields
within a profile but never which profile applies. Bindings are typed
as lease (pool-allocated) or reservation (AAA-provided), and a
reservation conflict rejects the static session with a critical log
rather than evicting the dynamic one.

## Allocation timing, IPoE vs PPPoE

Both access types publish an AAARequest event; the AAA component in
internal/aaa/ calls the configured provider and publishes the
response on an access-type-specific topic. The difference is when
addresses are needed.

IPoE (internal/ipoe/): the DHCP exchange drives everything. The
username is derived from DHCP options (60/77) or the MAC. On auth
success the component resolves the service group, builds the
allocator context, and resolution runs inside DHCP reply synthesis,
so the address (AAA-provided or pool-allocated) lands in the OFFER
and ACK. The DHCP provider is a pure adapter: given a resolved plan
it reserves the IP and builds the response, otherwise it only renews
existing leases.

PPPoE (internal/pppoe/): authentication happens at the LCP phase, via
PAP password or CHAP challenge and response, before any address
negotiation. On success the session stores all AAA attributes, builds
the allocator context, and answers PAP-ACK or CHAP-Success. The
addresses are consumed later when IPCP and IPv6CP negotiate, straight
from the context, with the shared allocator as fallback when AAA
provided no address. No DHCP is involved.

## Provider architecture

Providers implement the AuthProvider interface in pkg/auth/
(Authenticate plus Start/Update/StopAccounting) and register by name
through a factory. AuthRequest carries username, MAC, session ID,
VLANs, interface, subscriber group, and protocol attributes;
AuthResponse is an allow decision plus internal attributes.

HTTP (plugins/auth/http/): template-driven endpoint, headers, and
request body (Go templates), JSONPath attribute extraction, TLS with
CA and client certificates, Basic and Bearer auth. Allowed decision
defaults to HTTP status (200 allowed, 401/403 denied) or a custom
JSONPath condition. Accounting POSTs start, interim, and stop events
with counters, also template-driven.

RADIUS (plugins/auth/radius/): native client with persistent UDP
connections, identifier-based correlation (256 concurrent slots per
connection), PAP encoding per RFC 2865 section 5.2 and CHAP support,
ordered server failover with dead server detection and cooldown
recovery, and accounting Start/Interim/Stop with per-server stats
exposed via a show handler. Dynamic authorization (RFC 5176) is
implemented: a CoA/Disconnect-Message listener (default port 3799)
with an allowed-clients list and a replay window accepts Disconnect
and CoA requests and feeds them into the subscriber mutation path.

Local (plugins/auth/local/): SQLite users and services with
attribute merge (service attributes by priority, user attributes
override), PAP and CHAP, and an allow_all mode for dev. Accounting is
a stub.

The AAA policy system (pkg/config/aaa/) shapes what providers see.
Policies are typed dhcp or ppp, selected per subscriber group, and
build the username from a format string with variables such as
$mac-address$, $svlan$, $cvlan$, $remote-id$, $circuit-id$, and
$hostname$; PPPoE agent tag variants take precedence over DHCP
Option 82 values. Policies can set authenticate: false for
attribute-only lookups, cap concurrent sessions per subscriber, and
override the device identity (NAS-Identifier, NAS-IP) per policy for
wholesale and multi-tenant setups, with arbitrary metadata exposed to
HTTP templates.

Accounting interim updates are spread across 12 five-second buckets
over a 60-second cycle, each session hashed to one bucket, so every
session reports once per minute without a thundering herd.
