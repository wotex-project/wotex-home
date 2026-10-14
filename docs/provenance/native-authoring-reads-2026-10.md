# Native authoring history read evidence

Recorded: 2026-10-14. Owner: [native authoring reads](../specs/native-authoring-reads-v1.md).
Level: Swift/private peers, mounted visible presentation and actual Store/archive.

The owning contract preceded runtime in `6585780`; `a71df9a` reconciled candidate
bundle metadata with its actual owning codec before implementation. Runtime is
local main commit `799e889`. No API route, durable schema, dependency pin or
pending-journal kind changed.

The selected controller driver performs typed object/original reads under the
original local metadata fence or paired session. Before/after identity checks
retain owner, authority and principal and reject a regressed watermark or a
receipt beyond the final watermark. Historical original epochs remain unchanged.
The Things panel stores only verified object metadata and receipt outcomes;
payload-bearing SDK values redact reflection. Startup and input changes make no
request, and input/session/access/sleep/wake retirement discards delayed results.

Elixir 1.19.6 / OTP 28.5.0.6, Apple Swift 6.4
(swiftlang-6.4.0.34.1, clang-2100.3.34.1), Swift 6 language mode and
arm64-apple-macos15.0 target executed:

- `mise exec -- mix woh.native.authoring.read.smoke`: 272 private-peer and ten
  selected-session cases passed. Independently constructed tagged frames cover
  every kind at one byte and its exact ceiling with binary original bytes.
  Existing ordered-array receipt vectors cover import/candidate/review, all 30
  source/consumption/fixture combinations and their opposite proposal outcomes,
  exact S64 maximum and overflow/fraction/boolean refusals. Changed hash/length,
  noncanonical base64, extra/missing fields, duplicate JSON, wrong identity,
  missing/refused/lost replies fail closed. Selected-session cases include old
  original epoch, current owner/principal/epoch substitution, revision regression
  and a future receipt.
- `mise exec -- mix woh.native.authoring.read.panel.smoke`: delayed input/session/
  wake results, no startup request, repeated-click exclusion, canonical epoch,
  missing/error distinction and ten mounted object/review renders passed at
  480/599/600/839/840 points. The 480-point object and review PNGs were visually
  inspected in `_build/native/authoring-{object,review}-480.png`; metadata wraps
  without clipping and no object payload is presented.
- `mise exec -- mix woh.native.controller.session.smoke`: actual private Store
  selection, original recovery and metadata CAS regressions passed, including
  an authoring read with paired clock absence that captures no local credential
  and has no local fallback.
- The explicit three-archive command in
  [authoring operator evidence](authoring-operators-2026-10.md), unchanged except
  its freshly compiled selected fixture, passed 81 independent component cases
  in 10.2 seconds and two Store workflows in 26.3 seconds. Each real Store/socket
  now also runs the freshly compiled Swift SDK for its independently authored
  temperature or research source, compatible candidate and complete review.
  Swift payload SHA/size/first revision and reconstructed typed receipts equal
  the retained Authority records without another revision. Credentials enter
  the child through the private pipe rather than command arguments.
  Consumer lock SHA remains
  `6ddb05e87f2872a12a244a022d666372d792510c8760188a3ac235ce53c258dd`.
  Store fixture SHA is
  `b91e3e1fc4959a1caff204810bf881181967c8b40dabbeaf441a332479e03026`.
- Full-app warnings-as-errors Swift type checking passed. Format,
  warnings-as-errors Elixir compilation, the 22-contract catalogue and Git
  whitespace checks passed. Application dependency sources remain unchanged.

Mounted images establish visible fixture presentation, not installed VoiceOver
or signed paired custody. Native import/candidate/review mutations with durable
pending custody, explicit passage presentation, provider export/handoff, host
meaning/source installation, application producer adoption and physical
qualification remain separate obligations. The broader catalogue axes remain
partial/missing.
