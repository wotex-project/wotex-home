# External-profile native pending custody evidence

Recorded: 2026-10-15. Owner: [v9 custody](../specs/native-pending-external-profiles-v9.md)
NP9-01/02/03 and NP9-T1/T2/T3. Requirements preceded implementation in 8a26e70;
independent corpus was frozen in 808dcae. Runtime and focused native checks:
c2b12d7 on local main. The paired historical future-marker correction is recorded
in 1d33cef. No Store schema, dependency, producer API or
dispatch changed.

## Implemented boundary

The v9 journal retains a complete external inspection, trust or target-selection
original in its own external_profile category. It reuses the implemented owning
original codec, preserving exact canonical bytes, SHA, epoch, operation ID and
expected revisions. Manual, native operator and paired custody are historical
metadata; native/paired creation floors and context correspondence are checked.
Only pending phase is accepted, and reflection redacts originals and entries.

The existing bounded scanner grants a larger escaped string only under the v9
root, exact marker, valid kind and original-document slot. It applies the owning
16384/4096/32768 decoded-byte limit before reading the inspection/trust/target
string. Ordinary slots and all earlier roots keep their bounds. Every original
is revalidated by the owning canonical codec after the outer scan.

Private publication uses the unchanged single-account file paths, filesystem
custody, whole-file CAS and sixteen-row capacity. First external retention selects
v9; no-op, resolution, empty roots and later older-category writes preserve the
required version. Generic paired correspondence now accepts retained v9 through
the existing version-aware comparison rather than adding another fixed marker.

First local capture and every recovery action for this new category refuse while
its fixed consumer is absent. Paired first capture uses the same disabled action
guard. Metadata loading and disposable private-file fixtures remain usable; no
credential, signing, clock or transport authority is inferred from a record.

## Executed checks

Pinned Elixir 1.19.6 / OTP 28.5.0.6 through mise; Swift 6.4 in Swift 6 mode,
warnings-as-errors and arm64 macOS 15 target on the macOS 27 development host.

- `python3 test/support/native_pending_external_oracle.py` reproduced 182 valid
  and 276 invalid frozen roots without importing Home, BEAM or Swift. SHA256:
  `e92959896c0460d06ca9c0ef77be8f650ff3be403040880a5fb94bc2e30f048b`.
  These include all 43 previously frozen owning originals across three custody
  types, both quantity families/multichannel, signed bounds, mixed/retained older
  categories, sixteen-row capacity and malformed nested originals.
- `mix woh.native.pending.external.smoke` passed every frozen root with exact
  bytes/hash, accessors, redaction, old-root refusal and malformed input checks.
  It also exercised exact-slot size limits, neighboring-slot refusal, invalid
  UTF-8, trailing bytes and the 8388608-byte file ceiling.
- The same task passed actual private-file upgrades from every v1–v8 root,
  no-op confirmation, stale CAS, exact resolution, empty/later version retention
  and maximum-revision refusal. Separate child processes retained then exited
  and reloaded the original. Gated external/external and external/ordinary races
  each produced one winner and one conflict/lock-capacity refusal, retained the
  seed row and reloaded the winning file in another process.
- Generic paired capture, retention and resolution correspondence passed in a
  v9 file containing an unrelated external original; a substituted prior snapshot
  refused. Instrumented local begin/recovery, paired coordinator recovery and
  actual paired recovery factory checks made zero credential, socket-path, runner
  or clock-producer calls. Journal bytes/snapshots remained unchanged.
- `mix woh.native.pending.codec.smoke`,
  `mix woh.native.pending.storage.smoke --paired-authoring` and
  `mix woh.native.pending.storage.smoke --generation` passed the owning older
  closed codecs, private CAS and restart/concurrent-publication cohorts.
- `mix woh.native.pending.paired.smoke` passed the existing independent paired
  roots, original joins, actual private publication/restart, twelve two-process
  races, local recovery refusal and pending-panel compilation/render fixture.
- `mix test test/macos_app_inventory_test.exs` passed two tests. Formatting,
  warnings-as-errors compilation, the 22-contract catalogue check, HTML ExDoc
  with warnings-as-errors and Git whitespace checks passed.

The first race check failed because its harness omitted the existing nonblocking
lock-capacity refusal; it was corrected to require exactly one success and one
bounded conflict/capacity refusal. The older codec check exposed a stale v8
unknown-version assertion, generation storage named newly supported v9 as unknown,
and the historical paired corpus still named v7 as unknown. Fixtures explicitly
accept retained v7–v9 and use v10 as the unsupported marker. The paired refusal
helper also reports its caller's line so a future failure identifies the actual
case. The focused final commands above passed after correction.

Logs: `/tmp/home-native-pending-{external,codec,storage,generation-storage,paired}.log`,
`/tmp/home-native-pending-external-tests.log`, `/tmp/home-moduledocs-html.log`.
Unchanged mix.lock SHA256:
`3372ef86b264343efeedea270b3a8d0548650898043aa0e360daba46c7aaf184`.
Unchanged Nerves lock SHA256:
`259fb7f414899924e12897dcb9c04ceff817c9e82d03f6254f82049a3a1b3663`.

## Remaining delivery

Fixed mutation/recovery with complete receipt correspondence, explicit absent
acknowledgement, current selected authorization and native confirmation/panels
remain successors. Target history still additionally needs enroll:review; this
representation does not widen paired grants. No installed signed success,
Keychain interaction, target storage power-loss or source/device qualification
was established. No full application suite, Dialyzer or packaged app build ran.
Physical dispatch remains disabled by default.
