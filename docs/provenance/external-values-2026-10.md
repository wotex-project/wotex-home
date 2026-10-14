# Exact external value software evidence

The [value successor](../specs/external-values-v1.md) version 0.1.1 owns this
pure component under the [v2 mapping contract](../specs/device-profile-mappings-v2.md).
Commit `4d6e585` defines its inputs, transitions, bounds and acceptance;
`0491458` freezes independent coordinate/contract vectors and the structural
consumer schema; `4da6df5` implements checked value consumption and its tests.
No WoTEx change was necessary: public WPF Unit conversion and Interpreter/
Proposal APIs already own the generic mechanics.

On 2026-10-14, Elixir 1.19.6 / OTP 28.5.0.6 executed:

- `mise exec -- elixir bin/check_routines_shadow.exs --profile-consumer`
  with distinct --core-archive/--core-sha, --runtime-archive/--runtime-sha and
  --profiles-archive/--profiles-sha pairs below. A fresh consumer compiled twelve
  selected Home modules with warnings as errors, with Home host and routines
  absent. All 28 cases passed: seven new consumption cases plus the existing
  21 envelope/authoring/source/fixture cases. Consumer lock SHA-256 remains
  6ddb05e87f2872a12a244a022d666372d792510c8760188a3ac235ce53c258dd.
- `mise exec -- mix test test/wotex_home/external_value_unavailable_test.exs
  test/wotex_home/external_envelope_codec_test.exs
  test/wotex_home/portable_profile_artifact_test.exs`: 12 tests passed.
- Formatting, warnings-as-errors compilation, the working 22-contract catalogue
  and Git whitespace checks passed. No application/native full suite, Dialyzer,
  protocol transport, physical device or release qualification was run.

| Selected archive | SHA-256 |
| --- | --- |
| Core | 77c742b0b76c3d4d9d4c9d5e5b47e65755a351021de1ddba73369647b96fee61 |
| Runtime | 7c5412ea01dab311357a09276030ca005470c9bd8b0f471e0da3fb8ec5e4b1b4 |
| Profiles | 34a3dcef363a0b072fa2b260efeff8633f8365fd4aecfd1fbbc2c268c82e0b96 |

| Checked Home input | SHA-256 |
| --- | --- |
| lib/wotex_home/profiles/external_value.ex | 8b4993f5801e281e83c3da47afc6b90c674ca63fdac5a622e948d7015df3da77 |
| test/support/profiles_value_consumer.exs | 5ee2af3cfbe83293eb63954ec423644cce8ed4c34d652ecc25c9ff88c3b5c013 |
| test/fixtures/profiles/external-values.json | e7547a6c11c1e185a37e1541b670f71c8b88409648df2e844533bfba4707d7b8 |
| priv/profiles/external-consumer.schema.json | e37212b89bbc2e732af1c1487980c02df5cb40a036693184f9174fb5724e453d |

Python fractions independently convert the literal 2.5 Celsius and unfamiliar
density coordinates to the supplied milli-coordinate integer 2500 and compute
the consumer-record SHA identities. Tests compare those frozen values and
provenance records; they do not derive expectations from the new implementation.
Literal Boolean and bounded record fixtures exercise a separately constructed
public producer basis without adding a sensor/model enum to Home.

Cases EV-T1–EV-T5 cover null sentinels, unknown/stale qualities, retained/replayed
continuity, missing source time/sequence and negative receipt monotonic origins.
Wrong semantic/consumer references and quantity kind, fractional/repeating
conversion, range and signed-64 excess, stale report/capture/current envelope/
contract/limits, forged native data, malformed contracts and depth/collection/
string excess refuse. The ordinary locked application has no selected optional
Profiles producer and reports unavailable instead of providing local conversion.

The first archive run found a test incorrectly treating an equal min/max range
as malformed. The reversed-bound case corrected that expectation before the
final passing run. A draft implementation was held aside while the independent
vectors/schema were committed; the runtime commit follows those frozen inputs.

The output remains an inert checked value. It establishes neither source truth,
operator acceptance, device freshness nor observation/control authority. Durable
v2 import, current selection, correlated protocol delivery, canonical observation
admission and hardware qualification remain owning obligations. Application
producer pins are unchanged and all commits remain local on main.
