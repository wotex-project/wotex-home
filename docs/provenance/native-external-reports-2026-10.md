# Native external reported-value software evidence

Recorded: 2026-10-14. Owner: [native external reports](../specs/native-external-reports-v1.md).
Level: native software, mounted visible presentation and actual Store/archive.

The owning contract was committed in `1181e8a` before runtime code. Reference
bounds were reconciled in `3c18272`, deadline expiry in `d83c442`, generic catalogue
and independent Home/source channel identity in `d30d2b3`, and the exact boolean
wire tag in `305071b`. Implementation is local commit `a01ba7a` on main.

The Things task selects read-only generic catalogue entries and explicitly reads
one reported capability through the selected controller driver. Exact declaration
bytes and hashes retain metadata without copying WPF unit/schema algebra. The
value SDK preserves integer strings, actual booleans and external JSON, with
supplied semantic/consumer/unit metadata. It rejects malformed shape and never
casts a generic boolean into a power operation. A Home capability key can differ
from its source channel; Store owns that declaration join.

The panel clears scoped values on input/session/access/sleep/wake changes. It
starts its client clock before I/O, rounds elapsed time upward and permanently
retires a regressed clock presentation. A generation-bound one-shot expiry
publishes loss of freshness without an API request; periodic redraw cannot add
another interval to a short-lived report. Selected identity/owner/epoch/revision,
original native verifier and paired custody/peer/clock seals remain required.

Elixir 1.19.6 / OTP 28.5.0.6 and Apple Swift 6.4
(swiftlang-6.4.0.34.1, clang-2100.3.34.1), Swift 6 language mode and
arm64-apple-macos15.0 target executed:

- `mise exec -- mix woh.native.external.report.smoke`: 67 independent private
  socket cases plus six selected-controller driver cases passed. Cases include
  three quantities, alias key/channel, exact false/C02 boolean, external JSON,
  stale/unknown/missing/lost/refused reads, metadata bounds, URI/version/hash
  refusals, generic retained declaration joins, duplicate/raw document hashes,
  4096-byte schema keys, no power authority, changed owner/epoch and a regressed
  Store watermark. Peer requests match exactly; no device probe occurs.
- `mise exec -- mix woh.native.external.report.panel.smoke`: clock boundaries,
  inclusive and one-shot deadline expiry, request latency, sticky clock regression,
  delayed target/key/session/wake results, read failure and twelve mounted visible
  fresh/unknown/expired renders at 599/600/839/840 points passed. Fresh and expired
  PNGs were visually inspected; controls and metadata wrap without clipping.
- `mise exec -- mix woh.native.controller.session.smoke`: existing actual private
  Store selection/recovery/CAS cases passed, now also checking that an external
  read under a paired selection without a trusted certificate clock captures no
  local credential and has no local fallback.
- `mise exec -- mix woh.native.thing.client.smoke`: 69 existing native legacy
  inspection/refresh socket cases passed after the shared client changes.
- The unchanged three-archive `--profile-target-store-consumer` command from
  [target evidence](external-target-selections-2026-10.md): 81 isolated cases in
  10.2 seconds and 49 actual Store cases in 38.2 seconds passed. Its fresh Swift
  executable reads the real schema 35 catalogue/preview for temperature, density,
  multi-channel and a separate Home temperature/source sample key. Coordinates,
  units, semantic/consumer refs, revisions and decreasing freshness match Store
  and the independent vectors without another Store revision. Consumer lock SHA:
  `6ddb05e87f2872a12a244a022d666372d792510c8760188a3ac235ce53c258dd`.
  Store fixture SHA: `9e4254ef1c37180ebbf9cb919545363d9e45628b307dc69e27523317fdfbc2d2`.
- Full app Swift type checking and standalone app compilation/linking with
  warnings as errors passed (`swiftc -parse-as-library -warnings-as-errors
  -swift-version 6 -target arm64-apple-macos15.0 native/macos/Sources/*.swift`).
  The temporary unsigned binary was not launched or assembled into a bundle. Format,
  warnings-as-errors Elixir compilation, 22-contract catalogue and Git whitespace
  checks passed. The focused operator/Exchange files passed 19 cases in 5.7 seconds.

The first selected-session fixture failed because its temporary metadata URL was
not a physical canonical path. Moving that fixture to its explicit private
canonical directory preserved the production custody guard. A review caught the
false key/channel equality and non-owning boolean tag before implementation was
committed; owning grammar and actual Store alias cases now cover those boundaries.

The mounted foreground fixture returns an empty accessibility tree. It reports
that limitation explicitly and asserts labels/absence whenever the backend
exposes a tree; empty output is not accessibility evidence. The visible expired
render removes the coordinate and the model/label path uses Unknown, but actual
accessibility/VoiceOver remains unqualified. NR-T4 therefore has visible render
coverage, with its accessibility obligation still open.

No OTP release/app bundle, signed custody, installed host, physical source,
source isolation, full application suite or Dialyzer was run. Application pins
and schema are unchanged; source/meaning installation and native v2 authoring/
review delivery remain separate work. Every commit remains local on main.
