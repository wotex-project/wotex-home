# Explicit kernel adoption evidence — October 2026

This record owns incremental evidence for the
[explicit rule kernel contract](../specs/routine-kernel-adoption-v1.md).
Home's pure installed mapping and actual generic initial-proposal checks are
implemented. RestrictedBasis now emits current v4 proof over the complete
runtime cohort and preserves exact historical v3 decoding. The actual
Authority/Store path now prepares inert data, calculates the initial proposal
outside the writer and commits through current/final checks. The first bounded
durable corpus has evidence below. All-member runtime/final-read SQL faults
and actual retained-v3 held-original recovery are now covered. Retained-v3
spent/handoff uncertainty and the owning adoption milestone remain open.

## Source and boundary

The contract was committed before implementation at Home `117cf28`, with the
initial-step and opaque-ID corrections in `a1de24f` and `cf65675`.
The selected sources remain Routines
`f3e77a431a917b639f7b0d52a93b78c27def4344`, core/Continuum
`687a5cd70267fa47dbfb36e28eccad6ef2964fdf` and ExBooking
`3fa614cd3cf106aba7161e17015969634afc3730`. No dependency pin or producer
behavior changed. WoTEx `10e43a4a` improves module documentation only; Home
does not claim to select that newer sibling HEAD.

`KernelMapping.build/3` constructs the Home-owned security, lifecycle and
Boolean report contracts, installed basis, checked registry and closed source
under the contract's explicit limits. Opaque Home IDs map injectively to an IRI
using unpadded URL-safe Base64; no enrollment identity changes. Ownership spans
1–86400000 ms in this pure profile and does not widen durable admission.

`KernelProposal.propose/5` calls the selected public Compiler and Kernel with
the supplied runtime digest, resource revision and closed inert invocation
metadata. `validate/6` rebuilds the full program and independently checks the
complete result basis, initial Run and exact sole proposal before returning a
Home Boolean Value. A general valid retained Run with a later last_ms cannot
substitute for the initial result. `qualify/3` checks both Boolean values across
four original scopes and returns source-specific mapping/compiler digests.
The supplied runtime digest is bound, not measured or qualified here.

These helpers read no application data, clock or environment, retain no run,
and start no service. They do not receive a credential or Store connection and
cannot create held work. Missing producer APIs or bounded producer failures
return payload-free errors; there is no fallback evaluator.

## Executed checks

Home used pinned Elixir 1.19.6 / OTP 28.5.0.6 with
`WOTEX_HOME_GIT_DEPS=1`. The focused command
`mix test test/wotex_home/rule_kernel_proposal_test.exs test/wotex_home/restricted_basis_test.exs --warnings-as-errors`
passed **16 tests**, seed **7040**, in 2.9 seconds. Ten new cases exercise:

- Actual public Compiler/Kernel calls for both Booleans and ownership boundaries
  1, 10000 and 86400000; expected effect/original and contract digests use
  consumer-side expected values and an independent small canonical encoder.
- All 66 permitted Home ID characters and four additional boundary IDs, including
  maximum length and IDs without a scheme; 70 exact reversible IRI mappings.
- Maximum supported source/resource/epoch/generation coordinates, source/runtime
  and caller-scope identity changes, malformed native structs and unsupported
  semantics without coercion or defaults.
- Every member and unknown keys across the wrapper, program and result trees,
  zero/extra proposals, a valid foreign program, later retained time, shortened
  step deadline, string/depth/collection bounds and native struct injection.
- A fresh Home-only VM with the producer absent: all four pure entry points
  refuse as routine_kernel_unavailable.
- Ten mutations of the actual selected Kernel source in a fresh VM: no proposal,
  inverted input, foreign original, protocol-only completion, shortened step
  deadline, altered time, forged edge, forged spend, exception and throw. Every
  mutation fails correspondence. Compilation is in the child VM's memory; no
  parent BEAM or producer source is replaced.

At this pure checkpoint the other six cases preserved existing v3
restricted-proof checks; they did not establish v4 proof. Scoped
`mix format --check-formatted` for both
new modules and the new test passed. `mix compile --warnings-as-errors` passed.
No socket exclusion, full application suite, Dialyzer, release/image build or
physical campaign was used for this slice.

