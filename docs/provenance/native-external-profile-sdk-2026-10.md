# Native external-profile delivery and recovery evidence

Recorded: 2026-10-15. Owner: [fixed SDK](../specs/native-external-profile-sdk-v1.md)
NXS-01–04 and NXS-T1/T2/T3. Requirements preceded runtime in 17f2603;
independent receipts were frozen in 4ccbdd9 and expanded in dbc4d98. Runtime:
9b35443 on local main. No Store schema, producer API, dependency, paired permission
allowlist or dispatch flag changed.

## Implemented boundary

The fixed client checks a complete immutable original and expected controller
identity before I/O, reads authenticated identity and original status first,
and sends at most one fixed mutation only after exact missing status. A found
receipt resolves lookup/retry without a mutation. A missing old-epoch original
cannot become a new request. Final identity must retain authority/principal and
cover both the initial watermark and verified receipt revision.

Inspection, trust and target replies use the existing strict typed decoders.
Complete input SHA/header/revision correspondence and every input-derived reader,
action, artifact, policy, previous revision, resource, target and selection-source
join are checked. Signed arithmetic refuses overflow. Result/capture/envelope and
outcome identities that cannot be reconstructed from the original remain opaque;
the client does not compare a raw-document hash with a complete object-frame hash.

Once mutation is possible, lost/malformed/mismatching replies and final identity
failure are outcomeUnknown. Bounded owning mutation refusals stay definite; their
error reason grammar is closed and payload-free. Review found that a bounded
authentication error from the final identity read also needs unknown classification.
The client now distinguishes that phase from a definite mutation refusal, with
explicit unauthorized/permission_denied final-read regression cases.

Ordinary local pending capture publishes the complete original under v9 before
send. Local recovery uses only existing recorded custody and exact context, then
the fixed client. Lookup/retry retains missing results; separately confirmed absent
acknowledgement performs only lookup and resolves client metadata with explicit
late-arrival/no-operation text. Paired actions remain disabled before custody or
transport until their actual signed consumer exists. Startup/display sends nothing.

## Executed checks

Pinned Elixir 1.19.6 / OTP 28.5.0.6 through mise; Swift 6.4 in Swift 6 mode,
warnings-as-errors and arm64 macOS 15 target on the macOS 27 development host.

- `python3 test/support/native_external_profile_sdk_oracle.py` reproduced 34
  accepted and 142 refused cases: 176 total. It imports no Home, BEAM or Swift;
  inputs/receipts come from the already frozen two-family/multichannel owners.
  It independently changes and rehashes original actions/counters, tests S64
  maxima and preserves intentionally opaque output identities. Corpus SHA256:
  `2ceead7a8c55d452fb9d5924d4542c8d7d92c025ec693a8adb8ac6b6646e16e3`.
- `mix woh.native.external.mutation.smoke` passed all 176 correspondence cases
  and 172 actual framed socket cases. They check exact complete wrappers,
  status-first found/missing/retry sequences, all kinds/actions, opaque hashes,
  old-epoch found/missing behavior, receipt watermark coverage, identity changes,
  malformed/bounded errors, lost mutation replies and final authentication loss.
  The peer requires the exact request sequence; a mutation after found status or
  an automatic replay after loss fails the fixture.
- `mix woh.native.external.mutation.smoke --live` passed both temperature and
  unfamiliar-density Store cohorts. Each imports actual typed byte objects and
  uses the real Authority/SQLite/private Unix socket. Inspection, trust approval
  and target selection each lose a successful commit reply through a proxy that
  verifies the exact five-request sequence before dropping the mutation reply.
  A separate native process reloads retained input and recovers the original.
  Trust also starts as an unsent durable original and survives missing lookup.
- Live target retry confirms its original after the actual source/report publishers
  stop. Metadata-only target and trust revocations then succeed, preserving target
  binding and advancing its resource once. Missing lookup/explicit acknowledgement,
  stale CAS refusal, a different credential and original-principal revocation
  preserve the expected Store revision and pending identity. Failed actual file
  publication retains the unsent original in coordinator memory, marks reload
  required and performs no mutation; it does not claim durable publication succeeded.
- `mix woh.native.pending.external.smoke` passed the unchanged 182 accepted/276
  refused v9 roots, every earlier-root upgrade, private CAS, restart/races and the
  updated local/paired action matrix. Existing-only local custody failures retain
  metadata; paired actions still call no custody, runner, socket-path or clock owner.
- `mix woh.native.pending.paired.smoke` passed the existing independent paired
  roots, original joins, private CAS/restart, twelve process races, ordinary local
  recovery refusal and pending-panel compilation/render fixture.
- `mix test test/macos_app_inventory_test.exs` passed two tests. The app's explicit
  source list includes the new client. Formatting, warnings-as-errors compilation,
  the 22-contract catalogue check, HTML ExDoc with warnings-as-errors and Git
  whitespace checks passed. No full application suite or Dialyzer ran.

Logs: `/tmp/home-native-external-sdk-{peer,live,pending,paired,tests,docs}.log`.
Unchanged mix.lock SHA256:
`3372ef86b264343efeedea270b3a8d0548650898043aa0e360daba46c7aaf184`.
Unchanged Nerves lock SHA256:
`259fb7f414899924e12897dcb9c04ceff817c9e82d03f6254f82049a3a1b3663`.

## Remaining delivery

Selected first preparation/confirmation and panel workflows, signed paired
consumers, installed Keychain/signing and physical/source qualification remain.
The configured reader and source publishers here are synthetic software fixtures;
they do not qualify a protocol publisher, device, target storage power-loss or an
installed native operator account. SDK expected identity is a comparison basis,
not an injectable signing seal. Physical dispatch remains disabled by default.
