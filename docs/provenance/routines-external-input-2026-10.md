# External routine input producer checkpoint

Reviewed: 2026-10-15. This records an owned producer milestone and source review
for the next [routine adoption stage](../plans/universal-routines-delivery.md).
It does not select a dependency or qualify Home facts, clocks or effects.

## Exact producer evidence and current selection

WoTEx commit 743ef568 implements its accepted external-input execution contract;
d1b2e87b adds the extracted execution/mutation harness and records the owning
milestone. The owners are WRO.01 observation metadata, WRO.02 snapshots/edges and
WRO.05 exact external joins under
wotex/docs/packages/wotex-routines/specs/external-input-execution-v1.md.
The paired evidence is in that package's provenance/external-input-execution-2026-10.md.

The new public Input.binding_basis/3 retains the external profile identity and
complete installed Mapping, while keeping the installed Basis identity distinct.
Snapshot and Edge regenerate and validate the correspondence against the current
program Registry and complete Basis. Fact accepts required-but-null received_at.
The separately selected floor_millisecond receipt clock handles original signed
microseconds conservatively and caps exclusive expiry; the original exact clock
still refuses nonaligned receipts. Source-class and source/receipt-clock mismatch
cannot acquire a known value under the external binding.

Native integer/Boolean/enum reader-to-kernel and retained-edge checks pass. Two
independent extracted scalar consumers each pass five cases, using industrial
temperature and a separately supplied ratio definition. Both catch profile-identity
and signed-rounding mutants exclusively through assertions. A third passes actual
ordinary Kernel execution with the reader absent, while all explicit input APIs
return missing_producer. The full owning package gate passes 179 tests, 95.4%
coverage, zero Dialyzer errors, audits, docs, boundary, archive and passive loading
on Elixir 1.20.2 / OTP 29.0.4. Exact archives, locks, source hashes and seeds are in
the producer record; its Routines archive SHA-256 is
fb74f71b6b44b286907d65caaf2271e9e0b6318939236a4aaf736120e42a33ef.

At the initial checkpoint Home selected Routines f3e77a431a917b639f7b0d52a93b78c27def4344,
core/Profiles/Continuum 687a5cd70267fa47dbfb36e28eccad6ef2964fdf and
ExBooking 3fa614cd3cf106aba7161e17015969634afc3730. New sibling HEAD/API
availability is not runtime selection. This checkpoint changes no lock, active
proof, source qualification, Store schema or physical dispatch setting.

## Home source review and required consumption order

Review used Home a15d0f3 and its existing external observation and initial kernel
adoption implementations. These are source findings, not a new executed Home
reader-to-routine or durable-fact acceptance campaign:

- ExternalValue.project/4 starts with the actual WPF Interpreter proposal but can
  convert its unit and normalized_value through the explicit Home consumer before
  retaining the Home value. Removing Home-only fields cannot recover the original
  Proposal reliably. Rebuild through the retained original report and checked
  envelope using the public reader; retain both independent value/proposal hashes.
- ExternalObservationPreparation.build/6 rebuilds current target/envelope/source
  inputs and compares the retained outcome. ExternalObservations retains the exact
  original decoded report and canonical Home value separately. Historical byte
  correspondence is not a new live source or processing-time receipt.
- Store.external_receipt_clock derives received_store_ms from the original native
  receive microseconds with floor division, then subtracts Store.clock_origin.
  Its existing preboot, future, original lifetime and exclusive freshness checks
  must survive the join. A stable same-host correspondence can express the same
  coordinate as origin_us = 1000 * clock_origin and target_origin_ms = 0, bound to
  the actual report-owner epoch and Store boot. This equation does not authorize a
  caller to choose those clocks or install a Mapping.
- The authenticated external reported-value preview repeats current source,
  author/trust/policy/target/custody checks and actual interpretation. The legacy
  FactReadModel explicitly refuses ReadCapability. That separation is intentional;
  an approved read profile or a successful generic Mapping is not qualified
  sensor evidence and does not extend the existing admitted rule profile.

First author and review the bounded Home projection/correspondence contract,
including closed inputs/results, original reader reconstruction, complete mapping
installation, missing UTC, exact units, signed clock/expiry bounds, independent
vectors and producer/native forgery refusals. Its pure result must remain inert.
Then select and verify the exact producer cohort before consumer implementation.
Changing that cohort invalidates old runtime correspondence; do not rewrite an
old proof/history to keep it current.

The subsequent current Store collection contract must define authenticated bounded
scope, qualified semantic/source installation, live boot/source/custody checks,
atomic complete-set collection, exact report/resource/selection revisions and
final admission revalidation. Reconnect, restart, replacement, retained/replayed
reports and missing sequence must not invent a positive edge. Full composition,
run/step persistence and wider admission need their separate schema/proof owners.
No current external fact route or automatic rule activation is introduced here.

Temporary producer archives, extracted consumer projects, generated documentation
and metadata projections were removed after their checks. Reusable build/PLT
caches and unrelated Docker volumes remain. No Docker resources were created,
and all commits remain local on main.

The Home documentation check passes 22 working contracts. A separate temporary
projection validates all 21 indexed contracts, excluding unrelated research; all
changed working/indexed Markdown links and both Git whitespace checks pass. No
Home behavioral suite, Dialyzer, host build or hardware campaign ran for this
documentation-only checkpoint. The temporary projection was removed.