Early diagnostic runs exposed truncated source inspection in the mutation
fixture, an invalid assumption that raw opaque IDs were absolute IRIs, and an
incorrect test assumption that shortened step deadlines passed general Run
validation. The fixture and contract were corrected before the final run.
The later-last_ms case is the demonstrated general-valid/initial-invalid
counterexample. Those failed runs are not positive acceptance evidence.

Source SHA-256 values for this pure slice:

| File | SHA-256 |
| --- | --- |
| lib/wotex_home/rules/kernel_mapping.ex | fc2e8ef2179809c8b6af92369c255e469024b48873aca51f94c0929e0b61da91 |
| lib/wotex_home/rules/kernel_proposal.ex | f101c0d15c9b3db92a8af7d88a25cfeb3416bcbf7000a0293d9e925f77e57cdf |
| test/wotex_home/rule_kernel_proposal_test.exs | 36fc76d5587da275f900a623161e40d8018d23acc8152896c8c0071083daae84 |

## Cleanup and limits

The pure tests create no temporary directories, archives, documentation output,
Docker images, containers or volumes. Their child VMs exit normally. The test
and development build caches remain reusable. A subsequent disk audit found
Home's root _build at 66 MiB, dependencies at 790 MiB and approximately 40 GiB
free on the shared data volume. No owned disposable artifact remained.
Other projects' temporary directories, database volumes and build caches were
preserved. No push, repository visibility change or remote release occurred.

## Current v4 proof and historical codec checkpoint

The wire/codec requirement was committed before implementation at Home
`93a7187`. RestrictedBasis now retains Home's independent draft, gate and root
correspondence and adds source-specific actual generic Compiler/Kernel checks.
Its v4 fields and ordered obligations are those in RKA-04. Runtime identity uses
all ten selected applications and domain
`wotex-home.explicit-kernel-runtime.v1`. One positive basis per caller process
may be reused under complete rule/declaration/compiler/runtime bindings.
Every lookup reads a fresh complete runtime inventory. A cold proof reads it
again after calculation, including when an enclosing Store guard has an opening
memo; the internal fresh inventory path cannot reuse that memo.

The profile-specific native/JSON codec accepts exact v3 and v4 records without
calling the producer. Admission history retains its original bytes and hashes;
current qualification requires rebuilt v4 equality. This checkpoint establishes
artifact decoding, not the later actual retained-Store/restart campaign.
The existing review_rules operation emits the closed current v4 projection.
The native client validates all four generic members, ordered obligations and
both compiler profiles, while preserving the request and original grammar.

Executed bounded checks used the same pinned toolchain and sources:

- `mix test test/wotex_home/restricted_basis_test.exs test/wotex_home/rule_kernel_proposal_test.exs test/wotex_home/runtime_artifacts_test.exs:79 test/wotex_home/runtime_artifacts_test.exs:264 --warnings-as-errors`:
  **23 passed**, seed **179681**, 25.5 seconds, 16 unrelated tests excluded.
  The v4 proof cases include warm changes to retained bytes, application version,
  module inventory and artifact availability for every one of ten applications;
  failed inventory clears the positive memo. A matching changed Kernel BEAM
  with inverted actual input still fails semantic correspondence after a warm
  positive proof. A Kernel calculation that changes Tz metadata fails the cold
  closing inventory. Four matching RuntimeGate mutants still fail the
  independent gate check. A fresh Home-only VM decodes a v3 admission and
  round-trips its exact proof with Routines absent. Native/JSON malformed,
  omitted, reordered and mixed-profile members refuse.
- `mix test test/wotex_home/durable_rule_activation_test.exs:50:120:574:627:648:691 test/wotex_home/schedule_admission_artifact_test.exs test/wotex_home/local_api_test.exs:441 test/wotex_home/runtime_artifacts_test.exs:265 --warnings-as-errors`:
  **24 passed**, seed **782920**, 66.8 seconds, 59 unrelated tests excluded.
  The complete 16-case schedule-artifact suite remains compatible with v4
  proposal evidence. Six actual rule Store cases cover admission/activation,
  scoped source reads, held/root identity, revoked author, restart and altered
  runtime/IR. The real private review socket exposes the generic commitments
  read-only. Invalid fresh-inventory scopes/domains refuse.
- `mix woh.native.rule.client.smoke`: **65 independent socket cases passed**.
  Eleven added cases refuse missing/malformed generic fields, old profile,
  extra fields and obligation reordering. The Swift fixture compiled with
  warnings as errors. This establishes neither an installed host nor a device
  effect.

