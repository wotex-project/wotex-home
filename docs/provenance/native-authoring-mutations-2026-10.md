# Native authoring submission and recovery evidence

Recorded: 2026-10-14. Owner: [native authoring mutations](../specs/native-authoring-mutations-v1.md).
Level: typed JSON peers, real private UDS/Store/archive and separate native processes.

The owning contract preceded runtime in `c6e58a7`; implementation is local main
commit `00d52c3`. The SDK keeps complete original
fields and v6 import payloads, probes existing import/review originals before
transfer, sends fixed chunks under one transient identity and verifies the exact
original receipt before resolution. The existing original-purpose runner now
supports local authoring lookup/retry with before/after controller/principal and
nonregressing watermark checks. Paired authoring and review cancellation refuse.
First-decision native presentation is a subsequent composition obligation.

Elixir 1.19.6 / OTP 28.5.0.6, Apple Swift 6.4
(swiftlang-6.4.0.34.1, clang-2100.3.34.1), Swift 6 language mode and
arm64-apple-macos15.0 target executed:

- `mise exec -- mix woh.native.authoring.mutation.smoke`: 32 operation-scoped
  JSON peer cases passed for candidate, full binary import and large canonical
  review, with exact native fields, closed upload identity/hash/cursors, missing
  originals, byte-independent replay, lost begin/chunk before/after retention,
  changed owner, stale successful cursor, discarded/malformed final reply,
  mismatched receipt and cleanup failure. Final uncertainty retains its original
  and recovers by exact status without another commit. These peers exercise the
  same scoped SDK body/envelope seam; actual UDS framing is checked below.
- The explicit three-archive command in
  [operator evidence](authoring-operators-2026-10.md) passed 81 component cases in
  10.1 seconds and four actual Store workflows in 35.7 seconds. Temperature and
  research each create fresh native candidates and complete reviews in addition
  to the existing CLI/read checks. The proxy observes a complete v6 original
  before each mutation, forwards it to the real Store and discards its reply.
  A separate native process uses exact candidate retry or review lookup and
  removes only its confirmed entry without another Store revision. Full 256-KiB
  binary import likewise survives lost commit reply and separate-process lookup.
  An unsafe publication lock prevents mutation; after correction, capture writes
  the complete original without a Store revision. Later principal revocation
  refuses retry and preserves the complete journal bytes and empty byte custody.
  Credentials use private stdin pipes rather than command arguments.
- `mise exec -- mix woh.native.pending.coordinator.smoke` and
  `mise exec -- mix woh.native.pending.paired.smoke`: existing original
  publication/reload/restart lookup/retry, paired vectors/private CAS/races and
  local recovery refusal regressions passed with the expanded source closure.
- `mise exec -- mix test test/wotex_home/authoring_operator_test.exs
  test/wotex_home/authoring_upload_test.exs test/wotex_home/cli_test.exs`: 20 cases
  passed in 1.8 seconds. The new adversarial CLI case returns a successful chunk
  reply with an unchanged cursor and proves no retry/status/commit request follows.
  Correction `bb71ad1` limits exact chunk retry to status recovery after an actual
  lost reply; the native SDK has the same rule.
- Full app warnings-as-errors Swift type checking, Elixir warnings-as-errors
  compilation, formatting, the 22-contract catalogue and Git whitespace passed.
  `mix.exs` and `mix.lock` remain unchanged.

Consumer lock SHA:
`6ddb05e87f2872a12a244a022d666372d792510c8760188a3ac235ce53c258dd`.
Store fixture SHA:
`ee6f8b4f9d9a6ed124329ff3ae77f0e82d243874fe68428a1910c593edb66533`.
This is bounded software evidence. Arbitrary transfer interleavings, every
terminal upload/time race, native first-decision/selected publication UI, signed
paired authoring, installed publication/disk survival, application producer
adoption, provider export and physical qualification remain separate obligations.
Inert complete review still grants no approval, selection or control.
