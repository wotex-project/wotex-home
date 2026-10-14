# Explicit profile runtime and host custody evidence

Recorded: 2026-10-14. Owner: [installed runtime successor](../specs/installed-profile-runtime-v1.md),
WOH.18 profile/authoring and WOH.08/16 host/runtime boundaries.
Runtime commit: f15b1073fad02a0fa842f50759187b38f8e0429a. All work is on main;
no ref was pushed.

## Actual implemented boundary

The shared ProducerIdentity keeps exact three-field archive assertions and
their three-element wire values. The distinct runtime identity records the
locked WoTEx source revision and real per-application compiled inventories in
five named fields/five ordered strings. Current construction compares fresh
loaded/file code; historical decoding validates only the closed retained shape.
Path-selected Home compilation refuses to assert the pinned source revision.

Trusted Host startup validates explicit binding/meaning/capture/limit and live
publisher inputs before private resources. Store receives the checked reader,
authoring contract/capture and fixed owner names. A permanent Host subtree owns
temporary SourceOwner/ReportOwner children after Store/custody ownership and
before consumers. Store restart replaces the subtree with empty custody and
fresh source/report epochs. Publisher loss retires both owners without
automatically reinstalling or republishing them. No default profile, endpoint,
transport, grant, approval, clock confidence or device dispatch is created.

## Executed checks

Toolchain: Elixir 1.19.6 / OTP 28.5.0.6; arm64 macOS. The native fixture used
Apple Swift 6.4 in Swift 6 mode targeting arm64 macOS 15. All ordinary Mix
commands used WOTEX_HOME_GIT_DEPS=1 and MIX_ENV=test.

- 43 focused actual locked consumer/Host/Store/retained semantics/inspection/
  target/recovery/review cases passed in 3.1 seconds. Existing independent
  archive originals retained their exact bytes; new runtime ordered identities,
  mixed/unknown/revision/digest refusal, changed current inventory assertion,
  producer-free history and pre-resource configuration refusal were exercised.
- The final strengthened real-socket Host case passed in 2.0 seconds. It creates
  a compatible candidate from independent draft bytes, retains its original
  after Store restart, publishes an explicit source and a pending transport
  receipt, denies non-Store receipt checkout, then confirms fresh empty source/
  report custody and changed epochs after restart. Killing the publisher retires
  both temporary owners while Store history/revision remains available.
- Fresh Home-only subprocess: four producer-absence/historical cases passed,
  with the producer code path absent. This preserves absence coverage after
  ordinary application adoption; malformed native values remain refused with
  installed producers.
- Native external-report fixture: 71 private socket cases and six selected-session
  cases passed. Both exact producer identity shapes are admitted in generic
  catalogue declarations; extra fields, invalid revision and invalid digest
  refuse even when declaration hashes match supplied changed bytes.
- Fresh restricted three-archive consumer: 81 cases, zero failures, in 12.5
  seconds. Freshly compiled 40 Home components include ProducerIdentity and
  RuntimeArtifacts. Archive raw SHA assertions were independently checked before
  extraction; consumer lock SHA remains
  6ddb05e87f2872a12a244a022d666372d792510c8760188a3ac235ce53c258dd.
  This isolated lock is distinct from the ordinary Home lock.
- Formatting, warnings-as-errors Home compilation, 22-contract catalogue and
  git diff --check passed. A socket/upload cleanup race found during Store-loss
  testing was fixed separately in 198595a; its 14 focused operator/Host cases
  passed, including endpoint removal after owned upload retirement.

The archives are /tmp/home-profile-wotex.tar (SHA
77c742b0b76c3d4d9d4c9d5e5b47e65755a351021de1ddba73369647b96fee61),
/tmp/home-profile-wotex-runtime.tar (SHA
7c5412ea01dab311357a09276030ca005470c9bd8b0f471e0da3fb8ec5e4b1b4) and
/tmp/home-profile-wotex-profiles.tar (SHA
34a3dcef363a0b072fa2b260efeff8633f8365fd4aecfd1fbbc2c268c82e0b96).
Focused logs are /tmp/home-profile-runtime-integration.log,
/tmp/home-profile-host-full.log, /tmp/home-profile-runtime-native.log and
/tmp/home-profile-runtime-archive.log. These temporary artifacts are local
executed evidence, not tracked release payloads or physical identities.

No full release/native bundle/signing, installed service configuration loader,
protocol publisher, board or physical source qualification was performed.
Broader runtime qualification still binds native/transitive dependency closure;
the three per-producer inventories do not replace it. Existing catalogue
contracts remain partial with missing installed/physical evidence.
