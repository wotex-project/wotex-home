# Exact MQTT producer cohort and historical runtime identities

Version: 0.1.0. Updated: 2026-10-15. Status: accepted successor target.
Owner: WOH.03 H03-T7, WOH.18 H18-T11/T12, WOH.16 release source inventory.
Implementation: planned. Evidence: frozen predecessor identity/wire witnesses only.

## Result and ownership

Home adopts the exact generic MQTT JSON projection and Runtime exact JSON decoder
from owned WoTEx source `687a5cd70267fa47dbfb36e28eccad6ef2964fdf`, while retaining
readability of previously recorded producer identities. No broker, connection,
source, report, current selection, semantic profile, clock confidence, grant or
physical dispatch is created by dependency resolution.

The [prior adoption](producer-cohort-adoption-v1.md) owns the unchanged Git/path
source switches and ExBooking/ExMaude/UDP pins. The [installed runtime contract](installed-profile-runtime-v1.md)
owns exact per-application compiled inventories, historical wire shapes and
current revalidation. This successor changes historical source-revision syntax
validation, not current-source comparison or the contents of old records.

## Exact source selection

**MC-01.** Core, Runtime, Profiles and the newly added wotex_binding_mqtt use the
same source above, each with its exact sparse directory under packages/. Add
MQTT to MixProject.source_pins and producer_package_paths so ordinary source
staging, release Git checks and package-root LICENSE/NOTICE copying cover it.
Root and Nerves lockfiles select the same four actual Git tuples. Existing
compatible transitive tuples remain unchanged; MQTT uses the already locked
Jason. No MQTT client/backend dependency is introduced at this stage.

Both normal and WOTEX_HOME_GIT_DEPS=1 builds use the selected exact source.
Only the existing explicit development path override can use a neighbor, and
such a build still cannot assert a production runtime revision. No moving ref,
vendored substitute, ambient source search or invented Hex version is accepted.
The three-application ProducerIdentity inventory remains core/Runtime/Profiles;
MQTT belongs to complete release inventory and its separately qualified protocol
source, not a silent fourth field in existing five-string wire identities.

Read each selected owned package's changelog and intervening public changes.
WoTEx's new generic additions are Runtime Codec.JSON and MQTT JSONProjection;
current native JSON transport behavior and old WPF contracts remain unchanged.
A source revision identifies code, not a release or physical qualification.

The selected commit is initially local: GitHub's commit API on 2026-10-15 returned
422 for its abbreviated SHA. Local checks may seed exact Git objects from the
owned repository into dependency caches, preserving the canonical origin and
verifying every checked-out HEAD. This is local source evidence only. Clean
remote installation remains unavailable until the user manually pushes WoTEx.
The agent must never push or change repository visibility. This limitation does
not prevent local implementation, tests or logical local Home commits.

## Historical representation versus current authority

**MC-02.** ProducerIdentity.valid?/1 and from_wire/1 accept a runtime assertion
with exactly format, source_revision and the three runtime SHA fields. Format
is wotex-home.profile-producer-runtime@1; source revision is exactly 40 lower
hex ASCII bytes, and each digest exactly 64 lower hex bytes. Retain the existing
five-string order and all legacy three-digest archive bytes. Unknown/extra/mixed
fields, structs, wrong format, malformed/upper/short/long revision or digest refuse.
A well-formed different revision is historical data, not invalid representation.
No filesystem, package lookup, producer call, clock or migration is involved.

ProducerIdentity.current/0 still supplies only the selected exact source and
actual compiled inventories. check_current/1 first validates representation,
then requires complete equality to that actual assertion. Any well-formed old,
future, unknown or substituted revision/inventory returns stale_profile_runtime;
malformed representation returns invalid_profile_producer. Path-selected builds
still return profile_runtime_source_unavailable for current construction/use.
Native Swift producer decoders apply the same closed representation grammar,
including any canonical lower-hex40 recorded revision. A client build does not
relabel that revision or compare it to its own producer pin; controller-side
current guards retain authority. Native live fixtures compare the returned
revision to the actual Store export, not a compiled fixture constant.
No historical assertion can install a current ReaderSelection or current
AuthoringContract, renew a source/review lease or authorize a new report.

Historical EnvelopeSummary, retained declaration/source/inspection and original
wire readers use representation validity and keep exact original fields/bytes/
hashes. Do not rewrite old revision strings to the current pin, invent archive
identities for old runtime records or rehash retained originals on upgrade.
New live reader/authoring/source construction continues to call current checks.
No schema/table, backup manifest, SQL row, original namespace or grant is added.
An old release may refuse the newer current assertion; no downgrade compatibility
or restored authority is inferred.

## Entry and acceptance

Before changing pins/code, retain the actual predecessor assertion from Home
86408cb using old WoTEx ba8ea373244ce57987f47a731b8eca3ccae9b45f on Elixir 1.19.6 /
OTP 28.5.0.6. Freeze its five strings and independently assembled canonical wire,
retained-source document and all source/reader/policy hashes under
`test/fixtures/profiles/historical-runtime.json`. Synthetic source/profile inputs
come from existing independently retained profile fixtures. These are software
history witnesses, not physical source assertions or a full deployed DB upgrade.

| Case | Requirements | Stimulus and falsifier | Level |
| --- | --- | --- | --- |
| MC-T1 | 02 | Predecessor literal producer/wire, native decoding, EnvelopeSummary and retained source round-trip unchanged after the pin advances; malformed variants refuse. Rewriting identity/hash or producer lookup during historical decode fails. | Independent historical/software |
| MC-T2 | 01/02 | Actual checked-out HEADs/lock tuples, current three-app inventories, old/future revision current refusal, path-build refusal; old current reader/contract construction refuses. Accepting a historical identity as current fails. | Locked source/runtime |
| MC-T3 | 01 | Public exact JSON/JSONProjection vectors under Home's actual OTP lane, unchanged WPF/occurrence controls; release legal roots and committed Git staging include MQTT. Float conversion, endpoint install, changed unrelated lock tuple or missing legal/source input fails. | Consumer/software |
| MC-T4 | 02 | Existing external original/outcome, installed Host and source/report/Store lifecycle regressions retain archived identities and fail-closed current guards. A new source, grant, renewed freshness or enabled dispatch from adoption fails. | Focused regression |

Run the appropriate formatter, warnings-as-errors compiler, spec/reference checks,
focused tests and Git whitespace checks. Full suite, Dialyzer, clean remote install,
complete native release and installed/physical source qualification remain distinct
milestone obligations; none is inferred from this adoption.

## Sources

- Generic Runtime [exact JSON contract](https://github.com/wotex-project/wotex/blob/main/docs/packages/wotex-runtime/specs/WRT.06-json-values-v1.md)
  and MQTT [projection contract](https://github.com/wotex-project/wotex/blob/main/docs/packages/wotex-binding-mqtt/specs/WBM.04-exact-json-projection.md), implemented in the exact selected source.
- [Installed runtime identity](installed-profile-runtime-v1.md) and
  [original adoption evidence](../provenance/producer-cohort-adoption-2026-10.md):
  history assertions, current source/build identity and release custody remain separate.
