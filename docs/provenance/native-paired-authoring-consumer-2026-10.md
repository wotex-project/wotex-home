# Paired manual authoring consumer evidence

Recorded: 2026-10-15. Owner: [paired composition](../specs/native-paired-authoring-generation-v1.md),
manual portions of NPA-01/02/04 and NPA-T1/T2/T2a/T5.
Contracts preceded implementation in b7e5668 and upload lifecycle clarification
ab4d611. Listener runtime: 86a4fc6ce240e8c5fc3010f7be323645d7f02678.
Native runtime: ab85f8ecd665d6b18465c6dbde04742cffcda637 on local main.
No Store schema, dependency, producer API or sibling source changed.

## Implemented boundary

Paired manual import, candidate and review now permit lookup/retry through the
fixed original-purpose runner. First capture checks actual current profile:manage
in addition to exact original association/context correspondence. Original recovery
refuses an association that never approved that permission, then its actual factory
requires the current authenticated scope. Metadata comparisons create no live seal.

Around every authoring SDK exchange, including upload chunks/status, the adapter
reads scope through its same finite TLS owner. It checks original controller,
principal, epoch, creation floor, profile permission, unchanged current grants and
nondecreasing revision. Retry queries the exact retained operation first; a present
checked result resolves without sending mutation. Only a missing result permits
one unchanged original delivery through the existing typed protocol.

Production capture and outcome publication also check scope before/after the
private-file CAS, using the actual same signed seal and original five-second
lifetime. No reacquisition, fallback, successful fixture seal or raw-key session
constructor was added. Possible late/failed publication retains uncertainty.
Ordinary local recovery still refuses paired entries; paired generation actions
remain disabled. Manual outcomes remain separate from approval, admission and control.

The real TLS listener previously received an Authority without a transient upload
owner. It now creates one bound to its exact Store or validates/pins an explicitly
supplied owner PID. Owner loss fences the listener and accepted workers; normal
listener shutdown stops its owned process while preserving an external owner.
Registered-name replacement cannot retarget the pinned PID. Restart gives a new
transient owner epoch and preserves durable original receipts independently.

## Actual checks

Commands used the pinned Elixir1.19.6/OTP28.5.0.6 via `mise exec --`, Swift6.4,
Swift6 warnings-as-errors and the arm64 macOS15 target on the development host.

- `mix test test/wotex_home/controller_listener_test.exs test/wotex_home/authoring_upload_test.exs`:
  33 tests, zero failures. Real TLS begin/status uses one owner; owner loss closes
  accepted sockets, owned shutdown retires its process, restart discards transient
  IDs and changes epoch, external lifetime survives and wrong Store refuses before
  listening. Existing framing, scope/parity, owner loss and upload bounds pass.
- After extending the supplied-owner case, `mix test test/wotex_home/controller_listener_test.exs:449`:
  one test passed,26 excluded. A registered name is replaced while its original
  owner stays alive; the listener continues to pin the original PID and stops
  neither external process on shutdown.
- `mix woh.native.paired.recovery.smoke`: passed. The actual native closure compiles
  and runs independent metadata/private-file/unsigned cases and real pairing/TLS/Store
  cohorts. A profile:manage-only paired principal imports the frozen temperature
  draft, assesses a compatible manual candidate and records incomplete source review.
  Each committed final reply is dropped by a transport-only wrapper. Its next retry
  resolves by lookup, with zero mutation requests; Store revisions advance only once
  per original. v8 publication precedes each request. Existing history survives new
  native processes and Store/listener/custody restart. Revocation refuses and leaves
  pending metadata unchanged. Existing paired power/review publication and
  wrong-principal refusals also pass.
- `mix woh.native.pending.storage.smoke --paired-authoring`: passed independent v8
  bytes/digests/old-marker refusals, private guards, CAS, upgrade/no-op/version
  retention, process crash/restart and competing publication. New action assertions
  permit only manual lookup/retry; the independent corpus itself is unchanged.
- `mix format --check-formatted`, `mix compile --warnings-as-errors`,
  `mix woh.spec.check` (22 parent contracts), HTML ExDoc warnings-as-errors and
  `git diff --check` passed. Documentation agent commit ff4f5e5 independently
  passed documentation-stripped AST, references, formatting and attribute audits.

The initial fixture setup lacked its required private custody directory; it was
corrected. Two new Elixir assertions were corrected for decreasing remaining TTL
and linked startup refusal; the passing focused results above supersede those
failures. Native fixture construction now explicitly converts bounded Int64 DTO
values to the existing encoder's native Int field representation; codec acceptance
was not widened.

Input identities:

- `test/fixtures/profiles/authoring-mechanics.json` SHA256:
  `1b368b22a45ca78ffe46c6d7ee7a4df5fecba526de73779af52f31c3f02c37ae`.
- Independent `native-pending-paired-authoring.json` SHA256:
  `61a3e844903f3eb4ffb0c2181c298df20ae39ef8c844b787ff4ace015880da4d`.
- Unchanged `mix.lock` SHA256:
  `3372ef86b264343efeedea270b3a8d0548650898043aa0e360daba46c7aaf184`.

Temporary logs: `/tmp/home-paired-upload-owner-tests.log`,
`/tmp/home-paired-upload-pinned-owner-test.log`,
`/tmp/home-native-paired-authoring-consumer.log`,
`/tmp/home-native-paired-authoring-storage.log` and
`/tmp/home-paired-authoring-docs.log`. Only bounded public failure diagnostics
are emitted; synthetic credentials stay in stdin/private fixture custody.

## Remaining acceptance

The transport fixture uses raw synthetic custody and an explicit test clock;
it cannot construct a production signed session. The actual unsigned factories
refuse before account/Keychain/clock/network, including approved-profile metadata.
Successful installed signing, existing Keychain access, five-second signed
publication/delivery and failure at those actual host boundaries remain unexecuted.
The selected authoring driver/presentation, paired generation/workspace consumer
and their installed interaction/accessibility are still successors. This record
does not complete NPA-T2's generation portion, NPA-T3 or all of NPA-T4/T5.

No live model/account, external export, OS confinement, physical dispatch,
hardware qualification, storage power-loss, full-suite/Dialyzer milestone or
new hosted CI result is claimed. No ref was pushed.
