# External inspection preparation software evidence

The [inspection successor](../specs/external-inspections-v1.md) version 0.1.1
owns this component. Commit `ece518b` defines the durable target; `48dcd8e`
freezes independent reader/original/result/receipt identities and input schema.
Commit `19b3d64` implements ReaderSelection and producer-independent inspection
encodings, sharing the existing retained envelope representation with authoring
reviews. Commit `bcddc2f` specifies pure byte preparation before `0816170`
implements it. The Store writer, next schema, durable originals/recovery and
operator routes are still planned; no inspection table is installed by this work.

On 2026-10-14, Elixir 1.19.6 / OTP 28.5.0.6 executed:

- The fresh exact `bin/check_routines_shadow.exs --profile-store-consumer` lane
  after the reader/codec change: 32 pure cases and all 35 actual authoring
  Authority/Store/SQLite/custody cases passed. This checks unchanged schema 31
  review wire/receipt/recovery behavior after sharing its metadata encoder.
- The final `--profile-consumer` lane after byte preparation: 34 cases passed
  in 8.8 seconds. Seventeen selected Home modules compile with warnings as errors.
  Six reader/preparation cases join the prior 28 envelope/authoring/source/
  fixture/value cases. The Home host and routines are absent from this lane.
- `mise exec -- mix test test/wotex_home/external_inspection_test.exs
  test/wotex_home/authoring_review_test.exs
  test/wotex_home/external_value_unavailable_test.exs`: seven tests passed,
  including independent native/wire round trips without optional producers.
- Formatting, warnings-as-errors compilation, the working 22-contract catalogue
  and Git whitespace checks passed. No full application/native suite, Dialyzer,
  installed host, protocol or physical qualification was run.

The commands use distinct --core-archive/--core-sha, --runtime-archive/
--runtime-sha and --profiles-archive/--profiles-sha pairs, validated before
extraction. No neighboring checkout or production dependency override is added.

| Selected archive | SHA-256 |
| --- | --- |
| Core | 77c742b0b76c3d4d9d4c9d5e5b47e65755a351021de1ddba73369647b96fee61 |
| Runtime | 7c5412ea01dab311357a09276030ca005470c9bd8b0f471e0da3fb8ec5e4b1b4 |
| Profiles | 34a3dcef363a0b072fa2b260efeff8633f8365fd4aecfd1fbbc2c268c82e0b96 |

Consumer lock SHA-256 remains
6ddb05e87f2872a12a244a022d666372d792510c8760188a3ac235ce53c258dd.

| Checked Home input | SHA-256 |
| --- | --- |
| test/fixtures/profiles/external-inspections.json | 530d80b4a384783dc1cd654c0ef040cd8c292d07f3e9d85cb96920a955ead7bf |
| priv/profiles/external-inspection.schema.json | 384dde4b8122ae0be3656595a39cb42c40ab4c45c3523027891a349274b9ed16 |
| lib/wotex_home/profiles/reader_selection.ex | a374e44ef2372475d94860bd4ed45f23ada0db05b6deb658121c75c4ea50352a |
| lib/wotex_home/profiles/external_inspection.ex | 0c522b28ee7b9c1ccd522421d2594dd2c2efe76d7213421ecf965e8dc07d8211 |
| lib/wotex_home/profiles/inspection_preparation.ex | 157452fa362a498c5884719c1bada2a73a452927b8d8baf27ec018286ac7ee6a |
| test/support/profiles_reader_consumer.exs | 85721cb7230356c2c4c54be92891da934d855302f9a1709af5681322145b4320 |

Python independently constructs WOHA frames and raw SHA identities from the
existing literal original envelope/profile/definition fixtures, hashes the full
reader input and encodes ordered original/result/receipt arrays. The two quantities
share the same generic reader basis: their actual selected registrations/capture/
contracts/limits are identical. Their separate exact document and consumption
identities remain different. No sensor/model enum or local producer substitute
is introduced.

Pure cases cover capture/binding digest mismatch, changed archive/accepted
contract/limits, malformed/forged native selection, bounded/improper registration
lists and payload-free reader summaries. Preparation reproduces both independently
framed closure results, refusing missing/extra/unsorted/forged records, first revision
and reader-basis mismatch, wrong semantic join, 35 read records, per-payload and
aggregate byte excess. Aggregate refusal occurs before hashing deliberately
unproven large payloads. Codecs refuse unknown/duplicate/malformed handles,
over-budget tails, noncanonical wire and unsupported retained dispositions.

EI-T1/T3 are partial pure evidence; EI-T2/T4/T5 remain actual durable-writer
obligations. The 35 existing Store cases validate schema 31 authoring reviews,
not an unimplemented external inspection transaction. Preparation neither proves
actor ownership nor grants current observation or physical authority. All commits
remain local on main; no dependency adoption or external action occurs here.