The final input ordering captures the opening inventory before compiling the
Home program, keeping that compilation inside the cold opening/closing span.
The proof, actual Kernel mutation, closing-drift and codec cases were rerun
after this ordering refinement:
`mix test test/wotex_home/restricted_basis_test.exs:52:233:354:380 --warnings-as-errors`
passed **4 tests**, seed **711622**, in 4.2 seconds, with seven unrelated cases
excluded.
Scoped formatting and development compilation with warnings as errors passed;
the working catalogue check passed all 22 contracts. No full application suite,
Dialyzer, release/image build or physical campaign ran.
The staged committed-source catalogue passed all 21 contracts, with unrelated
research edits excluded. All 44 local references in the changed owning documents
resolve, all ten recorded source hashes match and both Git whitespace checks pass.

The docs agent improved only RestrictedBasis's module documentation and verified
unchanged non-documentation bytes/AST. Temporary proof/runtime copies, SQLite
fixtures and the native executable/private Swift compiler cache were removed.
An explicit post-check scan found zero directories with the owned
woh-kernel-proof-, woh-staged-specs-, wotex-native-fixture-,
home-rule-activation-, home-temporal-proof- and woh-guard-artifacts- prefixes.
No Docker resource was created. Approximately 41 GiB remained free; other
projects' data and reusable root build/dependency caches were preserved.

Source SHA-256 values for this proof checkpoint:

| File | SHA-256 |
| --- | --- |
| lib/wotex_home/rules/restricted_basis.ex | 483538e7ed75a7508c15f44455c05a9ffce6d8b5434773f22d2f5a39ee6ab50f |
| lib/wotex_home/rules/admission_artifact.ex | daba514b06650ede5cf810c01016f6d36bad0c753b5ff621be8a05a7674053bc |
| lib/wotex_home/runtime_artifacts.ex | 70d240d4d62dd0f62e13b5c071a6faeb43bb9b63067243899bac82c0d2e8a0df |
| lib/wotex_home/local_api/server.ex | 7bf2324e049125b78b89c21c2df74cee3b5dcba439ce8969a96016eeec58387c |
| native/macos/Sources/NativeRuleClient.swift | 7c0b6ad5d90e3c7dc3c1e24f300d49ab8796d4091aed959f0c9c4364e9fb65e8 |
| test/wotex_home/restricted_basis_test.exs | 1a05049d0b4b7de61f28e7a542c3571027d906f40fe8695f78d71b8815a14841 |
| test/wotex_home/runtime_artifacts_test.exs | b64b8973593eb9e6461f293db7b1680939c860da0e7bf6e887f0c439ad7f1674 |

## Actual initial invocation checkpoint

The authored RKA-06–08 preparation, projection, current/final guard and closed
error requirements preceded this implementation. The selected producer cohort
and dependency pins remain unchanged.

Authority invokes Store's internal preparation first. An authenticated exact
original returns its retained receipt before a new proof or target-grant check.
A new preparation contains exactly the eleven committed native fields, including
bounded admission bytes and its source/runtime hashes. It creates no durable row,
lease or worker. InvocationPreparation checks the shape/content and calls the
actual generic initial Kernel from Authority's caller process. The public
Store.invoke_rule compatibility API uses the same sequence. Its old raw
GenServer message refuses, and no external preparation/commit operation exists.

Commit authenticates and checks the original again, then regenerates the current
preparation and validates the entire generic program/result. Only the checked
Boolean enters the ordinary Home mutation. One transaction inserts one held
receipt/journal/outbox, exact rule origin and initially unspent causal root.
After enclosing history checks, the final unscoped read validates complete rule
history and repeats actor, author, admission/runtime/declaration/profile,
epoch/generation, invariant and override guards. No mutable grant or clock is
retained in the preparation. Store's profile-byte preparation includes both new
internal operations, preserving the existing portable-profile custody boundary.

The invocation path classifies only its closed semantic denial vocabulary as
recoverable. Inner collaborator policy wrappers cannot promote arbitrary SQL
strings or unclassified/control tuples to successful or recoverable outcomes.
A pending-capacity rejection rolls back the tentative refusal receipt and returns
receipt_capacity; no new invocation/root survives. Exact committed duplicates
recover the retained current receipt even if a calculated result is stale.
Subsequent fresh attempts still pass preparation and all current guards.

