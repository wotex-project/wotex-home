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
