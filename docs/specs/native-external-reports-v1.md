# Native external reported-value presentation

Version: 0.1.2. Updated: 2026-10-14. Status: accepted successor target.
Owner: WOH.08 H08-03/04, WOH.18 H18-T11/T12.
Implementation: planned. Evidence: missing.

## Result and ownership

The Things task exposes an explicit read-only external report panel. The user
enters an enrolled Thing ID and capability key and chooses Read Report. The
panel reads the selected local or paired controller through its current sealed
session. It displays the exact consumer coordinate, its supplied unit metadata,
semantic/consumer references, report revision and reported freshness. It neither
contacts a device nor imports/selects a profile, publishes a report, creates a
grant, changes a rule or supplies an effect. Navigation and timers perform no
requests. Original receipt lookup remains the separate socket/CLI operator flow.

[External observations](external-observations-v1.md) owns actual source/producer/
clock/sequence checks and the thirteen-field preview. [External values](external-values-v1.md)
owns the exact twenty-three-field value and numeric conversion. The native client
validates closed presentation shape without copying WPF algebra, unit conversion
or C02 interpretation. [Selected controller sessions](native-paired-session-v1.md)
and [session presentation](native-session-presentation-v1.md) own credential,
peer verification, association seals, current owner/epoch and window invalidation.

## Inputs and response validation

Thing ID and capability key are Home IDs of 1..128 bytes. No defaults are
supplied. The SDK sends exactly api_version = 1, operation = external_report_current,
credential, target_id and capability_key through LocalHealthClient's existing
bounded five-second private socket or selected paired domain transport. The
framed response is bounded to 1048576 bytes; strict duplicate/depth validation
precedes Foundation object decoding. Reads never create a pending mutation.

Success requires exactly api_version, outcome = ok and external_report_preview.
The preview requires exactly format = home-external-reported-value-v1,
target_id, capability_key, store_revision, authority_epoch, selection_revision,
resource_revision, report_revision, value, freshness, reason, age_ms and
remaining_ms. Target/key must equal the original request. JSON booleans and
floating-point numbers cannot substitute for integer metadata. Revision/epoch
and elapsed values use signed-64 bounds: authority/selection positive, resource/
store/age/remaining nonnegative, selection/resource no greater than store;
non-null report revision positive and at most store revision.

Freshness is exactly fresh, unknown, stale or missing. Fresh requires null
reason, non-null report revision/age/value and remaining_ms in 1..86400000.
For fresh results age_ms + remaining_ms must be at most 86400000, inherited
from the declaration freshness ceiling. Missing
requires null report revision/age/value and zero remaining. Unknown/stale require
null value, nonempty cause string at most 128 bytes and zero remaining; stale
also requires non-null report revision/age. Every non-fresh result displays
Unknown plus its reported cause, never a retained old coordinate.

A fresh value has exactly the twenty-three fields in the external-value owner.
Require its format, usable quality with null reason, baseline/continuous
continuity, non-null canonical uint64 sequence, IDs/digests/reference shapes and
matching channel ID. Opaque unit, source-time and C02 data are retained as bounded
JSON, not treated as native sensor types. The whole value is at most 65536 UTF-8
bytes, depth eight, 4096 nodes, 256 collection members and 4096-byte strings.
Integer consumer coordinates must be canonical signed-64 C02 sint strings;
boolean coordinates must be actual C02 bool JSON booleans. External coordinates
are displayed as bounded exact JSON. Do not round, convert to Double, infer a
symbol, guess a quantity or classify a boolean as power/smoke. Unit metadata
uses readable sorted JSON; semantic and consumer URIs identify its meaning.

The three reference objects are exactly id, version and sha256, with absolute
URI at most 256 bytes without control/format characters, canonical
major.minor.patch version at most 17 bytes with each component 0..65535, and
lower hex64. Source/receipt epochs are lower hex32; source ref and channel are
Home IDs. Receipt clock is exactly epoch and canonical signed-64 monotonic_us
string, preserving negative origins. Other opaque metadata is bounded JSON;
the native presentation does not claim to verify its producer semantics or hash
algebra independently of the authenticated Store.

## Presentation and transitions

**NR-01 — Bind one selected read.** Capture one original session before I/O.
Read authenticated controller identity before and after the preview. Require
the same deployment/owner/epoch/principal, preview epoch equal to that identity,
before revision <= preview store revision <= after revision. A native credential
reference must still match its retained broker creation verifier and owner/
epoch/principal. Paired delivery repeats current selected association, custody,
certificate clock and peer/session seals; never fall back to a local/manual
credential after paired refusal. No bearer is stored in the view or diagnostics.

**NR-02 — Expire conservatively.** Capture client monotonic time before starting
the read. After completion subtract all client elapsed time, rounded up to
milliseconds, from the Store's reported remaining life. Show a coordinate only
when original freshness is fresh and elapsed < remaining_ms. Equality is expired.
Clock regression permanently retires this presentation until another explicit
read. Sleep/wake or invalidation hides the coordinate. A generation-bound one-shot
client expiry publishes loss of freshness at the remaining deadline; periodic
redraw alone cannot keep a short-lived value visible for another timer interval.
Cancel that expiry on replacement/invalidation. No timer can renew freshness
or issue a request. A new explicit read obtains new Store checks, not a new report instant.

**NR-03 — Fence presentation.** Construction, input edits, navigation and timers
perform no credential/API/device I/O. Editing target/key, changing session or
host sleep/wake clears the view immediately and advances its presentation
generation. An in-flight old result cannot repopulate it. The shared app model
owns this panel across windows, includes it in busy/session guards and clears it
after access changes. Error clears the prior value and reports a read failure;
it never claims mutation uncertainty or offers retransmission of a report.

The panel uses explicit field labels and Read Report. It displays reported
value, semantic/consumer references, exact unit metadata, freshness/cause and
report/selection/resource/Store revisions. No write/probe/approval controls are
introduced. Long references and unknown causes wrap at the existing 599/600/
839/840-point layout edges, with text selection and accessible labels. Expired
values are absent from accessibility output as well as visible text.

## Acceptance

| Case | Requirements | Stimulus and falsifier | Level |
| --- | --- | --- | --- |
| NR-T1 | 01 | Independent temperature, unfamiliar density and multi-channel socket fixtures, plus actual schema 35 preview. Exact request/coordinate/unit/reference correspondence; wrong target, epoch, field, integer or joined provenance accepted fails. | Native software/archive |
| NR-T2 | 02 | Fake monotonic clock covers 0, just before/equal/after expiry, request latency and regression. Unknown/stale/missing/null data never exposes zero/false/old value. Rounding, renewed time or equality freshness fails. | Native software |
| NR-T3 | 01/03 | Owner/session/target/key replacement, permission refusal, lost read reply, wake and delayed result. Old value, changed bearer or mutation recovery instruction fails. | Native software |
| NR-T4 | 03 | Mount fresh/unknown/expired panel at four layout edges; inspect rendering and accessibility text. Clipped fields, automatic read or expired accessibility value fails. | Mounted native |

SDK shape and UI fixtures do not qualify source authenticity, signed installed
custody, physical support or source isolation. Existing physical dispatch remains
default-disabled. No schema or producer dependency change is allocated here.