Executed checks, with pinned Elixir/OTP and WOTEX_HOME_GIT_DEPS=1:

- Initial five existing admission/invocation/override/revocation/restart cases:
  **5 passed**, seed **211223**, 3.4 seconds, 25 unrelated cases excluded.
- The first new 23-case run exposed seven fixture failures from a nonexistent
  spent column, hard-coded enrolled resource revision, missing maintenance
  permission, empty target provisioning and use of an already revoked lookup
  credential. These were corrected using the actual reserved_effects column,
  decoded admitted resource revision, accepted permissions/provisioning and
  complete row comparisons. Failed seed **992294** is diagnosis, not evidence.
- Corrected initial corpus: **23 passed**, seed **233867**, 21.8 seconds.
- Expanded corpus: **27 passed**, seed **298987**, 26.3 seconds.
- After tightening nested ledger/control-error handling and using fresh preparation
  for retries, `mix test test/wotex_home/durable_rule_invocation_test.exs test/wotex_home/durable_rule_activation_test.exs --warnings-as-errors`:
  **57 passed**, seed **810635**, 45.9 seconds. This includes the full existing
  30-case rule lifecycle suite, its framed/CLI and real socket operations,
  encrypted backup/integrity cases and the 27-case invocation corpus.
- Full `mix format --check-formatted`: passed.
- `mix compile --warnings-as-errors`: passed.

The working catalogue passed all 22 contracts and the staged committed-source
catalogue passed all 21, excluding unrelated research edits. All 44 local links
resolve to staged files, all 16 recorded source hashes match, and working/staged
Git whitespace checks pass. Cleanup scans found no owned invocation, history,
rule-activation, staged-spec or native-fixture directories. About 42 GiB remained
free on the shared data volume.

The new corpus compares actual SQLite receipt/outbox/journal/origin/root,
revision and principal/grant rows. It checks read-only preparation; independent
commitment/original calculations; both actual invocation API calls traced to the
caller process; concurrent/lost-result original recovery; unrelated revision
changes; closed/malformed inputs and projections; foreign/invalid credentials;
ten intervening authority, grant, generation, maintenance, override, declaration,
target and invariant changes; four final actor/author status/grant mutations after
tentative origin publication; five SQL publication fault boundaries; 32-held
capacity; rejected raw/external routes; and same-owner restart/original recovery
with Routines actually absent. The fresh child VM creates its own credentials,
removes the Routines code path/modules, recovers the exact original through both
public APIs, refuses a new original and compares unchanged retained admission,
receipt, journal, origin and causal rows. No bearer enters command arguments.

The mutation/SQL cases distinguish usable semantic refusal from writer-disabled
failure and validate retained integrity. SQL messages deliberately contain the
semantic name permission_denied; they still cannot become policy denials.
These checks establish this initial software path. They do not replace the
pending all-member opening/closing/final runtime campaign, final-read SQL fault
injection, actual historical-v3 retained roots/uncertainty or its owning adoption
milestone. Composed execution, qualified sensor joins, installed hosts and
physical qualification remain outside this checkpoint and are still required.

The docs agent changed only the preparation and writer moduledocs and verified
non-documentation byte/AST preservation, nine references, formatting and spacing.
No Docker resources, standalone archives, reports or documentation build were
created. Test-owned SQLite and fresh-VM directories are removed on exit; reusable
build/dependency caches and unrelated project data remain intact.

Source SHA-256 values for this invocation checkpoint:

| File | SHA-256 |
| --- | --- |
| lib/wotex_home/rules/invocation_preparation.ex | e53fc54bb66f0d3835c58778a9d893256f82e6357742ce500b94317936cc42ee |
| lib/wotex_home/authority.ex | fe5a0b4ea3e99a0d173f5bb1dfb17c7d6e276a90f671eeb104523f2971363aa9 |
| lib/wotex_home/durable/store.ex | b87ac63b058984e9f6fbac14dee96182fad39fc3840ea021cf860949db9e3430 |
| lib/wotex_home/durable/store/profile_byte_context.ex | f2a7bcac169ef23c4bf9f52065f30d506bfe5bf2b0492ca97e08b1d4e6b6eb38 |
| lib/wotex_home/durable/store/rule_writer.ex | b701d864a5726de15e89ddc58b53869e8b3cbc7a73898dab55dffe7eea6deca1 |
| test/wotex_home/durable_rule_invocation_test.exs | c6ee50dc2e8a3c653e3eb7940c49ffaf2716f1f7cb0ebd11605590e68b6e0f51 |

