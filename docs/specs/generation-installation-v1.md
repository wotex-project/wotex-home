# Trusted generator and private export-policy installation

Version: 0.1.0. Updated: 2026-10-14. Status: accepted successor target.
Owner: WOH.18 H18A-02/H18-T15/T17/T18; WOH.08 host startup; WOH.16 recovery.
Implementation: planned. Evidence: missing.

## Result and ownership

An explicitly configured Host supplies the existing Store generation policies
and adapter capabilities. A fixed immutable private file can deliver policy data
for the next startup; an explicit trusted native option supplies live adapter
PIDs. This completes host consumption of the existing generation mechanism.
It does not install or authenticate an external model adapter. Ordinary startup
with no policy has empty policies/providers; file policy alone cannot call a model.

Home owns installation/export policy. GenerationPolicy owns checked actor,
provider, exact source-range/example and limit identities. GenerationProvider
owns the explicit alive local adapter capability. Store owns authentication,
revision CAS, current source custody, durable preparation/attempt originals,
response retention and cancellation. Host owns startup selection; it passes no
connection or bearer to the adapter. Existing authoring installation, profile
import, manual authoring and device dispatch remain separate and unchanged.

## Inputs, outputs and bounds

Host.start_link/1 accepts one optional generation_installation value:

| Native value | Interpretation |
| --- | --- |
| Option absent | Select the fixed private policy file and no providers. |
| nil | Explicitly disable generation; do not read the file. |
| Exactly %{policies: CHECKED_LIST, providers: CHECKED_LIST} | Use these trusted checked values; do not read the file. |
| Exactly %{policies: :private, providers: CHECKED_LIST} | Select the fixed private policy file and these trusted adapter capabilities. |

Unknown fields, structs, improper lists, dead/nonlocal/name-based adapter
capabilities and contradictory identities refuse invalid_generation_installation.
No application-environment provider default, endpoint option, caller-selected
callback or ordinary API installation route exists. Existing duplicate Host
option rejection also applies to this option.

GenerationInstallation.prepare/1 validates the resolved native value, returning
exactly policies/providers (nil resolves to empty lists). Each list has at most
32 entries. Policy values reconstruct through GenerationPolicy and are sorted
uniquely by principal_id/provider.id. Providers reconstruct through
GenerationProvider, are sorted uniquely by provider SHA and have distinct PIDs.
Every supplied provider SHA must occur in a policy. A policy may have no live
provider: it remains explicit metadata and permits inert preparation, while
attempt start refuses generation_unavailable. No provider is substituted.

The sole filename is generation-policies-v1.json beneath the canonical private
data root. The file is exactly {format,policies}, format
wotex-home.generation-policies@1, policies a proper ordered array of at most
32 native GenerationPolicy input objects. Each object has exactly principal_id,
provider, remote_export, passages, examples and limits. Provider is exactly id,
model_id,adapter_sha256,locality: Home IDs of 1–128 ASCII bytes, lower hex64
adapter identity and local/remote. Local requires remote_export false; remote
requires a boolean and preparation/export later requires explicit true consent.

Passages are at most 32 sorted unique exact {reference,offset,length} records;
reference is {object_digest,first_revision}, lower hex64 and positive signed-64;
offset is an integer from zero through 262144, length positive and at most 4096. Examples are
at most 32 sorted unique reference records. Limits are exactly max_passages
(1–32), max_passage_bytes (1–4096), max_passages_bytes (1–131072), max_examples
(1–32), max_examples_bytes (1–262144), max_input_bytes (1–1048576), all integers.
GenerationInput owns ordering and additional consistency checks. These are
maximum permitted exact selections; neither overlapping ranges nor an entire
source file becomes implicitly exportable. Installation does not read references
or authenticate their ownership. Store must do that before preparation/handoff.

The policy file is 1–1048576 UTF-8 bytes, bounded JSON depth eight, 32768
value/container nodes, 256 collection members and 4096 string bytes. Duplicate
names, floats/booleans in integer slots, unknown fields, malformed identities,
bad order and excess counts refuse. Resource excess returns authoring_limit;
other document/native policy errors return invalid_generation_configuration.
An unavailable public JSON producer returns profiles_producer_unavailable.

The leaf is mode 0400, regular, single-link and owned by the private 0700 root's
UID. Canonical leaf/ancestors cannot be symlinks. PrivateFile supplies bounded
descriptor reads, ancestor/inode/stat witnesses and exclusive synchronized
publication. Unsafe roots/files return generation_configuration_unavailable.
Raw bytes and SHA-256 identify delivery; whitespace changes are different
delivery even when policy identities are unchanged. Snapshot inspection reveals
only its SHA, never principals, references, paths or complete native inputs.

## Requirements and transitions

**GI-01 — Validate before resources.** Resolve both profile and generation
installations and reconstruct all policy/provider values before acquiring a new
data root, Store lock, database, profile namespace or socket. An invalid present
file or native installation refuses with no partial Host. An absent file yields
empty policies. With explicit private providers but no matching policy, refuse
invalid_generation_installation. Validate exact capabilities again in Host.init
and Store startup, since liveness can change after initial validation.

