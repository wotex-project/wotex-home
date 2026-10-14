# Generic external read declaration software evidence

The [owning declaration contract](../specs/external-read-declarations-v1.md) was
committed in `0b0b3bf`; independent Python canonical output/hash vectors in
`a2311d6` preceded the implementation in `7291a2e`. The declaration is inert
preparation for current target/observation usage, not executable capability
authority. Existing Light/SmokeDetector declarations and schema 33 are unchanged.

On 2026-10-14, Elixir 1.19.6 / OTP 28.5.0.6 executed:

- The exact three-archive `--profile-consumer` command from
  [trust evidence](external-trust-2026-10.md) passed 40 pure archive cases in
  8.9 seconds. The fresh consumer compiles twenty selected Home modules with
  warnings as errors. Archive and consumer lock identities are unchanged.
- `mise exec -- mix test` selecting external_value_unavailable_test,
  external_envelope_codec_test, external_inspection_test, external_trust_test
  and portable_profile_artifact_test passed 21 cases. No socket exclusion was
  selected; these selected cases do not exercise a socket.
- Format, warnings-as-errors compilation, the working 22-contract catalogue
  and Git whitespace checks passed. No Store schema change, full application/
  native suite, Dialyzer, packaging or physical qualification was run.

Value/declaration archive fixture source SHA-256 is
562a6b5c8b2697d8d8ba4a81312d35a5c161f1d5884eba3f3c10dfa225b55baa;
declaration module SHA-256 is
7881d25cd751a921e91fe3189c763f51dceb8538f9710a483c1a7bb74cac52b1;
independent vector SHA-256 is
2d42a1c4f8477f742ca103f45e6c0941ed671306c0e412fa460a7a583ddae4b0.

Five new archive cases extend the earlier 35. Temperature and an unfamiliar
quantity match complete independent JSON outputs and SHA identities. Household
policy, risk/freshness/Thing, exact consumer coordinate, raw whitespace variant,
actual recapture and limits changes cannot reuse the prepared declaration.
Native input/data/hash/extra-field forgery refuses. Wrong channel/reference/
semantic/quantity and malformed or excessive policy fields refuse. Boolean and
external numeric/record cases preserve the checked producer schema and source
unit without exposing write authority. An actual optional producer-excluded
channel alongside a supported channel cannot become a Home read declaration.
Missing optional producer and public consumer-identity limit checks refuse
without a local implementation substitute.

The first run caught unsorted field lists supplied to Home's existing closed-map
helper. Later adverse fixtures corrected a nested-map update that had returned
the whole outer fixture, and retained a supported channel while testing an
optional exclusion, as required by the existing envelope contract. All final
cases passed. Public consumer_identity/2 and check_reader_limits/1 reuse the
existing consumer/unit and Home ceiling validation rather than copying it.

No producer/model/sensor-name branch, Store connection, bearer, clock, network,
grant, target selection or observation is introduced. Host acceptance of meaning,
source custody, current trust/selection, Store-clock freshness, counter continuity
and physical qualification remain owning durable/protocol obligations. Current
producer dependency pins are unchanged; all commits remain local on main.