## Runtime faults and actual v3 held history checkpoint

All ten runtime members now have actual preparation, commit and final
publication drift evidence. The new corpus uses disposable copies of the full
ten-application closure plus UDP, while retaining the locked producer sources.
A test-only Store copy adds a callback immediately before the real final rule
read. Its matching BEAM is installed before admitting the rule, so the measured
Home cohort includes the test copy. No production hook, inventory stub or
semantic fallback was added.

For each of three boundaries, each of ten members changes complete retained
bytes, application version, module inventory or artifact availability:
**120 vectors**. The byte mutation retains the executable-code MD5 while changing
the full BEAM hash. At the final boundary, the fixture first observes all four
tentative receipt/outbox/origin/root rows on Store's own connection. Every new
invocation refuses, all retained data/schema rows remain equal, Store stays
writable, and an already committed original remains recoverable even while the
runtime is changed. Restoring the cohort permits fresh preparation and a single
successful held commit. The existing original is never re-created.

Six additional final callbacks rename an actual table only after tentative
publication: principals, target grants, invariant operations, override leases,
rule origins and admissions. The subsequent real final guard encounters SQL
failure. Every case rolls back all data and schema changes, disables writing and
passes retained integrity. Each fault occurs during the real final read after
tentative publication.

Three matching private Kernel variants fail only for the actual requested
invocation original: exception, throw and zero proposals. The normal finite
proof probes and a distinct retained original still succeed. Authority returns
routine_kernel_refused or invalid_kernel_projection without writing a new
original, Store remains usable and complete retained data stays equal. This
exercises actual application sequencing in addition to the earlier pure result
mutation corpus.

Historical v3 evidence comes from the five owning consumer modules at actual
prior Home commit **cf65675**: RestrictedBasis, AdmissionArtifact, RuleWriter,
Store and Authority. They are compiled into the private matching Home inventory
under the unchanged compatible schema. Their real admission, activation and
invoke APIs create a v3 document and held original; no receipt is relabelled or
rehashed into a legacy profile. After stopping that Store, the fixture restores
the current matching BEAMs and restarts. The exact receipt recovers, new use
refuses stale_rule_admission, and every retained data/schema row remains equal.
It then removes the actual Routines code path/modules, restarts again, recovers
that original through both public APIs, refuses a new original and checks
unchanged complete history and integrity. Credentials are generated in the
child VM and never enter command arguments. This is held-history evidence;
actual retained-v3 spent roots and handoff uncertainty remain required.

Executed with the pinned toolchain and WOTEX_HOME_GIT_DEPS=1:

- Initial runtime/final-SQL corpus: **4 tests passed**, seed **460014**, 60.0
  seconds, covering all 126 runtime/SQL vectors above.
- The first historical case failed on an already-loaded application return,
  seed **712518**, 4.8 seconds. Accepting the explicit already_loaded result
  corrected the fixture; the historical case passed with seed **43145**, 5.8
  seconds. The failed run is diagnosis only.
- Actual producer-failure case: **1 test passed**, seed **552092**, 3.2 seconds,
  covering all three matching actual-invocation variants.
- `mix test test/wotex_home/rule_kernel_runtime_test.exs test/wotex_home/durable_enrollment_test.exs:2580:2627:2659:2719 --warnings-as-errors`:
  **13 passed**, seed **111402**, 74.0 seconds, 611 unrelated cases excluded.
  This runs all six new tests, plus seven existing qualified software cases:
  override at queue/claim/handoff, damaged activation at those three boundaries,
  and generation withdrawal after committed handoff. Line 2659 selects the
  preceding damaged-activation group, not the maintenance group.
- `mix test test/wotex_home/durable_enrollment_test.exs:2668 --warnings-as-errors`:
  **4 passed**, seed **220437**, 36.6 seconds, 614 unrelated cases excluded.
  These actual held/queued/claimed/dispatching maintenance barriers preserve
  spend and handed uncertainty through the new initial-proposal join.
- Full `mix format --check-formatted`: passed.
- `mix compile --warnings-as-errors`: passed; production source is unchanged
  from the prior invocation checkpoint.

