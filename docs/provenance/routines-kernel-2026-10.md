# Explicit kernel adoption evidence — October 2026

This record owns incremental evidence for the
[explicit rule kernel contract](../specs/routine-kernel-adoption-v1.md).
Home's pure installed mapping and actual generic initial-proposal checks are
implemented. RestrictedBasis still emits v3 and the existing Authority/Store
invocation path has not adopted these helpers. Current v4 proof, preparation,
commit, rollback and retained-history acceptance remain outstanding.

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

The other six cases preserve existing restricted-proof checks; they do not
establish the planned v4 proof. Scoped `mix format --check-formatted` for both
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
