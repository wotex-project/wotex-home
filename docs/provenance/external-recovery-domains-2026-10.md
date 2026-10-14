# Inert external recovery inventory evidence

Recorded: 2026-10-14. Owner: [external recovery domains](../specs/external-recovery-domains-v1.md).
Level: pure/software/archive; no physical isolation or generic destination acceptance.

The owning v3 contract was committed in `d61e989` before implementation
`01b4565`.
Independent Python json/hashlib vectors derived from retained temperature,
unfamiliar density and multi-channel Thing bytes reproduced the missing decoder
support: two of three new pure cases failed before implementation. No Home or
WoTEx code runs in `python3 test/support/external_recovery_oracle.py`; regeneration
now reproduces the fixture bytes exactly.

RecoveryDomains emits v3 only for inventories containing external ReadCapability
Things. Their sorted capability keys and declaration hashes remain separate from
legacy quantity/unit summaries. Complete source/snapshot commitments retain their
full private source, target and observation originals plus sequence history.
Generic records have an unknown transport basis and cannot produce an accepted
isolation scope. Legacy-only inventories retain the exact v2 format and guards.
No schema, producer pin or dispatch policy was changed.

Elixir 1.19.6 / OTP 28.5.0.6 executed:

- Focused new external domain, acceptance-record, acceptance-codec and existing
  recovery-domain files: 32 cases passed in 4.2 seconds.
- Existing actual controller acceptance and recovery snapshot files: 30 cases
  passed in 13.8 seconds, preserving legacy signed/transaction/rollback behavior.
- The exact unchanged three-archive `--profile-target-store-consumer` command in
  [target evidence](external-target-selections-2026-10.md): 81 isolated component
  cases passed in 10.1 seconds and 48 actual Store cases in 21.4 seconds. Consumer
  lock SHA remained `6ddb05e87f2872a12a244a022d666372d792510c8760188a3ac235ce53c258dd`.
  Updated Store fixture SHA-256 is
  `5da34e3f57bf3e54c0f19cae26ca53ef12646f1dd3e04ac304e88e12e67a9371`.
- Format, warnings-as-errors compilation, 22-contract catalogue, owning file
  references and Git whitespace checks passed.

Three actual source/quarantine cases select temperature or multi-channel targets
or revoke the unfamiliar density target after admitting a report. Each retires
the controller, exports an inclusive encrypted archive and compares its inert
inventory and normalized retained commitment with staged quarantine. Original
receipt and sequence history survive. Source/Store/custody owners are stopped,
staged profile files removed, and the actual WoTEx JSON module plus its code path
removed during verification; no producer fallback or owner restart is needed.
A transactionally injected sequence mutation changes the normalized commitment
and makes complete domain derivation fail integrity; rollback restores exact
correspondence. Every generic inventory refuses physical_disconnection as an
acceptance basis. Pure cases also refuse other methods, malformed hashes, mixed
capabilities, ordering/duplicates, legacy versions and resolved generic bases.

This establishes ER-T1–ER-T4 for the exercised inert representation. It does not
provide a generic transport/isolation profile or accepted destination transfer.
No full application suite, Dialyzer, native build, installed host or physical
qualification was run. All commits stay local on main.

Format selection was tightened in `ed5629e` to inspect the actual tagged
capability records rather than a profile-label prefix. The new external domain
and existing recovery-domain files passed 15 cases in 3.1 seconds after that
change, and warnings-as-errors compilation plus Git whitespace checks passed.
The archive run above predates this equivalent classification for its external
fixtures; it is retained as the executed archive evidence, not represented as a
new run after the final classification edit.
