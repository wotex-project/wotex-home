# Native external-profile catalogue and history read evidence

Recorded: 2026-10-15. Owner: [native reads](../specs/native-external-profile-reads-v1.md)
NXR-01/02/03 and NXR-T1/T2/T3. Requirements preceded implementation in a2fa92c
and authorization clarification in 2725ee0. Runtime:
9f60ea681bd16c4beeb567c81c328617aec469d2 on local main. Concurrent Store race
fixtures are recorded in 62a8bc4052254cb506b4b2451f8db53b57ffecdf.
No Store schema, wire format, dependency or producer API changed.

## Implemented boundary

The fixed native reader exposes current external catalogue plus inspection, trust
and target original status. It takes a caller-supplied credential/transport and
owns no credential capture, signing, private input file, mutation or publisher.
All returned metadata has typed fields and redacted reflection. Each read brackets
its domain request with authenticated controller identity, refuses changed owner/
principal/active epoch or regressing revision, and separates historical original
epoch from active identity. Optional expected input SHA verifies a present receipt.
Catalogue revision must be stable; original receipt revision cannot be in the future.

Catalogue decoding preserves binary id/version ordering and the 64-artifact limit,
current trust state and policy counters. Original decoding enforces the owning
closed receipt fields and action/counter rules. Approved, revoked and
`author_unavailable` metadata never become current grants or physical qualification.
The new transport allowlist admits only four reads; malformed server reasons are
refused around both domain and identity exchanges. No retry or fallback is added.

## Executed checks

Pinned Elixir 1.19.6/OTP 28.5.0.6 through `mise exec --`; Swift 6.4, Swift 6 mode,
warnings-as-errors and arm64 macOS 15 target on the development host.

- `mix woh.native.external.profiles.smoke` passed 725 framed cases using frozen
  independent receipts for temperature and research. Exact request sequences check
  both inspection receipts, approve/revoke and select/revoke histories, matching
  optional input SHA, historical epoch, missing, malformed/wrong fields or hashes,
  bool/float/string/null/overflow counters and changed owner/principal/epoch/revision.
  Catalogue cases include empty/64 rows, lexical version order, duplicate/reversed
  rows, bounds and all three current trust states. Initial/final identity errors,
  server refusal, malformed reasons and lost reply are covered. Invalid inputs
  refuse before a request; the peer observes no mutation or capture route.
- `mix woh.native.external.profiles.smoke --live` passed both families against
  actual SQLite, private object/source custody and the real private socket. Setup
  uses actual import, inspection, maintenance, approval and target selection.
  Native reads verify present original input SHA and current catalogue, then
  revoked target/trust receipts while the old approve/select receipts stay readable.
- Two actual private-socket proxy races per family commit one unrelated principal
  after the domain reply and before final identity. Catalogue refuses the changed
  revision, while immutable inspection history succeeds across that increase.
  The proxy observes exactly identity/domain/identity and each race increments
  Store revision exactly once; the native client sends no mutation.
- The live cases stop both report and source publisher owners before reconciliation.
  Catalogue/history still read, and explicit reapproval remains distinct from a
  selected target. A manager with profile:manage but no enroll:review sees shared
  catalogue and scoped missing inspection/trust history, while target history
  refuses. A separate fully permitted actor cannot borrow another actor's originals.
  Author withdrawal yields author_unavailable to the permitted auditor and unauthorized to
  the retired credential. Store revision is unchanged across each native read
  batch; dispatch remains disabled. No model or physical device is accessed.
- `mix test test/macos_app_inventory_test.exs test/wotex_home/external_profile_operator_test.exs`
  passed 17 tests. The explicit app source inventory includes the new reader and
  existing socket/CLI authorization/original behavior still passes.
- Focused formatting, compilation with warnings-as-errors, the specification
  catalogue, HTML ExDoc with warnings-as-errors and Git whitespace checks passed.
  No full application suite, Dialyzer or installed app build was run.

An early 64-item fixture used uppercase hex from Elixir's numeric formatter; the
strict decoder refused it. The fixture now supplies lower hex. The initial live
fixture gave its cross-actor target-history auditor only profile:manage and was
correctly refused; it now tests both the explicitly permitted auditor and a separate
manager without enroll:review. Neither production authorization nor decoding was
relaxed. A review also extended malformed-reason refusal to identity exchanges,
with explicit initial/final identity peer cases in the passing 725-case run.

Logs: `/tmp/home-native-external-profile-reads-{peer,live,tests,docs}.log`.
Credential bytes use stdin/private fixture custody and never command arguments or
tracked files. Frozen input SHA256 values:
external-inspections.json `530d80b4a384783dc1cd654c0ef040cd8c292d07f3e9d85cb96920a955ead7bf`;
external-trust.json `6264b993ddc814f825f4d885e6587a6b0acd6c72eab6b330943da3b287ec5738`;
external-target-selections.json `85c062d40e021ef0403aeadff62889ef2cde8a3bfa14ab96bd6852824c103701`.
Unchanged mix.lock SHA256:
`3372ef86b264343efeedea270b3a8d0548650898043aa0e360daba46c7aaf184`.

## Remaining native delivery

This implements the read prerequisite, not native v2 first decisions or durable
pending custody. Complete inspection/trust/target original codecs, journal/recovery,
selected driver confirmations and panel composition remain next. Actual signed
selection/Keychain, same-lease UI delivery, accessibility, protocol/source truth,
confinement, storage power-loss and physical qualification retain their separate
requirements. A compiled reader or synthetic publisher does not satisfy them.
