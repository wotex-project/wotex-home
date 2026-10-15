# Consumed report lifetime evidence

Reviewed: 2026-10-15. Scope: the
[consumed lifetime successor](../specs/external-report-lifetime-v1.md).

## Source review and implementation entry

Home aa8ec898 implements the inert original-reader/routine projection. Review of
ExternalReportOwner.retire/3, Store.external_receipt_clock/3 and the immutable
ExternalObservation receipt found no retained original owner deadline after
consumption. The native guard has that deadline while checked out, but retirement
drops it and durable v1 stores only the original Store receipt coordinate. A
future current routine collector cannot derive the deadline from processing time,
a replacement owner's configuration or a historical fixture. Qualified Mapping
installation is a separate missing owner; ordinary external read approval is not
routine qualification. The lifetime successor is the concrete prerequisite.

The contract closes a Store-only native API, thirteen-member result, original
signed-microsecond coordinates, exclusive expiry, state/caller/source guards,
bounded private consumed retention and unchanged public/durable formats. It
adds no schema number, current routine route or physical authority. The independent
Python entry oracle uses integer addition over the existing three original report
fixtures: -5 us + 60000 ms = 59999995 us. Before/equal/after deadline outcomes are
literal vectors. The offline schema is closed and exposes no body or new UTC.

Before production code,
`WOTEX_HOME_GIT_DEPS=1 mise exec -- mix test test/wotex_home/external_report_lifetime_schema_test.exs --warnings-as-errors`
passes **two tests**, seed **909787**, **0.04 seconds**, on Elixir 1.19.6 /
OTP 28.5.0.6. These are entry grammar/vector cases, not RL-T1–T5 execution.
The working catalogue validates 22 contracts. Native custody, current collection,
reviewed installation, Store commit, host and physical evidence remain open.

Formatting, both Git whitespace checks, all 21 indexed catalogue contracts and
174 changed indexed Markdown links pass. The independent catalogue workspace
was removed. No full suite, Dialyzer, archive build or Docker resource was used
for this specification entry. Existing research changes remain outside the index.

## Native custody implementation

The contract/schema/vector entry was committed as 606880f2 before production
implementation. ExternalReportOwner now retains one private receive/deadline pair
only on consumption, while releasing all prior active slots, bodies and checkout
monitors. lifetime/3 checks the configured Store before any source lookup, then
scope, consumed state, original signed bounds, one call-local source snapshot and
exclusive deadline. Public safe receipts, original replay, correlation tombstones
and quotas stay unchanged. No current-default TTL or sampled receipt fallback is
used. The documentation-only agent reviewed the module's public explanation,
including the distinction between consumed custody and a durable observation
commit; it preserved all non-moduledoc bytes and created no artifacts.

`WOTEX_HOME_GIT_DEPS=1 mise exec -- mix test test/wotex_home/external_report_lifetime_test.exs test/wotex_home/external_report_lifetime_schema_test.exs test/wotex_home/external_report_owner_test.exs test/wotex_home/routine_external_fact_test.exs test/wotex_home/routine_external_fact_schema_test.exs --warnings-as-errors`
passes **29 tests**, seed **553824**, **2.3 seconds**, on Elixir 1.19.6 /
OTP 28.5.0.6. This includes twelve lifetime-native cases, two entry schema cases,
two existing owner configuration/status cases and thirteen projection cases.
The tests execute actual public source/reader/report owners, three complete
frozen witnesses and nine before/equal/after deadline probes in a fresh VM.
Only clock/nonce seams are replaced in that isolated boundary VM; production
has no injectable clock. Wrong caller refuses even with the source suspended.
Configured Store name replacement, source replacement/loss, empty owner restart,
producer absence, malformed private clock ranges, body/monitor release and exact
original replay are exercised. No private clock or code mutation escapes a child
VM or owned test process.

`HOME_REPORT_OWNER_FIXTURES=test/fixtures/profiles WOTEX_HOME_GIT_DEPS=1 MIX_ENV=test mise exec -- mix run --no-start --no-compile -r test/test_helper.exs -r test/support/profiles_report_owner_consumer.exs -e ':ok'`
passes **16 tests**, seed **825260**, **0.8 seconds**. The existing archive-consumer
module is executed here against pinned native dependencies and an explicit
fixture root; this is native regression evidence, not a renewed archive build.
Its original byte/count/1024, expiry, source/Store failure, correlation and absent
producer cases pass. The added lifetime assertions preserve null and maximum
uint64 sequences and work with Core JSON actually removed. An initial direct
Mix-test invocation emitted an unmatched support-file warning and exposed a
misnamed test variable; both were corrected before the passing explicit runner.
The first new producer-absence probe removed an alias path rather than the actual
BEAM path; the corrected probe removes the actual path and asserts module absence
before checking successful native consumption/lifetime. Neither initial failure
is counted as evidence.

`WOTEX_HOME_GIT_DEPS=1 mise exec -- mix test test/wotex_home/mqtt_publisher_test.exs:106 test/wotex_home/mqtt_publisher_test.exs:136 test/wotex_home/mqtt_publisher_test.exs:169 --warnings-as-errors`
passes **three tests**, **27 excluded**, seed **63763**, **5.0 seconds**. Actual
loopback broker reports traverse current reviewed Store selection, exact units,
multi-channel publication and lost-worker-reply original recovery. This confirms
bounded observation regressions; the lifetime API is not yet integrated into a
qualified current routine collector. All owned brokers, Stores and temporary
MQTT directories are stopped/removed by the existing test cleanup.

| Input | SHA-256 |
| --- | --- |
| Report owner source | b8e821c9e44ea3d0cc064ce4af7a7162e3f57bf338bcb34bd582c8dc66cb2ce7 |
| Independent lifetime vectors | 4c02cfa807ec4302a05e9508f3428156fb306ba9de89c7e1aac949bd283f37d6 |
| Offline result schema | 09e4df5e0014c67df621021cb477206170190ddac6715435d05ef3cd05f6d7c9 |

This completes RL-T1–T5 in bounded native software scope. There is no durable
schema/receipt/backup change, new current routine route, installed host claim,
physical qualification, automatic mapping approval or changed dispatch default.
Reviewed Mapping installation and complete current collection are still required.
No full Home suite, Dialyzer, native packaging or Docker resource was needed.

Final formatting, warnings-as-errors compilation and the 22-contract working
catalogue pass. A disposable index projection validates all 21 committed
contracts and 175 changed indexed Markdown references. Both Git whitespace
checks pass. Cleanup initially detected an older generated MQTT specification
index: inspection found only 180 copied Markdown/YAML contracts (2083423 bytes),
and lsof confirmed no open files before removal. The final scan confirms all
owned catalogue/archive/MQTT workspaces absent. Shared build/dependency/PLT caches
and unrelated Docker data remain intact. All commits are local on main.
