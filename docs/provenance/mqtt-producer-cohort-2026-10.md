# Exact MQTT cohort and producer history validation

Recorded: 2026-10-15. Home implementation source:
`bc49271a20bb5a902d60b7d930e12605f985349d` on main.
Owner: [MQTT producer cohort contract](../specs/mqtt-producer-cohort-v1.md).

## Consumed source and availability

Core, Runtime, Profiles and wotex_binding_mqtt select exact WoTEx source
`687a5cd70267fa47dbfb36e28eccad6ef2964fdf`, with their four sparse package
paths in both Home and Nerves lockfiles. The compiled Home consumer uses the
real Runtime exact JSON decoder and MQTT JSONProjection on Elixir 1.19.6 /
OTP 28.5.0.6, separate from the producer's Elixir 1.20.2 / OTP 29 validation.

All four primary Hex package API reads on 2026-10-15 returned 404. Selected
package changelogs have no release entries. The reviewed source delta adds
Runtime Codec.JSON and MQTT JSONProjection, their documentation and independent
vectors; core/Profiles code and existing native-number MQTT Transport remain
unchanged. Jason was already locked. No MQTT backend/client or transitive Hex
package was added. ExBooking, ExMaude and UDP retain their previous exact pins.

GitHub's commit API did not expose the selected new WoTEx source (422 at the
read). Local checks seeded that exact existing commit's objects from the owned
repository into Git dependency caches and verified each checkout HEAD and its
unchanged canonical GitHub origin. This is local committed-source evidence,
not a successful clean remote download. The user must manually push WoTEx before
a clean remote Home build can fetch this cohort; no agent push or visibility
change occurred. Local implementation and validation can proceed meanwhile.

`mix deps.get --check-locked` passed with those exact checked-out sources.
The four selected dependencies compiled. Byte comparison of both lockfiles
against the preceding committed files proves only the three WoTEx source tuples
changed and the one MQTT Git tuple was added; every other tuple is unchanged.
Root lock SHA-256:
`3e08fcf65bcaa05b615df3ab0d0d52d6610a564a65a77f2c55ce6a7cb2a3489a`.
Nerves lock SHA-256:
`cac5fe094b3533145c72d9daa896be8651aa578a38f538359308d1eafcec85f3`.
Lock parity does not establish a firmware build or board behavior.

## Historical and current behavior

Before pin/code changes, Home 86408cb with the predecessor ba8ea373 source
recorded its actual three compiled application digests. An independent Python
assembler froze the exact producer wire and retained source/reader/policy bytes
and hashes under `test/fixtures/profiles/historical-runtime.json`. Both old codecs
accepted that witness before the upgrade. The checker
`test/fixtures/profiles/historical_runtime_oracle.py --check` passes afterward.

Elixir and native Swift now validate historical revision syntax as exactly 40
lower hex bytes. They retain the recorded value; they do not relabel it with the
new pin. Current ReaderSelection and AuthoringContract construction still reject
the old runtime with stale_profile_runtime, using the actual complete current
assertion. Native live tests compare all returned producer fields with the actual
Store export. A valid historical/future revision in a response is representation
only, not an installed-code assertion or control decision.

The Home-only fresh-process fixture decodes the predecessor retained source and
its exact hashes without loading WPF. Current construction with absent code still
refuses. Legacy three-digest archive identities retain their explicit existing
compatibility behavior. No SQL schema/row, original bytes, target, source, grant,
report freshness or dispatch flag changes through this adoption.

## Executed checks

Commands used `WOTEX_HOME_GIT_DEPS=1 MIX_ENV=test` on the Home toolchain.

- 20 tests passed in producer_cohort_test.exs, installed_profile_runtime_test.exs,
  release_components_test.exs and isolated_smoke_test.exs. Coverage includes
  actual dependency HEADs/lock parity, exact decimal/uint MQTT values and original
  token limits on OTP 28, unchanged WPF and ExBooking controls, actual compiled
  inventories, stale current rejection, private Host refusal, source staging and
  package-root legal bytes/copying (including the new MQTT application).
- 10 tests passed in host_profile_installation_test.exs, external_target_test.exs,
  external_observation_test.exs, producer_absence_test.exs and
  native_authoring_contract_test.exs. These exercise actual Host/Store startup
  and restart, frozen original/outcome codecs, a fresh producer-absent process,
  and a freshly compiled Swift client reading two actual Store exports.
- Four source/report custody process tests passed in external_source_owner_test.exs
  and external_report_owner_test.exs.
- After strengthening stale AuthoringContract and producer-absent retained-source
  assertions, the seven tests in installed_profile_runtime_test.exs and
  producer_absence_test.exs passed again. The latter executes four inner tests
  with only Home code on the path; the inner four are not four additional outer
  ExUnit cases.
- `mix woh.native.authoring.contract.smoke`: 44 private-peer cases passed with
  warnings rejected by the Swift compiler. Old/current/other canonical revisions
  decode; uppercase/short/long and malformed/mixed records refuse.
- `mix format --check-formatted`, `mix compile --warnings-as-errors`,
  `mix woh.spec.check` (22 parent contracts), independent witness check and
  `git diff --check`: passed. The staged catalogue check covers 21 committed
  parent contracts; the 22-contract worktree also contains the preserved proposed
  research contract. A scoped reference check resolves 333 local/cross-repository
  links across nine owning documents, without asserting remote availability.

Full suite, Dialyzer, coverage, clean remote dependency installation, complete
release/firmware assembly, installed signing and physical source qualification
were not run. The actual MQTT connection publisher, transport receive clock,
source succession and automatic observation admission remain implementation
work; importing these libraries creates none of them. Physical dispatch remains
disabled by default.
