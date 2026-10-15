# Explicit kernel adoption evidence — October 2026

This record owns incremental evidence for the
[explicit rule kernel contract](../specs/routine-kernel-adoption-v1.md).
Home's pure installed mapping and actual generic initial-proposal checks are
implemented. RestrictedBasis now emits current v4 proof over the complete
runtime cohort and preserves exact historical v3 decoding. The existing
Authority/Store invocation path has not adopted generic proposals. Preparation,
commit, rollback and retained Store-history acceptance remain outstanding.

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
