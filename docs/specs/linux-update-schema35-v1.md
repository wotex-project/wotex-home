# Linux same-schema update profile for Store 35

Version: 0.1.3. Updated: 2026-10-14. Status: accepted successor target.
Owner: WOH.16 H16-T1/T2/T4; linux-release-update-v1 compatibility boundary.
Implementation: explicit cohort, historical verification and current update
guards implemented. Evidence: [executed focused software cases](../provenance/current-host-ci-remediation-2026-10.md); Linux-root/installed cases remain unexecuted.

The body below preserves the executed schema-35 contract. Its final annex
explicitly supersedes the current cohort with schema 36; every reference to
current schema 35 in the historical body is scoped to that earlier source.

## Purpose, inherited boundary and compatibility

New Linux service packages and development release updates select the explicitly
reviewed Store schema 35 cohort. Schema 35 adds retained inert authoring objects,
candidates/reviews, external inspections/trust/targets and observation originals
to the earlier schema 28 history. Existing core migration and backup contracts
own those rows and their integrity; this updater performs no database migration.

The [Linux update owner](linux-release-update-v1.md) continues to require exact
source/target inventory and bootstrap pins, root-owned administrative custody,
kernel process identity joined to the actual socket peer, current host:maintain
authentication, original epoch/revision and retained begin receipt, maintenance,
synced deny fence, stopped source cgroup and owned target switch. Acknowledged
service transitions do not establish device effects, installed qualification,
power-loss recovery or permission to replay uncertain work. Physical dispatch
remains disabled by default. No account, service or live controller is changed by
package assembly or these software checks.

The current cohort is a literal reviewed 35, never whatever Schema.current_version
happens to return. A future Store version makes assembly refuse until that cohort
has its own reviewed successor. Source and target must both declare exact current
schema-35 compatibility, and authenticated live Store status must equal 35 before
planning, recording a new begin, joined maintenance or target completion. These
requirements replace the old active schema-28 entry conditions; historical
schema-28 evidence in the owning document remains scoped to its original source.

## Exact metadata and transition requirements

**LS-01 — Emit and verify explicit metadata.** Newly assembled service manifest
format 2 contains update_compatibility exactly:

```
{"store_schema_version":35,"strategy":"same_schema_only",
 "update_guard_scope":"linux_release_update_guard",
 "update_guard_path":"/opt/wotex-home/update-guard.json"}
```

All other package fields, file bytes/modes, inventory checks and artifact identity
rules remain unchanged. Legacy format 1 packages retain their exact bytes and
verification. Historical format 2 with the exact same four-field record except
store_schema_version 28 also remains verifiable against its retained metadata.
Unknown/extra/floating/other-version compatibility refuses verification. Never
rewrite a retained 28 declaration to 35 or reinterpret verified package integrity
as current update eligibility. Existing source/core artifact identities exclude
the service manifest, as defined by the package owner; exact issued inventories
still bind its actual manifest bytes.

**LS-02 — Refuse cross-schema execution.** LinuxUpdateProcess.image must require
format 2 plus the exact current compatibility record for every source and target
image used by the update workflow. A historical 28 package may pass integrity
verification but must fail this current image gate before process/service work.
Planning, journal record_begin, maintenance status and source/target status guards
require integer live schema 35, writable Store and enabled update fence; floating
35.0, 28, 34, 36, unknown/nonwritable/unfenced or malformed status refuse.
Existing typed invalid_update_process_observation/invalid_update_journal or
update_compatibility_refused outcomes remain at their owning boundaries.

Exact journal lookup, original receipts and metadata inspection remain historical
reads. No new metadata version, SQL table, authority revision, repaired begin or
implicit maintenance end is introduced. An unfinished old schema-28 update can
be inspected but cannot resume under this active cohort. Original unknown service
or effect outcomes remain unknown; refusal never switches, stops, starts, sends
or rolls back automatically. A completed legacy administrative prefix remains
historical; future new work must independently satisfy current image/status gates.

**LS-03 — Check the actual current Store.** The embedded packaged Store probe
must independently assert the known schema-35 number after creation and restart
and run current integrity, original replay, schedule custody/backup and private
installation identity checks. Do not derive the expected version from the same
schema function under test. Historical schema-24 fixtures must remove all tables
introduced after their declared version, including schema 29–35 authoring and
external tables, before migration; changing only user_version is not a historical
fixture. Migration must preserve existing rows/revision and restore no authority.

## Failure, recovery and acceptance

Package assembly refuses a changed current schema before publishing service files.
Historical verification is producer-free metadata/inventory work and does not
start an executable. Active status checks never manufacture a schema assertion
from package metadata. Changed pins, ownership, credential, process incarnation,
epoch, maintenance barrier, fence or package bytes retain their existing refusal
and uncertain outcome. No 28-to-35 upgrade or 35-to-28 rollback is authorized.
Board/Linux disk-power-loss and signed installed release evidence remain separate.

| Case | Requirements | Stimulus and falsifier | Level |
| --- | --- | --- | --- |
| LS-T1 | 01/02 | New format-2 package declares literal 35 and verifies; exact historical 28 and format-1 package still verify, but only 35 is current image-compatible; tampered/extra/float/other version refuses. Any implicit migration or old-image execution fails. | Software/filesystem |
| LS-T2 | 02 | Actual Store returns 35 and its original maintenance begin survives discarded reply/restart. Wrong current schema/writability/fence/principal/epoch refuses new progress without journal, Store or service mutation. | SQLite/framed software |
| LS-T3 | 03 | Independent embedded probe checks 35 and current retained history; real schema-24 migration passes and corrupt migration rolls back DDL. Expected number borrowed from implementation, stale tables or widened activation fails. | SQLite/software |
| LS-T4 | 01/02 | Affected package/update planning, journal, maintenance, stop/switch/process suites preserve ownership/CAS/original behavior. Hardware/release qualification remains separately missing. | Software; installed remains required |

Implementation entry is the existing exact Schema 35 and its validated table set,
the existing package/manifest/journal codecs, and these fixed metadata vectors.
No new dependency or persistent encoding is needed. Record actual commands,
source/toolchain, passed cases and skipped platform/installed checks in provenance.

## Schema-36 preparation successor

The [generation preparation owner](generation-preparations-v1.md) allocates the
next actual schema 36. Before that schema is enabled, new package declarations,
current update image/status gates and the independent packaged Store probe must
select literal 36. This successor is implemented with
[executed package/Store/migration evidence](../provenance/generation-preparations-2026-10.md). Exact historical format-2 records
for both 28 and 35 remain verifiable; neither is a current update image. Require
source and target declarations and live Store schema all 36. No cross-schema
update, migration or rollback is added; original historical records remain intact.
The earlier schema-35 evidence above keeps its historical scope. Repeat LS-T1–T4
for this current cohort with 35/28/float/unknown metadata refusals and preserved
legacy verification, alongside schema-36 generation migration/backup checks.