**GI-02 — Pin one startup selection.** Carry the selected private snapshot or
continued absence into Host.init. Immediately before constructing children,
recheck the exact file seal, raw digest and reconstructed policy data. Removal,
replacement, same-size content/mode/link/ancestor change, or appearance after
absence returns generation_configuration_changed. Never switch to another file,
native input or empty configuration after a refusal. Host root aliases accepted
by the existing canonicalizer select the same canonical namespace.
When the root already exists, absence retains its ancestor identity witnesses;
a missing root is checked as a newly acquired private namespace before children.

**GI-03 — Publish without activation.** GenerationConfiguration.publish/3 takes
an existing canonical private data root and explicit immutable private source.
Validate the document and recheck its source seal/bytes before exclusive
nonreplacing publication. Exact existing bytes return the same safe summary;
different existing bytes return generation_configuration_exists. Summary is
only sha256, policies count, principals count and distinct providers count.
Sync failures/races use PrivateFile's owned-file cleanup and never remove foreign
bytes. No source contents, principal/reference, credential or path are printed.
The task mix woh.profile.generation.install loads paths without starting Home;
it creates no root, Store, credential, revision, provider or background service.

**GI-04 — Install the exact checked set.** Host passes the resolved checked
lists as Store generation_policies/generation_providers. File-only Host can read
actor-scoped options and make inert preparations, but has provider_present false
and cannot hand off an attempt. Trusted native composition can use a previously
started adapter PID; Host does not start, restart, rename or own that external
process. Its owner must separately enforce transport output limits, model
authentication and confinement before supplying this capability. Declaration
identity and a live BEAM PID prove none of those properties.

**GI-05 — Preserve original recovery.** Store/custody child restart uses the
same selected native lists and never reloads disk policy or resumes an attempt.
Adapter loss leaves the Host and ordinary controls running; options presence
becomes false, new attempts refuse, and current response guards discard output
without the original exact live capability. A dead capability can cause a Store
child restart to fail its own startup validation; no name lookup/fallback or
automatic adapter replacement is allowed. A later complete Host start can
explicitly select a new installation. Same identity with a new PID is a new
process capability, not permission to replay an old attempt.

Existing-only preparation/attempt status and exact original retry still resolve
under current actor authorization when installation is now empty or bytes/model
are unavailable. They do not refund a spent attempt, recreate a worker, renew
time or export again. Changed policy/basis requires a new explicit preparation;
current response acceptance retains all earlier Store guards.

**GI-06 — Keep local policy outside restore.** The file/native PID installation
is host policy outside profile imports and encrypted database/quarantine backups.
Restoring history cannot manufacture policy, provider capability, source custody,
source review, grants or device qualification. There is no schema change. Neither
file nor native configuration changes physical dispatch's disabled default.

## Compatibility and acceptance

Before code, freeze independent Python file documents/digests and reconstruct
policy/provider hashes for both existing quantity families without Home/BEAM.
Use actual private files, Host/SQLite/socket processes and bounded scripted
providers for execution evidence. Scripted adapters qualify no external model.

| Case | Requirements | Stimulus and independent observation / falsifier | Level |
| --- | --- | --- | --- |
| GI-T1 | 01/04 | Both frozen families, checked native/private modes, nil/absence, 32 policies and unknown/duplicate/float/bool/order/struct/list/size/depth inputs; changed digest or accepted malformed installation fails. | Pure/filesystem |
| GI-T2 | 02/03 | Mode, symlink, hardlink, unsafe ancestor, same-size modification, replacement/removal, absence appearance, exact publication retry/conflict, file/directory sync failure and competing publication; mutation of foreign bytes or leaked private data fails. | Filesystem |
| GI-T3 | 01/04/06 | Invalid native/present file before resources; no database/socket/profile root or provider call. Explicit nil/native suppresses bad disk input. Default file-only metadata has no live provider and cannot start a model. | Host/socket |
| GI-T4 | 04/05 | Actual configured Host imports independent owned source/fixture, prepares, calls once and retains inert candidates for both families. Options and originals survive exact retry/child restart; changed disk policy is not hot-loaded. Any approval/effect or second call fails. | Host/SQLite/process/socket |
| GI-T5 | 04/05 | Provider death leaves Host readable, missing/unmatched capability refuses, full startup explicitly removes installation while original status/retry remains; old pending outcome stays unknown without replay. | Host/process/restart |
| GI-T6 | 02/03/06 | Fresh Mix installer with deliberately bad Home startup env never starts Home; ordinary fresh Application loads valid policy, rejects bad policy before children and stays dispatch-disabled. Logs expose no raw configuration. | Fresh OTP process |

Record actual source/toolchain, fixtures, commands/results and scope. Linux
systemd, signed native installation, actual model confinement, power-loss and
hardware qualification remain separate required evidence. Consumer installation
semantics belong here; no ExBooking or WoTEx API change is required.