Working/staged catalogue checks passed 22/21 contracts respectively. All 44
local references resolve to staged files and all 18 recorded source hashes
match. Working/staged Git whitespace checks passed. Cleanup scans found zero
owned runtime, staged-spec, invocation, history or enrollment fixture directories;
approximately 39 GiB remained free on the shared volume at the final check.

The union provides 129 fault vectors, one actual v3 held/restart/absence trace
and eleven existing qualified-software execution regressions. The rule/temporal
adoption milestone remains open, especially retained-v3 spent/handoff history.
No full application suite, Dialyzer, installed host, release/image or physical
campaign ran. The qualification fixtures establish software guard behavior;
they do not qualify a device or enable physical dispatch.

Both new test modules use moduledoc false with the required following blank
line. Private BEAM/source/SQLite copies are removed on exit. SDK source,
parent BEAMs and unrelated work are preserved. No Docker resource, archive,
Swift cache or generated report is created by these tests.

Source SHA-256 values for this corpus:

| File | SHA-256 |
| --- | --- |
| test/support/rule_kernel_runtime_fixture.exs | 80b59f29650f261bf5c6ee1650de93979a61483da6a2b430835e2b4bfde5610b |
| test/wotex_home/rule_kernel_runtime_test.exs | 51d30bbc02da411276e8d9a7bdf5baf536a2a963d94adce6a9260fda74093a92 |

## Historical spent-work and software adoption milestone

The actual prior consumer modules at **cf65675** now create v3 originals through
four additional real ledger phases: queued, claimed, dispatching and
protocol_accepted. The shared LIFX qualification fixture is synthetic software
evidence only; it exercises guarded ledger APIs without device transport or
physical dispatch. Its six data attributes, qualification installer, digest
and SQL helper bodies were compared as normalized ASTs against their previous
definitions in durable_enrollment_test.exs and matched exactly. The existing
suite delegates to that installer rather than maintaining a second copy.

Each private VM admits, activates and invokes using the actual old modules,
reserves the root through the real queue API, and advances the requested phase
through actual claim/handoff/ACK calls. After restoring current consumer BEAMs
and restarting, queued/claimed snapshots remain exact. Handoff and ACK recover
through one documented outcome_unknown/crash_after_handoff transition: one
revision, receipt/execution outcome changes and one appended journal entry.
The other sixteen retained tables and schema remain equal. Admissions, origins,
spent roots, attempts and handoff timestamps are preserved.

After producer removal and another restart, both public invocation APIs recover
the same scoped original. New use refuses. Queued cancellation retains spend
while removing execution state; claimed/unknown work refuses cancellation
unchanged. A further claim refuses in every case. The ACK case also exports,
verifies and stages an encrypted backup. Staged immutable history remains exact,
integrity passes, quarantine is set, and ordinary Store opening refuses
restore_requires_transfer. Keys are generated inside the child VM and never
enter command arguments. RKA-05 now explicitly distinguishes immutable proof
history from these owning recovery/cancellation transitions.

Additional current-state cases exercise actual replacement-source admission and
activation, selected portable-profile byte loss, and epoch scope. A prepared
true-valued proposal refuses after replacement by an active false-valued source;
a fresh invocation creates only that new value and admission/generation root.
A valid inert epoch-2 proposal cannot commit against epoch 1. This checks current
epoch refusal, not a controller-transfer campaign. Removing selected custody
bytes after calculation makes preparation and commit refuse with every main-table
row unchanged. Restoring those exact bytes permits one held original with its
current profile pin and unspent root. A real private socket now invokes, repeats
and recovers the same original through framed/direct interfaces; a fresh stale
generation refuses without publication.

Executed with WOTEX_HOME_GIT_DEPS=1 and the pinned Elixir/OTP versions:

- Initial three-phase run: seed **974405**, 13.5 seconds; queued/claimed passed,
  while recovery comparison exposed a fixture-only list-to-map conversion
  error. Explicit key/value row conversion corrected that comparison.
- The next selected ten cases had no test failures, seed **933565**, 26.5
  seconds, but warnings-as-errors failed on two unused extraction aliases.
  Removing them corrected the fixture; that command is not green evidence.
- Corrected runtime/invocation/execution subset: **43 passed**, seed
  **652523**, 99.4 seconds, 611 unrelated cases excluded.
- All four spent-history cases, including ACK/archive: **4 passed**, seed
  **677685**, 19.5 seconds, six excluded.
