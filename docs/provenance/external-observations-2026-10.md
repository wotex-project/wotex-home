# Durable external observation software evidence

Recorded: 2026-10-14. Owner: [external observations](../specs/external-observations-v1.md),
WOH.18 H18-04/05/08, H18-T3/T4/T5/T8/T11/T12; WOH.01 H01-T6.
Level: bounded software/archive correspondence; no physical qualification.

The native admission/clock/sequence/schema requirements were frozen in `9e1c28d`,
the source snapshot boundary in `576341d`, independent ordered bytes in
`c6c8520`, reported preview fields in `bc7075f` and live reprojection in `caf3be4`.
Implementation is local commit `7806414` on main. Source snapshots allocate no
review lease or original, so continuous reporting does not consume target-review
identity slots. Receipt publication remains separate from observation admission.

Schema 35 adds exact originals/outcomes/receipts, current target/channel pointers
and retained source/channel/sequence cursors. Only Store opens/writes SQLite.
The native API accepts report-owner epoch/ID rather than a caller's report body,
clock, target or normalized value. It obtains the configured Store-only checkout,
resolves the exact selected source binding, rebuilds the actual actor-owned raw
closure/declarations and uses public WPF/ExternalValue interpretation. The final
report/source/deadline guard rolls back on changed evidence. A definite attempt
finishes the private checkout; replay recovers the original before fresh work.

The original host receive microseconds are floor-converted into Store elapsed
milliseconds. Processing time never renews that clock. Explicit new selection in
this Store boot is required for fresh admission/use; replay cannot install that
marker. Equal/decreasing sequence, forged continuous gaps and preboot receipts
refuse. Replacement/dependency retirement clears current report pointers while
retaining sequence/original history. Legacy facts/routines/effects stay closed.

Authenticated reported previews require read permission and a whole-Thing grant.
Lab, old-boot, stale/unusable/discontinuous or missing-basis values remain unknown.
A fresh preview reprojects its stored original report through current checked
bytes/consumer and compares the exact outcome. Historical opaque decoding is
not a proof of producer algebra: a rehashed in-range coordinate can remain
structurally interpretable, but live use detects it as external_value_changed.

## Executed checks

Elixir 1.19.6 / OTP 28.5.0.6; project lock unchanged. The exact Core/Runtime/
Profiles archive arguments from [target evidence](external-target-selections-2026-10.md)
passed `--profile-target-store-consumer`: 81 isolated component cases in 12.0
seconds and 39 actual Home Store cases in 13.2 seconds. Consumer lock remained
`6ddb05e87f2872a12a244a022d666372d792510c8760188a3ac235ce53c258dd`.
The selected fresh consumer compiles 38 Home modules; the actual Store uses the
same exact public producer archive cohort, not neighboring checkouts.

The Store cases include independent temperature, unfamiliar density and actual
multi-channel current reported coordinates, scoped read/status, exact replay and
cold Store recovery, sentinel null preservation, source replacement while private
byte preparation is suspended, SQL rollback, sequence order/continuity, preboot
receipt rejection, target replacement, erased/mutated pointers/sequences/journal,
rehashed consumer mismatch, live reprojection mismatch, and nonempty inclusive/
database-only encrypted quarantine. Prior target, trust, source and operator cases
remain green in the same run. The additional source snapshot case verifies exact
native value/guard, typed refusals and no review lease/tombstone allocation.

Focused target/observation wire and durable Store files passed 22 cases in 3.8
seconds. Recovery Store, controller acceptance schema and native target schema
files passed 50 cases in 21.2 seconds. Format, warnings-as-errors compilation,
the 22-contract catalogue and Git whitespace checks passed. Historical fixtures
remove the three actual successor tables before exercising an older schema.
No socket exclusion, full application suite, Dialyzer or native package was used.

## Remaining delivery

This establishes the exercised software subsets of OB-T1–OB-T5. End-to-end valid-history quota saturation, full nonempty normalized controller
transfer, accepted host source/meaning installations, physical transport/correlation
cohorts and native reported-preview presentation remain open. Private socket/CLI
reads are implemented with [executed operator evidence](external-profile-operators-2026-10.md). No default physical dispatch,
grant, qualification or generic routine correspondence is enabled by admission.
The new owner does not establish actual hardware support or storage power-loss
survival. Independent vectors regenerate with
`python3 test/support/external_observation_oracle.py` without invoking Home/WoTEx.

## Sequence and aggregate boundary successor

The clarified boundary contract is local commit `12b78b0`. The same three-archive
`--profile-target-store-consumer` passed 81 isolated cases in 10.1 seconds and
45 actual Store cases in 15.8 seconds. Lock and archive digests are unchanged;
Store fixture SHA-256 is
`fe4b6f424884a075c3fb11caab4a37f7f410a084e737ec9c5b61c11563412f59`.
New actual Store cases retain 18446744073709551615 as SQLite text, refuse wrap
and publication overflow, preserve the sequence cursor across actual report-owner
replacement plus Store restart/reselection, retain nullable originals without a
cursor, and preserve unknown gap/retained/replayed preview dispositions.

Focused observation wire/bounds files passed seven cases in 0.5 seconds. Real
in-memory SQLite aggregate-guard cases check 4095/4096/4097 originals, 8192/8193
cursors, exact input/outcome byte ceilings and one byte beyond using multibyte
UTF-8. These isolated aggregate tables deliberately lack valid authority history;
they establish the arithmetic guard, not full Store quota saturation/recovery.
Pure preview cases check original age, equality expiry, wrong boot/future receipt,
null sequence and discontinuous/null-value dispositions without timed sleeps.
Format, warnings-as-errors compilation, catalogue and whitespace checks passed.
No full application, native, Dialyzer or physical test was run.
