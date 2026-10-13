# External profile inspection software evidence

Home commit `0088784` implements the pure v2 envelope/projection boundary in
`lib/wotex_home/profiles/`. WoTEx source `5626facf`, package
`packages/wotex-profiles`, supplies the public reachable-reference seam. These
are exact development/archive cohorts; the ordinary Home application has no
selected Profiles dependency and returns profiles_producer_unavailable.

On 2026-10-14, Home's pinned Elixir 1.19.6 / Erlang OTP 28.5.0.6 executed:

- `mix format --check-formatted`, `mix compile --warnings-as-errors` and
  `mix woh.spec.check` passed. The working catalogue checked 22 contracts;
  the separately extracted staged documentation checked 21 contracts, keeping
  the unrelated music target outside this commit.
- `mix test test/wotex_home/external_envelope_codec_test.exs test/wotex_home/portable_profile_artifact_test.exs test/wotex_home/portable_profile_ledger_codec_test.exs`:
  15 tests passed. The new decoder refuses duplicates, numbers, controls,
  resource overflow and improper native collections; optional producer absence
  returns unavailable. Existing v1 artifact and ledger behavior passes.
- `elixir bin/check_routines_shadow.exs --profile-consumer` with the three
  explicit archive/digest pairs below passed seven fresh consumer cases.
  Home's three-module source closure is freshly compiled, and neither routines
  nor the Home application is present. Both independently authored quantities
  match Python-generated raw/projection/consumption identity vectors. Raw variant,
  semantic/capture/native replacement, optional exclusion, uninstalled contracts,
  unreachable/missing closure and bounded malformed input are exercised.
  Home refuses required writes even when the producer registration supports them.
- Git whitespace and owned document references passed before the local commit.

The harness verifies archive bytes before bounded extraction and selects only
those extracted dependencies in env=prod. It supplies synthetic installed
consumption assertions and capture; these establish no physical qualification.

| Exact artifact | SHA-256 |
| --- | --- |
| Core archive | `77c742b0b76c3d4d9d4c9d5e5b47e65755a351021de1ddba73369647b96fee61` |
| Runtime archive | `7c5412ea01dab311357a09276030ca005470c9bd8b0f471e0da3fb8ec5e4b1b4` |
| Profiles archive | `34a3dcef363a0b072fa2b260efeff8633f8365fd4aecfd1fbbc2c268c82e0b96` |
| Consumer lock | `6ddb05e87f2872a12a244a022d666372d792510c8760188a3ac235ce53c258dd` |
| Home Id source | `1dba3abf794eb238b12b6427c7bbf122d023b7bb19f8ad013476cce6fdea307c` |
| Home envelope decoder source | `6646c3252a5a9d86f0e15dc8b990d9a8c6d748a038133edc2cafccadbf1bebde` |
| Home inspection source | `66b301a93956e27872cbbd493cf1972d5718379a6828e73a0ded4f9bc272fc0a` |
| Consumer source | `47265cfdab25f25852e0c143763ae2fcfa6dfa78065ac1a1dbd6b7743544f5e8` |
| Temperature vectors | `a597c4fc8122c75bf6d6ad2e94f713d647af71b478502d1eb6579a13f542dc91` |
| Research vectors | `9906863b19d1e50e63dd77d38dd7805716ad3af711ca8fac225092c18e379666` |
| Envelope schema | `2142d3fe06d4c3e9939bb87f529a7a99ee417d259c57bfe40fd6b8c128f9f5fe` |

The owning Profiles milestone passed all 15 configured checks, 80 tests at
95.7% coverage, zero Dialyzer warnings/skips and both five-case archive consumers
on Elixir 1.20.2 / OTP 29.0.4. Its reachable-reference output matches the frozen
closure identity and omits validated but unused entries.

This evidence completes the bounded inspection component. Current trust,
enrollment, accepted meanings, canonical observation state, authenticated
authoring, durable custody/selection/recovery, protocol paths, installed-host
behavior and device qualification remain separate obligations. V1 history and
default-disabled physical dispatch retain their existing meaning.
