# Last paired power receipt software evidence

Executed 2026-10-15 on Apple Silicon macOS 27.0.1 with Elixir 1.19.6,
OTP 28.5.0.6 and Swift 6.4, targeting macOS 15 with Swift 6 warnings rejected.
This records the [last resolved paired power receipt contract](../specs/native-paired-power-receipt-v1.md),
owned by WOH.08 H08-T9 and WOH.15 H15-T8. Positive installed signing, Keychain,
trusted certificate-clock and supported-host TLS qualification remain separate.

The contract was committed before implementation in `0d6ff90`, then refined
before the corresponding implementation in `a2b209e` (read-query metadata versus
immutable original custody) and `acc4bac` (raw principal before DTO projection).
Core implementation and actual transport acceptance: `e8b1a70`. Shared driver,
Activity model/panel and model acceptance: `168d7ec`.

## Implemented boundary

The actual private paired factory has a distinct fixed power-receipt purpose.
It acquires actual signed-app access and existing Keychain custody, keeps the
complete original association snapshot and one five-second continuous lease,
and exposes only original/result/deadline metadata. The raw helper repeats
original association/verifier correspondence, brackets status with current read
scope and checks raw principal before the ordinary receipt DTO omits that field.
It exposes no reusable session, arbitrary SDK callback or mutation route.

The shared Activity model retains one resolved paired power/cancel original in
memory. Explicit use copies its epoch/operation without I/O. Matching lookup
resolves the recorded association even when another controller is selected.
Driver generation, complete association snapshot, exact retained entry/inputs
and the original delivery deadline fence publication. Failure and not-found
cannot call local custody, resolve pending work or change reported state.

## Executed acceptance

`mix woh.native.paired.power.receipt.smoke` passed against the final code. It
compiled all 80 non-main production Swift sources plus the fixture, then checked:

- PR-T1: literal frozen association/pending vectors; original destination with
  another association selected; local/non-power/phase, absent association,
  controller/verifier/context substitutions; read-only current scope; permission,
  target, epoch and revision drift; wrong receipt identity and future revision.
- PR-T2: the actual unsigned production factory refuses before clock/Keychain/
  networking; a driver missing its clock refuses without local acquisition and
  keeps the other selected controller. No successful signing seam is injected.
- PR-T3: no startup I/O, one retained original, explicit field copy, found,
  absent, failed, expired and missing-reader results, duplicate click, held
  completion after changed fields/generation/reference, remote unmatched lookup
  and shared busy refusal. Local capture count stays zero and pending entries
  remain unchanged. Cancel/Retry cannot use the retained read-only reference.

The actual shared Activity panel rendered at 480 and 840 points. Both images
were inspected: controls fit vertically at narrow width and horizontally at
wide width, the original-controller explanation and disposition remain readable,
and mutation controls are disabled for this reference.

`mix woh.native.paired.recovery.smoke --power-receipts` passed. Its independent
raw-key foreground adapters use actual Authority pairing, pinned TLS and SQLite:
found original held receipt, absent receipt, byte-identical pending custody and
unchanged Store revision across reads/identical retry, then reads after Store
restart. Revoked credentials refuse. A separately provisioned read-only
principal with no targets sees not-found for the same epoch/operation, and its
read does not advance the Store revision. A fake TLS response with another
principal is rejected before ordinary DTO projection. Existing original power
lookup/retry acceptance remains in this bounded cohort. These are actual
transport/Store checks, not successful protected-app factory construction.

PR-T4 regressions passed:

- `mix woh.native.controller.session.smoke`: actual local Store reads, shared
  selection, CAS, local original recovery after external selection and remote
  no-fallback. This preceded only the shared model's missing-reader error-type
  correction; the final model fixture and local workflows compile that change.
- `mix woh.native.session.operations.smoke`: all 34 live local original
  model/recovery workflows, including existing receipt/retry/cancel behavior.
- Final full-app `swiftc -parse-as-library -typecheck -warnings-as-errors
  -swift-version 6 -target arm64-apple-macos15.0` with the existing six framework
  imports: all 81 production sources passed in 36.8 seconds. A private temporary
  module cache was removed on exit; no app/release artifact was built.

The first metadata fixture incorrectly treated a fully self-consistent second
association as an invalid read query. Independent vectors revealed that both
records intentionally share principal/verifier/controller fields. The contract
now distinguishes that inert query from the UI's immutable original record;
the refusal vector uses an absent association ID and the positive routing case
keeps the original ID while selecting the other record. Review also caught the
ordinary DTO's omitted principal; the production raw wrapper and real/fake peer
acceptance now check it before projection. The first local regression compile
found a new dependency on the full app's driver error type; using the existing
pending-boundary error restored the smaller client closure. Final affected runs
passed after these corrections.

## Validation, provenance and cleanup

Formatting, Home warnings-as-errors compilation and Git whitespace checks pass.
The first incremental compile exposed a stale development runtime cache: the
newly pinned JSON module existed in source and the test cache, but its beam was
absent in the development cache. Recompiling only `wotex_runtime` and
`wotex_binding_mqtt` with `mix deps.compile <dependency> --force` restored the
module; both dependencies and the subsequent Home warnings-as-errors compile
completed without diagnostics. No dependency source or pin changed. This remains
a targeted cache repair, not a clean uncached dependency build.
The catalogue checker passed all 22 working contracts and an isolated export
of all 21 staged contracts; all 257 staged Markdown local targets exist in the
index or named sibling sources. Unrelated research edits remain excluded from
these commits. Contract implementation/evidence axes remain partial/missing for
their broader installed and physical obligations.

Dependency locks are unchanged: root SHA-256
`3de9b75ee702ed6bd95f846b2681b071c1e8266cd2daa4615bf625f55741f913`, Nerves
`05a334979d42c0717e7df1c0f85e1bb6529d9b370acb9f871fba3750c8afc34f`.
WoTEx remains `687a5cd70267fa47dbfb36e28eccad6ef2964fdf`; ExBooking remains
`25ad04548c01e5a24c5505acfbe063550d3efaa0`. This consumer-only feature changes
neither sibling nor a Store schema, dependency pin, authority permission or
physical dispatch default.

The documentation-only agent supplied the two new/affected task headers.
Documentation-stripped AST, non-documentation bytes, formatting, references and
exactly one following blank line were checked. No behavior was delegated to it.

Each native task removes its private compiler/fixture root in `after`.
The completed agent scratch and final full-app typecheck cache were removed.
After inspection, all 588 generated native PNG previews were removed, recovering
181.7 MiB of apparent file size; `_build/native/` is empty and free disk is about
30 GiB. Current receipt fixture/typecheck scratch prefixes are absent. No Docker
image or container was created for this slice; remaining unrelated images and
volumes were preserved. No full suite, Dialyzer, firmware, signed package,
hardware campaign or broad Docker prune ran.