## Home projection entry contract

The [inert projection successor](../specs/routine-external-facts-v1.md) now closes
its inputs, selected limits, original-reader reconstruction, independent
Home/Proposal witnesses, eight-member JSON output, static errors and REF-T1–T5.
Review found one additional boundary: runtime producer assertions in
ExternalValue validation delegate to existing compiled-code inventory, which can
read BEAM artifacts through bounded temporary readers. The contract preserves
that check and its cleanup, rather than calling the whole operation pure.
It distinguishes historical archive assertion fixtures from current inventories.

Before consumer code, the offline result schema embeds the exact local WRO
Fact/Mapping/external-binding definitions from d1b2e87b. The independent Python
oracle first reproduced the existing producer Mapping hash, then froze the new
source/clock Mapping, Registry, original Proposal, Home value and exact result.
It distinguishes reader 2.5 degrees, Home 2500 thousandths and routine 250
centidegrees. Original -1001 us at origin 0 us/10000 ms yields 9998 ms; freshness
1000 gives exclusive expiry 10998. Receipt UTC stays null. The historical
archive assertions are explicit fixture input, not current runtime evidence.

`WOTEX_HOME_GIT_DEPS=1 mise exec -- mix test test/wotex_home/routine_external_fact_schema_test.exs --warnings-as-errors`
passes **three tests**, seed **337048**, in **0.08 seconds** on Elixir 1.19.6 /
OTP 28.5.0.6. This validates entry grammar, offline reference closure and literal
independent hashes only; it does not execute ExternalFact or promote REF-T1–T5.
No dependency pin, Store table, current read route, proof or physical dispatch
changed in this entry slice.


## Exact source selection

Home now selects Routines d1b2e87bdc82bd0138887931a9f40a2236ff2fdc in mix.exs
and root/firmware locks. The other producer and Hex entries are byte-for-byte
unchanged. Diff review from f3e77a43 finds no Routines mix.exs/CHANGELOG change;
the accepted execution contract owns the additive behavior and evidence. The
core/Runtime/Profiles/Continuum package contents have no diff from selected
687a5cd7 through d1b2e87b. The new Routines commit was fetched into the clean
dependency cache without configuring remotes; locked dependency resolution
exited zero and changed no other tuple. No ref was pushed or release published.

`WOTEX_HOME_GIT_DEPS=1 mise exec -- mix test test/wotex_home/producer_cohort_test.exs test/wotex_home/installed_profile_runtime_test.exs test/wotex_home/rule_kernel_proposal_test.exs test/wotex_home/routine_calendar_test.exs --warnings-as-errors`
passes **28 tests**, seed **509759**, **4.3 seconds** on Home's Elixir 1.19.6 /
OTP 28.5.0.6. Routines' 58 modules compile in that lane. Actual dependency HEADs,
root/firmware lock parity, public profile values, compiled inventories, initial
Kernel proposals and calendar behavior are exercised.

The selected line probes in durable_rule_activation_test.exs:574 and
rule_kernel_runtime_test.exs:142 pass **two tests**, **38 excluded**, seed
**433114**, **5.3 seconds**. They create an actual held invocation and real v3
admission/original under historical modules, then preserve immutable history
through current restart and producer absence. They do not renew every earlier
current/final writer mutation or qualify a wider admission profile.

Before committing selection, the existing Home civil archive lane was renewed
against exact selected sparse package sources and ExBooking 3fa614c. A first
archive attempt used a sparse repository root without a Mix project and exited
before any build; its context-managed directory was removed. The corrected
package-root builds and bin/check_routines_shadow.exs --civil-consumer exit zero.
It passes **14 tests**, seed **103727**, **0.5 seconds**, including all **230**
independent timezone/label cases, **112** recurrence vectors and a civil
calculation with no application startup. Pure Hex builds and the consumer use
Elixir 1.19.6 / OTP 28.5.0.6; no firmware/native image is built.

| Archive | SHA-256 |
| --- | --- |
| core | 77c742b0b76c3d4d9d4c9d5e5b47e65755a351021de1ddba73369647b96fee61 |
| Continuum | db7077c5f0ad92426c94a077a4f58f9b7334df25de8c2a1b8ed25143bab6efb5 |
| Routines | fb74f71b6b44b286907d65caaf2271e9e0b6318939236a4aaf736120e42a33ef |
| ExBooking | 5e1b12fbe5fa9e72f02ff7e79674dd35e415fb4aea87222f7ea01cfa50ae1fb2 |

Consumer lock SHA-256 is
79bb3746c94f2f858f6586eacccfe22eb7ebd51f6d574320b6ec25956a2b439b.
Root mix.lock SHA-256 is
3bc9cc0a8a17c7df701007f653ab29bd06028dca2068f100d49feca5b39ed68e;
firmware mix.lock is
4b155edd0b88dbfbdc496c87ee2c1756bf234df4d8a34219701a9cf64215334b.
Both the archive-build directory and runner's extracted consumer directory were
removed after completion. Dependency/build caches remain reusable. No full Home
suite, Dialyzer, native packaging or physical campaign ran for this pin change.
The inert projection and its REF-T1–T5 remain the next implementation obligation.
