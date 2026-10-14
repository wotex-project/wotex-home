# Native installed authoring contract read evidence

Recorded: 2026-10-14. Runtime source: bdcfb61 on main.
Owner: [native contract successor](../specs/native-authoring-contract-v1.md),
WOH.08/15 selected-client delivery and WOH.18 manual authoring basis.

The existing NativeAuthoringReadClient source now contains the bounded contract
client and immutable Sendable contract/limit/producer values. Reflection omits
document bytes; explicit native access preserves exact raw bytes. The selected
driver reads under shared busy/association guards, local capture or sealed
paired session, before/after authority/principal/epoch and nonregressing export
watermarks. It creates no pending original or file. The paired branch delegates
the existing lease/current/delivery guards; the new export was not independently
exercised through installed paired TLS in this slice.

The first fixture found that a real public contract reaches depth 18. The
ordinary 16-container scanner was therefore insufficient. The spec was amended
before code to give only the decoded contract scan explicit 32-container,
50000-node, 4096-member and 16384-byte string/key limits, matching the inspected
producer envelope. Ordinary response defaults remain depth 16/members 256.
This does not implement or relax a producer schema validator.

## Independent bytes and executed checks

Toolchain: Elixir 1.19.6 / OTP 28.5.0.6 and Apple Swift 6.4
(swiftlang-6.4.0.34.1 clang-2100.3.34.1), Swift 6 mode, arm64 macOS 15 target.
Mix checks used WOTEX_HOME_GIT_DEPS=1 MIX_ENV=test.

test/fixtures/profiles/authoring-contract-exports.json retains two 52222-byte
grammar documents. Its raw file SHA-256 is
ff98a680e6fcc2c371ddc80170d96a6f5e0441dbb36a0cf3c6c681660f6e4997.
Each document's raw/domain hashes and complete Home basis were checked against
the previously frozen authoring-mechanics vectors before fixture publication.
A separate Python hashlib pass confirmed both raw and prefixed WPF identities;
the fixture is not regenerated during native tests.

- mix woh.native.authoring.contract.smoke: 40 independent private peer cases
  passed. Both document families and archive/runtime producer shapes succeed;
  malformed wrapper/body/Base64/UTF-8/duplicates/types/hash/limits/producer,
  oversized collections, decoded depth, nodes, strings and keys refuse. Changed
  document cases carry matching recalculated raw/domain hashes, so decoding
  guards are exercised independently of checksum mismatch. Refusal and lost
  transport cases retain typed read behavior.
- mix woh.native.authoring.read.smoke: 272 existing typed peer cases and 22
  selected local-session cases passed. Twelve new contract cases cover current
  success, owner/principal/epoch succession, watermark regression, future/old
  export revision, mismatched actor/epoch, permission refusal, transport loss and
  cancellation before delayed delivery. Busy state clears and late data is
  discarded. No credential or source bytes enter fixture diagnostics.
- mix test test/wotex_home/native_authoring_contract_test.exs: one test containing
  both actual locked producer/SQLite/private-socket families passed in 18.4
  seconds, including fresh Swift compilation. Exact bytes, raw/domain/basis
  identities, principal/epoch/revision and runtime producer revision match the
  Store oracle; Store revision remains one. Credential contents stay in private
  fixture files; command arguments contain only paths.
- Formatting, warnings-as-errors Home compilation, catalogue (22 contracts)
  and git diff --check passed. Native compilation rejects warnings.

Logs: /tmp/home-native-authoring-contract-peer.log,
/tmp/home-native-authoring-contract-session.log and
/tmp/home-native-authoring-contract-live.log. These are local executed checks,
not installed app artifacts. No complete bundle, signing, actual paired export,
private configuration delivery, physical device, protocol qualification or
manual draft UI was established. Existing catalogue contracts remain partial
and keep missing installed/physical evidence. No remote ref was pushed.
