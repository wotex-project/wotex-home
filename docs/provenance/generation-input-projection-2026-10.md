# Generator input projection software evidence

Recorded: 2026-10-14. Contract:
[bounded generator input projection](../specs/generation-input-projection-v1.md).
Runtime source: e4eb8d4ea85cf728dbdc7b807da80a3108341cea on local main.
Contract and independent vectors preceded implementation in ec0edb4.

## Source, producer and environment

The runtime is Profiles.GenerationInput and the focused suite is
test/wotex_home/generation_input_test.exs. The independently calculated fixture
is test/fixtures/profiles/generation-inputs.json, raw SHA-256
fea95619fdcb9dbdf448159151c5cccad0ac89301042b2ec50bae989e510f359.
test/support/generation_input_oracle.py uses Python compact sorted UTF-8 JSON,
byte slicing, explicit WOHA framing and hashlib; it invokes neither Home nor
WoTEx. It consumes previously frozen two-family contract exports and independent
fixture examples. Actual tests reconstruct the installed producer contracts and
complete frame identities instead of treating the oracle's assertions as native
trusted values.

Consumed core/Runtime/Profiles source remains
ba8ea373244ce57987f47a731b8eca3ccae9b45f. No dependency was updated; mix.lock raw
SHA-256 remains 3372ef86b264343efeedea270b3a8d0548650898043aa0e360daba46c7aaf184.
Environment: macOS 27.0.1 build 26A434; Elixir 1.19.6; OTP 28.5.0.6,
ERTS 16.4.0.6, selected through mise and .tool-versions.

## Executed checks and correspondence

`python3 test/support/generation_input_oracle.py` regenerated the frozen vectors.
The first focused runtime run passed nine tests in 3.2 seconds. After adding
combined capacity/node cases, this affected regression run passed **21 tests,
zero failures, 6.1 seconds**:

```
mise exec -- mix test test/wotex_home/generation_input_test.exs \
  test/wotex_home/authoring_contract_export_test.exs \
  test/wotex_home/authoring_object_test.exs \
  test/wotex_home/authoring_candidate_test.exs
```

The projection suite contributes ten cases. GI-T1 has exact independent document,
hash and safe-summary comparison for temperature and an unfamiliar quantity,
plus unchanged input/frame checks. GI-T2 has malformed/unknown/native/struct,
missing/extra objects, forged complete frame fields, kinds, duplicates/order,
conflicting first revisions, control/UTF-8/range and duplicate-key fixture cases.
GI-T3 covers 32 passages and 131072 selected bytes, 4096 per passage, 32 examples,
262144 raw example bytes, all 64 selected objects, exact encoded size and one
byte/count below required limits, JSON depth/collection/string/node excess,
improper tails beyond ceilings, Unicode split/normalization distinctions,
overlap accounting and unchanged raw fixture decimal/exponent text. GI-T4 covers
exact recomputation, changed ranges/instruction/first revisions/source identity,
forged contract reconstruction, source canaries outside the range, Inspect
redaction and an actual SQLite Store with unchanged revision and file inventory.

Also passed:

* `mise exec -- mix format --check-formatted`.
* `mise exec -- mix compile --warnings-as-errors`.
* `mise exec -- mix woh.spec.check`: 22 catalogue contracts matched.
* `git diff --check` and the staged whitespace check before the runtime commit.

Ephemeral raw run logs are /tmp/home-generation-input-test.log and
/tmp/home-generation-input-regressions.log. They contain synthetic test status,
not private source documents or provider credentials.

## Evidence limits and next owner

This slice establishes structural selection and exact private projection bytes.
It installs no generator, public route, export policy, provider credential,
handoff process or schema migration. First revisions remain supplied assertions
until authenticated Store ownership checks establish them. The ordinary manual
candidate, contract export and frame suites remain green for this change.

Durable generation originals/export authorization, current policy rechecks,
provider isolation, bounded attempts/deadlines/repair, cancellation, unknown
handoff and original recovery still require owning contracts and executable
evidence before a generator is installed. No provider confinement, physical
device qualification, installed signed host or full application-suite milestone
is claimed. All commits remain local and no refs were pushed.
