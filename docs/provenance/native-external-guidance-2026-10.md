# Native external guidance evidence

Recorded: 2026-10-15. Owner: [native guidance reads](../specs/native-external-guidance-reads-v1.md)
NGR-01–03 and NGR-T1–T4. Specs preceded implementation in b8494eb and
4487cf2. Runtime: f909889 on local main. The underlying Store/socket/CLI
mechanism has [separate evidence](external-profile-guidance-2026-10.md).

## Implemented boundary

Four explicit native SDK reads return immutable typed reader/maintenance,
source-choice, target-counter and exact inspected-manifest metadata. Inputs
validate before any socket work. Each read uses identity/domain/identity at one
authority/principal and Store watermark; a missing artifact still verifies the
final identity. Historical inspection epoch remains independent of the current
authority epoch. No operation, source lease or pending publication is allocated.

Closed decoders enforce field sets, integer/null distinctions, source ordering,
target-history counter correspondence and body ceilings. Manifest decoding uses
the existing pinned URI grammar, ordered typed object summaries and the exact
domain-separated object-array hash. It verifies full canonical manifest bytes
without exposing raw payloads or captures. All returned nested metadata redacts
reflection. The existing transport gains only four named read operations; its
mutation transport remains unchanged. The app assembly source list includes the
new client, without adding UI or a selected signing path.

## Executed checks

Swift6.4 in Swift6 mode, warnings-as-errors, arm64 macOS15 target on the macOS27
development host. Elixir1.19.6 / OTP28.5.0.6 through mise and existing lockfile.

- `mix woh.native.external.guidance.smoke --live`: **211 independently sequenced
  private-peer cases**, then both quantity families against actual
  Authority/SQLite/custody/Unix sockets. Expected frames are independently written
  by the Elixir fixture, not emitted by the native implementation. Frozen existing
  manifests supply exact canonical bytes and digests; malformed manifests are
  rehashed by a separate array/hash builder so structural refusals do not depend
  solely on a stale hash.
- Peer cases cover all four bodies, active/unavailable context, available empty
  versus unavailable sources, exactly32 sources, unsorted/duplicate/oversized
  sources, absent/selected/revoked targets, historical inspection refs, missing
  artifacts, missing/extra fields, boolean/float/string/overflow counters,
  invalid enums/digests/versions, duplicate JSON names and lost domain replies.
  Before/body/after principal, epoch, owner and watermark changes refuse.
  Invalid credential/target/reference uses a missing socket to establish refusal
  before IO. Successful values, nested reflection, counters and safe source fields
  are independently asserted; artifact canonical bytes match the frozen corpus.
- Actual Store runs verify both manifests, source summaries and current reader
  basis, selected/revoked target state, source shutdown and fresh reader loss.
  Original catalogue/status workflows also execute through their unchanged
  client, including revision races, revocation and authorization. Guidance reads
  preserve Store revision and the preexisting source lease table and release
  private byte leases. Fixture credentials and inspection refs travel on stdin.
  Physical dispatch remains disabled.
- `mix test test/macos_app_inventory_test.exs`: **two tests, zero failures**.
  Global formatting, warnings-as-errors compilation, the22-contract catalogue
  check, HTML ExDoc with warnings-as-errors, local references and Git whitespace
  checks passed. No full suite, Dialyzer, app assembly or installed signing ran.

The first live check incorrectly expected an empty source lease table after
selection. Completed selection legitimately retains lease history. The corrected
fixture compares the table immediately before and after guidance reads; both
families then passed. No product change was made to erase that history.

Logs: `/tmp/home-native-guidance-{tests,live,compile,inventory,docs}.log`.
Frozen input SHA256 values:

- `external-trust.json`:
  `6264b993ddc814f825f4d885e6587a6b0acd6c72eab6b330943da3b287ec5738`
- `external-source-selections.json`:
  `82798f1a709603b2cf98c78e83dcaafe23711e5e0d7a00c61e9ca499e57dc52f`
- `external-inspections.json`:
  `530d80b4a384783dc1cd654c0ef040cd8c292d07f3e9d85cb96920a955ead7bf`

Unchanged mix.lock SHA256:
`3372ef86b264343efeedea270b3a8d0548650898043aa0e360daba46c7aaf184`.

## Remaining delivery

These are explicit SDK inputs for guided decision construction. The selected
panel still accepts complete private files; native guided controls, selected
driver composition, signed paired interaction, installed accessibility/signing,
protocol publishers and physical qualification remain separately owned work.
Fixtures do not establish real source identity or hardware qualification.
