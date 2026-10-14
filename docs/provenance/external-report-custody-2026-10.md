# External transport receipt custody evidence

Recorded: 2026-10-14. Owner: [receipt custody](../specs/external-report-custody-v1.md),
WOH.18 H18-04/05/08, H18-T3/T4/T8/T11/T12; WOH.03 H03-T3/T5.
Level: bounded software and archive correspondence. No physical qualification.

The requirements and numeric/replay clarifications were committed before runtime
work in `174a608`, `a8537d7` and `9f837b8`. Independent Python bytes/hashes were
frozen in `6600c3e`; runtime and process cases are implemented in `83caa1d`.
ExternalReportOwner receives no database connection or bearer. Only the configured
publisher may buffer data; only the currently resolved configured Store may borrow
or finish a report. Its original host receive instant bounds expiry and cannot
be renewed by publication, checkout, exact replay or a duplicate packet ID.

On Elixir 1.19.6 / OTP 28.5.0.6, the exact three-archive `--profile-consumer`
command passed 80 cases in 10.1 seconds: the previous 64 profile/target/source
cases and 16 receipt-owner cases. The source closure compiled 36 Home modules
from fresh extraction, with zero warnings. Core/Runtime/Profiles archive hashes
and consumer lock are unchanged from [target evidence](external-target-selections-2026-10.md).

The new cases use actual source custody and a separate configured Store receiver.
They compare temperature, previously unseen density and multi-channel bytes
against independent canonical vectors after substituting only the actual owner
clock. They verify original deadline, caller identity, exact checkout/finish,
source replacement, cancelled/consumed/expired tombstones, nullable/maximum
unsigned sequence strings, full correlation retention at 1024 originals, exact
byte and active-count ceilings, timer release, publisher/source-owner/Store
death, new incarnation and actual optional producer removal. Foreign calls,
malformed fields/decimal clocks, wrong source/epoch, future time and resource
excess refuse without publication. Process status redacts private state/message.

The cold report-owner, source-owner and target wire files passed nine cases in
0.08 seconds. `mix format --check-formatted`, `mix compile --warnings-as-errors`,
`mix woh.spec.check` (22 catalogue contracts) and `git diff --check` passed.
No full application suite, native build, Dialyzer or socket exclusion was used.

This proves RC-T1–RC-T4's exercised custody mechanisms. It does not accept a
canonical observation, prove channel/schema/semantic interpretation, install a
host transport, establish physical source authentication, widen a grant or
qualify hardware. Durable observation/current-use integration is the next owning
transition. Complete delivery still requires its schema, original/sequence
history, Store boot clock, source/current target guards and physical cohorts.

Regenerate the independent receipt fixtures with
`python3 test/support/external_report_oracle.py`; it invokes neither Home nor
WoTEx. Publication's public JSON encoder is intentionally still required for
exact byte comparison, while retained status/checkout/retirement need no producer.
