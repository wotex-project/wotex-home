# Retained countdown clock correspondence v1

Version: 0.1.2. Implemented inert monotonic capture/decoding, 2026-10-08.
WOH.04 owns temporal admission; WOH.14 owns retained clock correspondence.
This prepares countdown lifecycle inputs. It creates no admitted schedule,
activation, timer, clock-source installation or device effect.

A countdown can depend on qualified continuous monotonic time while wall time
is unavailable. `ClockSample.monotonic/4` checks the complete closed sample,
valid original boot and clock generation, signed-64 current coordinate,
nondecreasing time, continuity and the original maximum sample age. A continuous
sample must retain its qualification digest. That digest is a host/source
assumption, not qualification established by the codec. The function returns
only the checked monotonic coordinate and derives no UTC interval or wall
confidence. Existing wall-time advancement remains separate.

`ActivationClock` retains this distinction with the new closed format
`wotex-home.schedule-activation-monotonic-clock.v1`. Its five ordered members
are format, the existing six-field deployment/owner/epoch/boot/generation/runtime
scope, complete original clock sample, checked Store observation and initial
watermark. Scope and integer bounds retain their existing checks. The sample
must have unqualified wall confidence and null UTC bounds, qualified continuous
monotonic state and unchanged boot/generation. The reconstructed snapshot retains
null UTC interval and the existing typed temporal-unavailable reason. Neither
decoding nor successful countdown arithmetic changes that wall-time refusal.

Documents remain canonical compact JSON, at most 4096 bytes, with the existing
allocation limits. Unsupported formats, expanded members, floats, noncanonical
bytes, stale/discontinuous samples, wrong boot/generation and malformed scope
refuse. The new format cannot alias the existing qualified-UTC
`wotex-home.schedule-activation-clock.v1`, and a qualified wall sample cannot
be substituted into the monotonic format. Existing qualified-UTC records retain
their exact canonical bytes and historical decoding.

Countdown activation arithmetic requires the source's original boot/generation,
a start at or before the captured coordinate and a due instant strictly after
it. Initial watermark is that captured monotonic coordinate. Calendar and UTC
interval activation still require the complete qualified UTC interval within
the source's uncertainty tolerance; they refuse a monotonic-only snapshot.
Capture continues through the existing lazy Store clock context: both actual
surrounding receipt samples must contain the observation, and a countdown
accepts no timezone record. A receipt-clock tuple alone supplies no temporal
snapshot.

The independent
[Python generator](../../test/fixtures/schedules/generate_countdown_clock_vectors.py)
authors complete canonical clock/sample bytes, their SHA-256 and thirty-two
boot/generation/start/due boundary cases without reading Home code, a live clock,
key or device. The
[frozen fixture](../../test/fixtures/schedules/countdown_clock_vectors.json)
has closed inert software scope and a 16,384-byte ceiling. Additional focused
cases check format substitution, malformed scope, null UTC, maximum age,
rollback, continuity and surrounding receipt/timezone capture.

The separate [durable countdown lifecycle](schedule-countdown-lifecycle-v1.md)
now consumes this source-specific correspondence in Store admission, occurrence,
queue/claim/handoff and restart expiry. Current readiness no longer requires due
to remain in the future. UTC sources keep their qualified wall-time requirement.
The current host owner still provides no installed monotonic-only source;
installed clock/sleep, autonomous runtime and physical qualification remain
independent obligations. This original clock format changes no schema or archive
shape and carries no clock-source or effect authority.

On 2026-10-08, thirty-two affected pure clock/window/planner/consideration/context
cases passed, including all eight activation-clock cases, the independent
thirty-two-vector boundary oracle and a near-signed-64 monotonic coordinate
beyond the UTC domain. All fifty-five Store admission/lifecycle, temporal
artifact and actual clock-owner cases also passed. Existing Store countdown
refusal and qualified-UTC history/recovery remained in that run. The fixture
regenerates byte-for-byte as 7,233 bytes. A separate two-case calendar execution
follow-up had one `observation_unavailable` claim refusal while retaining its
queued/spent identity. The following
[fixture extraction](calendar-execution-traces-v1.md) removes repeated identical
historical reads from the timed execution sequence while preserving every
immutable-row/integrity check and the actual receipt clock and report-age guard.
Three focused regressions subsequently passed. This remains calendar/interval
regression evidence, not countdown execution or installed-clock qualification.
The complete combined follow-up then passed all 132 interval/calendar execution
traces with zero failures, using the current monotonic-clock implementation and
the existing qualified-UTC execution sources.
