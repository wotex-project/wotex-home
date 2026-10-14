# Explicit installed profile runtime and host wiring

Version: 0.1.0. Updated: 2026-10-14. Status: accepted successor target.
Owner: WOH.18 H18-08/09, WOH.16 source/runtime identity and WOH.08 host lifecycle.
Implementation: planned. Evidence: missing.

## Result and boundaries

Trusted Host startup can supply supported bindings, accepted Home meanings,
reader limits and an explicit capture to the one Store. A supervised bounded
source/report custody pair can receive publications from one explicitly named
live trusted publisher. No HTTP, discovery, Markdown loader, default sensor
mapping, device write, grant or profile approval is created by startup.
Ordinary Host startup with no installation retains its current unavailable
authoring/reader/source behavior. Installation is a trusted native input, never
a socket, CLI, profile, model or paired-client request.

The [producer cohort](producer-cohort-adoption-v1.md) supplies exact locked
core/Runtime/Profiles source ba8ea373244ce57987f47a731b8eca3ccae9b45f.
AuthoringContract, ReaderSelection and ExternalEnvelope retain public producer
reconstruction. SourceOwner and ReportOwner retain their own bounded transient
custody and permissions. Only Store opens SQLite, authenticates principals and
commits history. Publisher receives neither a Store connection nor a bearer.

## Producer identity: history versus current runtime

**IP-01.** Introduce one shared closed ProducerIdentity grammar. The existing
archive assertion remains exactly core_archive_sha256, runtime_archive_sha256
and profiles_archive_sha256, each lower hex64. Its unchanged three-element
ordered wire value remains core/runtime/profiles. Existing independent archive
vectors, history, quarantine and hashes must remain byte-identical.

An ordinary installed runtime uses exactly format, source_revision,
core_runtime_sha256, runtime_runtime_sha256 and profiles_runtime_sha256.
Format is wotex-home.profile-producer-runtime@1; source_revision is the selected
lower hex40 source above. Each runtime SHA is the actual RuntimeArtifacts.digest
of its single fixed application (wotex, wotex_runtime or wotex_profiles) with
domain wotex-home.profile-producer-runtime@1. RuntimeArtifacts retains its
complete deterministic BEAM inventory and loaded/file checksum comparison;
native/OS libraries and transitive numeric packages retain the broader runtime
qualification obligations. These values are compiled runtime identities, never
raw source/archive hashes or authenticity evidence. The revision records the
trusted locked build's selected source, not proof of reproducible compilation.
No caller chooses an application/module name or digest domain.

The runtime ordered wire value has exactly five strings in the order format,
source_revision, core_runtime_sha256, runtime_runtime_sha256,
profiles_runtime_sha256. No mixed archive/runtime shape, extra key, alternate
format, wrong revision, uppercase digest, native struct or malformed list is
accepted. Historical decoding validates representation only and performs no
filesystem, producer or current runtime lookup. Current runtime construction
recomputes all three application inventories and compares the full assertion;
drift refuses stale_profile_runtime, absent/unreadable code refuses
runtime_artifact_unavailable. Archive assertions remain explicit test/consumer
inputs under their existing separate archive-verification obligations.

Apply the shared grammar to authoring contract, reader, envelope, retained read
declaration, retained source and inspection summary/wire boundaries. Changed
producer identities change their existing complete basis hashes. Existing
three-element originals cannot be reinterpreted as runtime assertions. No
schema/table is added; tagged new producer wire values are new originals.
An older release that cannot decode them must refuse/quarantine rather than
rewrite them or manufacture legacy archive assertions. Native generic catalogue
validation must admit each exact supported shape without discarding identity.

## Trusted startup input

**IP-02.** Host.start_link/1 accepts optional profile_installation, nil by default.
A supplied native map contains exactly installed, capture, reader_limits,
authoring_limits and publisher. installed contains exactly bindings, contracts
and home_contracts; producer is supplied by the runtime factory, never the
caller. Lists, references, binding bodies and capture obey ReaderSelection.new/3.
Capture contains exactly binding, capture_epoch, digest and fields and is
explicit trusted host evidence; it establishes syntax/correspondence, never
physical authenticity or qualification. Authoring limits contain exactly reader,
max_bundle_bytes, max_diagnostics, max_report_bytes and max_check_steps under
AuthoringContract ceilings; its reader must exactly equal reader_limits.
Publisher is one live PID, not a name, endpoint, credential, module or callback.
No defaults are inferred inside a supplied map; unknown keys, structs, duplicate
keyword options and malformed configuration refuse invalid_profile_installation.
Inherited resource/runtime/producer failures retain their typed outcomes.

Prepare the complete pure configuration before creating a data directory,
Store, private profile namespace or socket. Reconstruct both values through
their public APIs with the same installed runtime assertion and reader limits.
Store receives authoring_contract, authoring_capture, external_reader and the
fixed supervised source/report owner names. An absent installation passes nil
for all five options, including owner names; it starts no source/report child.
Host exposes only current custody owner PIDs through trusted in-process accessors.
There is no external installation/configuration API or application-env fallback.

**IP-03.** Store ownership and ordinary custody/reviews precede SourceOwner;
ReportOwner follows SourceOwner and receives the actual current Store PID and
source-owner PID. Both precede delivery/API consumers in the rest_for_one tree.
Use the owners' existing ceilings/defaults, temporary restart policy and
publisher monitors; installation supplies no quota overrides. Neither owner
auto-publishes selections or reports. Store restart discards all transient
snapshots/leases/receipts; surviving retained target originals are history and
cannot use an old custody epoch as current evidence. Custody restart similarly
retires downstream transient work. Publisher loss stops both temporary owners;
later reads/commits fail closed. It does not repeatedly restart with a dead PID
or republish old captures. Explicit full Host reinstallation with a current
publisher/configuration is required after temporary owner retirement.

## Acceptance and limits

| Case | Requirement | Setup, expectation and falsifier | Level |
| --- | --- | --- | --- |
| IP-T1 | 01 | Existing archive wire vectors decode/re-encode identically; new runtime assertion uses actual per-app inventories, roundtrips both ordered shapes, rejects mixed/extra/revision/digest fields and changed runtime assertion. Historical validation still works without producer lookup. Hash alias or archive relabel fails. | Software |
| IP-T2 | 01/02 | Two independent fixture binding/meaning families construct reader/authoring under actual runtime identities. Invalid configuration refuses before any new directory/Store/socket. No-config host preserves existing unavailable operations and disabled dispatch. | Actual locked consumer/Store |
| IP-T3 | 02/03 | Start Host, inspect actual source/report child ownership, publish from selected publisher and reject another caller; source/report begin empty. Restart Store then require fresh custody epochs and no old sources/receipts; retained history survives. Kill publisher and observe unavailable custody with no automatic publication/restart. | Actual supervised software |

Focused checks include shared codecs, locked producer integration, actual Host
restart tree and existing authoring/inspection/read originals. Native catalogue
decoding/typechecking is a bounded client check. No full release, installed
signing, fresh-account lifecycle, transport qualification or physical source is
established by these cases. Accepted broader host source/meaning delivery still
requires actual protocol publishers, private configuration delivery and current
device review/qualification; this boundary supplies no synthetic default device.
