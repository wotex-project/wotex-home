# Native MQTT publisher validation

Recorded: 2026-10-15. Implementation: Home main
`28cee3b50d8dd47c51989e17d5dd2240d951a7a8`.
Owner: [native MQTT publisher contract](../specs/mqtt-observation-publisher-v1.md).

## Implemented path

One explicitly started native Publisher owns one local IPv4 TCP/verified-TLS
EMQTT connection. Actual EMQTT callbacks record original monotonic delivery
times and unsigned host receipt ordinals before bounded handoff. Public WoTEx
JSONProjection produces exact values; SourceOwner/ReportOwner hold the checked
source and original decoded reports. One owned worker passes only original IDs
through Authority to the real Store. There is no worker database connection,
bearer, implicit current target, continuous-device-sequence assertion or
automatic reconnect.

Source selection, source-custody byte accounting and retained input witnesses
now allow one wrapper depth level around their independently checked reader.
Reader/consumer/report ceilings remain unchanged. RetainedSource separately
checks the same reader and policy at depth eight; its input wrapper allows nine.
Existing source hashes and historical runtime witnesses remain unchanged.

The native composition entry exists; immutable installed MQTT configuration,
credential brokerage, native operator setup and installed-host lifecycle are
separate unfinished delivery work. These checks do not qualify a physical
sensor, broker fleet, source age, autonomous reported edges or physical dispatch.

## Dependencies and reviewed upstream changes

EMQTT is exact Hex 1.16.1. Both lockfiles add only emqtt 1.16.1, gun 2.7.0,
cowlib 2.21.0, getopt 1.0.3, quicer 0.2.15 and snabbkaffe 1.0.10; all old lock
entries are unchanged. The package's ordinary app requires Gun; this publisher
uses only EMQTT's TCP/TLS connect, never its WebSocket/HTTP/QUIC entry points.
BUILD_WITHOUT_QUIC=1 applies in every environment; quicer's resolver entry is
compile/app/runtime-disabled. Tests confirm quicer is not loadable. Runtime
license texts for EMQTT/Gun/Cowlib/Getopt are copied into their exact release
applications by the shared host/firmware hook, checked without a release build.

The primary [EMQTT tag](https://github.com/emqx/emqtt/tree/1.16.1),
[1.16.0 comparison](https://github.com/emqx/emqtt/compare/1.16.0...1.16.1)
and package sources were reviewed. The release raises the minimum OTP to 27,
corrects macOS CI toolchains and exposes WebSocket upgrade limits. Home uses
OTP 28.5.0.6; its closed TCP/TLS configuration exposes no WebSocket overrides.
The selected Gun/Cowlib package metadata, sources, license/readme inputs and
upstream HTTP-header fix were checked; Getopt supplies the package CLI rather
than this native publisher. Snabbkaffe's included changelog records the OTP 27
reserved-word fix and trace helpers; no Home trace API is adopted. Quicer is a
disabled resolver dependency, not a delivered transport or native build.

Hex still flags Gun/Cowlib for
[CVE-2026-43966](https://cna.erlef.org/cves/CVE-2026-43966.html), involving
untrusted structured HTTP header serialization. The reviewed
[Gun change](https://github.com/ninenines/gun/commit/4f35609eb37109b106a863fc9ba83d7ee64e3e42)
and [Cowlib discussion](https://github.com/ninenines/cowlib/pull/166)
do not justify calling the resolved dependency graph advisory-free. This
publisher has no HTTP, structured-header or WebSocket input/path. Expanding that
surface requires a new dependency/advisory review; no cached source was patched.

Root lock SHA-256:
`3de9b75ee702ed6bd95f846b2681b071c1e8266cd2daa4615bf625f55741f913`.
Nerves lock SHA-256:
`05a334979d42c0717e7df1c0f85e1bb6529d9b370acb9f871fba3750c8afc34f`.
Owned producer source pins remain the exact cohort recorded in the
[preceding validation](mqtt-producer-cohort-2026-10.md). The new WoTEx source
still needs the user's manual remote push before a clean remote fetch. Native
dependency caches were seeded from that exact owned local commit, without
changing their canonical remotes. This is local committed-source validation.

## Executed acceptance evidence

On root Elixir 1.19.6 / OTP 28.5.0.6, 29 focused publisher tests passed through
the actual EMQTT client and independent literal MQTT 3.1.1 broker frames:

- MP-T1: reviewed raw imports, inspection, maintenance, local digest approval
  and current target selection in actual SQLite; exact 250/260 raw integer
  projections normalize to 25000/26000 through public interpretation/consumer
  units. Two channels retain one frame ordinal and original receipt time.
- MP-T2: closed/current native configuration, nonlocal/unavailable interface,
  invalid port/provider/TLS shape, unsolicited topic, 65537-byte raw payload,
  oversized wire packet, four raw callback credits, four frame batches including
  active work, an individually valid decoded value exceeding enclosing report
  bytes, uint64 maximum/overflow, accepted QoS-zero grant, refused QoS-two/failure
  grants and nonzero Session Present. Overflow/capacity retires rather than wraps
  or evicts. Existing generic selector/JSON edge vectors belong to cohort tests.
- MP-T3: frozen independent ordinary/retained/DUP/both/missing/malformed traces;
  publisher suspension proves callback time precedes later processing; all
  client/source/report/Store losses close the real connection. Killed admission
  work reconciles the same original and returns the unchanged durable receipt.
  A five-second blocked worker becomes uncertain; reconciliation after the
  original freshness interval refuses instead of manufacturing a new clock.
- MP-T4: real verified TLS with credentials, wrong CA/name and expiry before
  any MQTT CONNECT, raw-TCP credential refusal, independently killed hung
  credential provider, actual EMQTT debug delivery and gen_statem/proc_lib crash
  diagnostics with payload/reason canaries, an unrelated retained log, and a
  conflicting primary filter left intact. Client TLS diagnostics are disabled
  locally so hostname rejection cannot log the private requested name.

Nineteen related source/report-owner, producer-absence, producer-cohort and
release-component tests passed. Seven cohort tests passed again after extending
all six new dependency-lock parity and QUIC build/runtime-option assertions.
These are overlapping focused checks, not a full-suite count.

Root format, warnings-as-errors compilation and Git whitespace checks passed.
Nerves host lock validation succeeded after exact-cache seeding; its four real
producer dependencies compiled, then host compilation passed warnings-as-errors
on its declared OTP 29.0.4 / Elixir 1.19.6 toolchain. Initial cache failures and
stale BEAM warnings were resolved by forcing the exact owned producer sources;
EMQTT's OTP 29 dependency compilation emitted two upstream exported-variable
deprecation warnings. No dependency source was changed or warning hidden.

The docs-only agent improved two existing custody headers and four new MQTT
headers. Its AST checks show no behavior changes; the audit found 304 test,
support and migration modules using moduledoc false plus one following blank.
Metadata checks pass for 22 working-tree contracts and 21 staged contracts;
252 local Markdown references in the initial seven staged documents resolve.
Two current-target/TLS cases passed again after making the test's private
temporary path portable (27 other cases excluded in that focused rerun).
Full suite, Dialyzer, assembled releases, native installed UI, firmware boot and
physical qualification were not run at this component milestone.
