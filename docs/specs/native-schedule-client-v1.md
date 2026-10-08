# Native schedule input and client v1

Version: 0.1.0. Implemented inert Swift correspondence and private-socket SDK,
2026-10-08. WOH.08 owns native presentation/custody, WOH.15 the adapter,
WOH.04 temporal admission and WOH.14 durable operations.

`NativeScheduleWire` implements the existing closed
[source](schedule-source-v1.md) and [original operation](schedule-operation-v1.md)
documents. Review/admission retain the complete canonical source and narrow
absolute Boolean power rule. Source, rule, target and digest joins are rebuilt;
the declared author is retained without manufacturing authorization. Activation
and suspension have their separate exact forms. Every decode reconstructs the
same UTF-8 bytes. The rule document uses the core's sorted closed object keys;
the source and outer operation retain ordered arrays. Swift never imports a
Home evaluation engine or evaluates a device protocol.

Before Foundation parses, the bounded scanner checks document size, container
depth/member counts, ASCII string lengths and nineteen-byte scalar tokens.
Source is at most 4096 bytes, rule 2048 and operation 8192. Embedded canonical
source/rule strings use only quote/backslash escapes. Alternate escapes,
whitespace, expanded fields, floats, negative source integers, oversized values,
duplicate object keys and alternate rule grammar fail reconstruction. Explicit
signed-64-bit identity is preserved, including maximum source, rule and resource
revisions. Calendar labels use Gregorian dates and seconds 0–59; no locale or
current OS zone resolves a label. The five inert trigger forms retain the
existing bounds. Supporting a countdown record creates no countdown admission.

`NativeScheduleClient` uses the existing same-user private peer, protected native
lease where applicable, four-byte framing, complete five-second monotonic
deadline and strict response scanner. Its transport permits only the seven
existing schedule operations. Requests cannot supply a clock sample, timezone
bytes, endpoint, qualification or effect operation. An authenticated controller
identity supplies the expected principal to the calling workflow. Source author
and returned principal/epoch/operation/kind/input digest must match the original.

Content receipts check the exact eight fields, state, artifact digest and
successor revision. Lifecycle receipts check all fifteen fields, exact admission,
generation successor, barrier and final revision, affected/unknown counts and
initial watermark. The final revision is barrier plus affected requests plus
one. Activation retains a UTC initial boundary; suspension has admission zero
and watermark minus one. No counters assert an effect or recall a handed packet.
A returned result is bound to the complete typed original and principal before
a workflow may resolve it.

Readiness is a separate explicit read. Inactive has exactly three fields;
otherwise the full lifecycle record describes current active/suspended state
and reason. A withdrawal has its reserved digest-derived operation identifier.
The read's initial watermark remains the original activation boundary; it is
not a current considered-through cursor. Missing clock, stale generation and
withdrawn authority can change readiness without changing an immutable original.
Readiness never authorizes a new effect or registers a timer.

The timezone read binds exact name/local label, digest and
`calendar_calculation_only` scope. Zero, one or two ordered instants preserve
gap/fold choices, including null positions. This is calculation input, not
qualified clock confidence. Malformed counts, changed identity, expanded fields
or an authority-bearing replacement scope refuse.

Exact original lookup and retry use the original document. A missing result is
represented as missing, never success. A transport failure remains uncertain;
the SDK starts no automatic recovery or replacement operation. Durable native
publication, journal-version migration, shared recovery and a composed schedule
panel remain the next delivery slice. The SDK itself neither stores an original
nor opens Keychain custody. Existing rule, access and request workflows retain
their current formats.

The independently serialized Python corpus contains fifteen original documents
with static SHA-256 values and sixty-one malformed-input refusals; it is bounded
to 65,536 bytes (61,714 retained). Both Swift and the actual Elixir codec check
that corpus. `mix woh.native.schedule.wire.smoke` compiles Swift 6 with warnings
as errors under a private module cache and checks complete reconstruction,
allocation refusals and calendar labels. `mix woh.native.schedule.client.smoke`
checks ninety-four independent private-socket cases: every mutation and exact
lookup, missing results, a lost reply followed by explicit lookup, refusal,
changed receipt joins, generation/count/range damage, readiness and timezone
choices. Fixture credentials are synthetic, with no Keychain or device worker.

Both checks passed on 2026-10-08. The first wire task expected the wrong fixture
count in its completion marker; the marker was corrected from sixty-three to
the actual sixty-one refusals. Forty-two affected core codec/actual-Store/API
tests passed in 9.4 seconds, including the actual schedule socket/private-file
routes with no socket exclusion. The entire macOS application source also
typechecked with Swift 6 warnings as errors, including these SDK files. The
assembly source closure and macOS CI include both files/checks; remote CI has
not run. Native journal/panel, signed installation, autonomous runtime proof,
installed clock and physical qualification remain separate work.

After extending the maximum-integer record to include the complete rule revision,
the native wire smoke passed again. Seven final corpus/macOS inventory/SPDX/
native-dependency cases passed in 0.8 seconds. Locked formatting,
warnings-as-errors compilation, twenty-contract workspace/nineteen-contract
staged metadata, local document references and Git whitespace passed. This
slice verifies source compilation and client correspondence; it assembles no
new app artifact and changes no installed service registration.
