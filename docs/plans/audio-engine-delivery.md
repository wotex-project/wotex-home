# Optional audio completion contract

Version: 0.2.0. Updated: 2026-10-13. Status: accepted programme.
Implementation: planned. Evidence: missing.

Deliver an independently usable Rust audio engine and optional Mix facade for
one music timeline across qualified native/network outputs. This is a consuming
project component contract. Select an owned independent/consumer source project
and facade before implementation; no WoTEx audio package is registered. WoTEx
WST.01–02 own optional protocol-stream joins; this engine owns sample processing,
OS capture/output and acoustic qualification. Device definitions remain external.

## Owners and order

| Stage | Required artifacts | Exit evidence |
| --- | --- | --- |
| A0 contract review | MAU.01–04 closed values, clock/error budgets, adapter profiles and IPC; independent normal/adverse walkthrough | No hidden input/default, unbounded queue, ambiguous original or capability-as-qualification claim |
| A1 source cohort and scaffold | Review exact Sendspin spec/Rust server proposal, time filter and native transport sources; compatibility/notice inventory; explicit independent/consumer component and Rust workspace allocation | Public archive closure, application-free loading, pinned sources and explicit protocol gaps |
| A2 native timeline | MAU.01 constructors/schemas/vectors, MAU.02 Rust scheduler/buffers/clock mapping, MAU.04 bounded IPC | Independent affine-clock/format oracle, stale generation/pressure/fault cases; no real device required |
| A3 independent native output | Native Sendspin server/client interoperability and a real consumer-selected hardware output; native output timing | Current pinned-spec conformance and two public archive consumers; software timing separate from physical skew |
| A4 macOS capture and Bluetooth | Specific process-tap source, specific Core Audio output, private source ingress and per-route tail calibration | Installed permission/revocation/PID reuse/default-route/sleep cases; exact portable-audio cohort measured |
| A5 scheduled network output | AirPlay profile, audited native helper and clock projection; source/build/pairing inventory; private helper credential/pairing channels before production use | Current exact receiver cohort, no credential argv/diagnostics, independent peer and mixed host-output acoustic campaign |
| A6 Cast | Ordinary Cast/native group; separate custom Sendspin receiver on supporting firmware; optional OS Bluetooth fallback | Missing-API refusal, full descendant closure, measured group grade; alternative profile earns its own evidence |
| A7 legacy/native group | Exact local control/HTTP source profile, private stream server, source takeover and group membership | Real codec/pull behavior, retained unknowns and acoustic classification; unsupported is an honest completed assessment |
| A8 delivery | Two independent consumers, public facade/host ABI, native artifact notices and host lifecycle/cleanup guides; optional WST protocol join | Relevant archive, documentation, native/interop and milestone gates; no automatic installation or release |

Stages A2–A7 use focused mechanism tests. Full changed-package and native
quality checks belong to milestones after the corresponding sources/hosts are
stable; avoid unrelated repository-wide suites. Physical gates record the
exact source/build/profile/firmware/codec/clock/calibration and acoustic setup.
An unimplemented target, a software peer and measured installed hardware remain
separate catalogue/evidence states.

## Source strategy and contributions

The inspected `sendspin-rs` main revision
`0cae6bbf5e794f87dfbc986dac2e812fefded12c` is client-oriented. The unmerged
[server proposal](https://github.com/Sendspin/sendspin-rs/pull/87) is a candidate
for review, not a selected production dependency. Its declared scope defers
per-client formats and external-output registration. Compare it to Sendspin
spec `ee8aad9660fc57345e726a888486f47f66a41f97`, especially timing,
availability, encryption/pairing and source-role rules. Keep the reference
Python server as an independent oracle; do not require it in production.

Potential generic contributions: current-spec Rust server parity, explicit
external-output/clock ports, hardware-time feedback, per-output resampling,
bounded late joins, private AirPlay-helper credential/pairing channels and
independently reproducible conformance/fault vectors.
Consumer enrollment, room labels, policy, custody and writer code do not belong
in those patches. Preserve compatible public APIs and reviewed notices. Prepare
logical local patches; remote publication and release remain maintainer actions.

Reuse an existing AirPlay transport where justified while the Rust engine owns
the common timeline. Rewriting a transport is a separately specified stage,
not an implicit requirement to make all dependencies Rust. A source fork does
not create missing firmware APIs or actual output timing evidence.

## Completion and unsupported cohorts

Every claimed adapter profile implements its advertised finite operations and
passes independent tests. An unsupported cohort has an explicit refusal and
recorded reason; it is not secretly mapped to another protocol or labeled synced.
Engine correctness requires bounded loss/cleanup and honest results even when
no physical cohort earns a synchronization grade. Compatibility experiments
remain best_effort until their exact acoustic qualification passes.

The normative owners are [MAU.01](../specs/audio-engine/MAU.01-media-session-values.md),
[MAU.02](../specs/audio-engine/MAU.02-timeline-synchronization.md),
[MAU.03](../specs/audio-engine/MAU.03-output-adapters.md) and
[MAU.04](../specs/audio-engine/MAU.04-native-host-capture.md). Their catalogue currently
contains no implementation modules or executed evidence.
