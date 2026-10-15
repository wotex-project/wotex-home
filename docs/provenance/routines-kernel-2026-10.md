# Explicit kernel adoption evidence — October 2026

This record owns incremental evidence for the
[explicit rule kernel contract](../specs/routine-kernel-adoption-v1.md).
Home's pure installed mapping and actual generic initial-proposal checks are
implemented. RestrictedBasis now emits current v4 proof over the complete
runtime cohort and preserves exact historical v3 decoding. The actual
Authority/Store path now prepares inert data, calculates the initial proposal
outside the writer and commits through current/final checks. The first bounded
durable corpus has evidence below. Expanded all-member/final-fault and actual
retained-v3 Store acceptance remain outstanding.

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