- Replacement source: **1 passed**, seed **112873**, 1.6 seconds, 27 excluded.
  Epoch and profile-custody cases: **2 passed**, seed **229282**, 3.3 seconds,
  71 excluded.
- Full formatting and development compilation with warnings as errors: passed.
- Owning milestone command below: **115 passed**, seed **827870**, **141.0
  seconds** (96.5 async, 44.4 sync), 653 unrelated cases excluded.
- The additional real-socket invocation case was added after that gate:
  `mix test test/wotex_home/durable_rule_invocation_test.exs:346 --warnings-as-errors`
  passed **1 test**, seed **135536**, 1.3 seconds, 29 excluded. The unchanged
  cases were not rerun. No socket exclusion was requested in either command.

```sh
WOTEX_HOME_GIT_DEPS=1 mise exec -- mix test test/wotex_home/rule_kernel_proposal_test.exs test/wotex_home/restricted_basis_test.exs test/wotex_home/rule_kernel_runtime_test.exs test/wotex_home/durable_rule_invocation_test.exs test/wotex_home/durable_rule_activation_test.exs test/wotex_home/schedule_admission_artifact_test.exs test/wotex_home/authority_profile_review_test.exs:1538:1652 test/wotex_home/durable_enrollment_test.exs:2514:2597 --warnings-as-errors
```

| Acceptance | Milestone evidence and scope |
| --- | --- |
| RKA-T1–T3 | Complete pure projection/result corpus and actual producer mutants; independent draft shadow evidence stays separately scoped |
| RKA-T4 | Warm proof mutations, cold closing drift, safe historical decoding and 120 actual Store boundary runtime vectors |
| RKA-T5 | Caller-process calculation, concurrent original recovery, real held receipt/origin/root and restart |
| RKA-T6 | Actor/author/grant, generation, source, declaration, profile custody, epoch, invariant/override, maintenance and runtime refusals; late permission/runtime drift rolls back tentative work |
| RKA-T7 | Five publication and six final-read SQL faults, unchanged data/schema, writer-disabled failure versus usable semantic refusal |
| RKA-T8 | Actual old held plus four spent phases, absent producer, preserved spend/attempts/uncertainty and quarantined encrypted restore |
| RKA-T9 | Actual framed/private-socket invoke and scoped receipt recovery, closed external routes, rejected raw-message bypass and compatibility API |

This closes the restricted initial-proposal software adoption milestone. It
does not close WOH.20 stage 6: qualified sensor continuity, complete-set
collection, composed run/step persistence, durable completion and wider
admission still require their owning specifications and implementation. No full
application suite, Dialyzer, installed-host, release/image, minimum-window load
or physical campaign ran. No production code, dependency, durable schema or
dispatch default changed in this milestone.

Latest source SHA-256 values (earlier tables retain their checkpoint identities):

| File | SHA-256 |
| --- | --- |
| test/support/lifx_qualification_fixture.exs | a599e84aaa10b55232c4d9655c1f0b5dfc002cb5b094dd1ddc485f2c26a7d5e3 |
| test/support/rule_kernel_runtime_fixture.exs | f65d29940b2e5ec6aa75d301e5f2d1a6a8f3f229c44b7c365e026d8df0496cab |
| test/wotex_home/durable_enrollment_test.exs | 195b74b150c23518a52e25432d956588335a825d5f88589fad28ddda0027de65 |
| test/wotex_home/rule_kernel_runtime_test.exs | ffac063fd0b5f52a8f6d94b36e5fc6a4c0f6e1197bb3d57dc03d8cb4df3f9eae |
| test/wotex_home/durable_rule_invocation_test.exs | 26ea730d13afeaa164e4d7d2210403f40aaa27ba4ea04bea6ea78fe52a637d89 |
| test/wotex_home/authority_profile_review_test.exs | 8c0bcaf93db4b61bf6206fd52268a439c17dcd4b1e043ced7b17bfbdf82dcb96 |

Working and staged catalogue checks passed **22/21 contracts** respectively.
All **46** staged local references resolve, all **21** latest checkpoint source
hashes match, and all changed test/helper modules retain moduledoc false with
the required following blank line. The nine extracted attribute/helper ASTs
match the previous fixture. Final formatting and both Git whitespace checks
passed. Post-check scans found **zero** owned test or staged-spec scratch paths;
approximately **58 GiB** remained free on the shared volume. No Docker resource
was created. Reusable dependency/native caches and unrelated data were preserved.
