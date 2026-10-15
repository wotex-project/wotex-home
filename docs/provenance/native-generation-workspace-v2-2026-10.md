# Paired generation workspace dependency evidence

Recorded: 2026-10-15. Owner: [v2 workspace](../specs/native-generation-workspace-v2.md).
Accepted contract: b7e5668. Independent vectors preceded code in c04cf6e.
Runtime: be042cb665471730f6dd0728753df27b53ea5931 on local main.
No Store schema, dependency or sibling API changed.

## Implemented custody

v2 uses the existing fixed workspace file/lock and private descriptor/content/
revision/inode CAS. Paired custody stores only association/controller/creation/
verifier references and exact context; every original/epoch/creation/attempt/link/
budget/basis check remains enforced. v1 markers refuse paired entries. First
paired retain upgrades once and preserves existing roots. Append, intent change,
archive, empty and later local publication retain v2; no-op/load preserves bytes
and version. Unknown/corrupt/unsafe or stale state refuses without reset.

The entry accessor now validates paired metadata for v2. Therefore the local
driver adds explicit paired refusal before capture to status, attempt preparation,
cancellation, pending restoration, generated assessment and submission with a
paired predecessor. Local workspace selection excludes paired entries. This
preserves consumer separation while actual signed category composition is absent.

## Independent vectors and actual checks

`test/support/native_generation_workspace_v2_oracle.py` allocates50 valid and241
invalid roots from frozen v1 originals without Home/BEAM/Swift. Cases include both
families, complete attempt/repair chains, Unicode, intent, exact creation floor,
maximum S64, mixed local/paired roots and empty retained v2. Refusals include v1
paired markers, wrong principal/epoch/creation/scalar/custody/intent and same-scope
other-principal duplicates. Fixture SHA256:
f5b4c1e1a91a0b8f59f3ec0066fab0c2161b432c43bae07cfdf13c85f7e6c75e.

`mise exec -- mix woh.native.generation.workspace.smoke` passed v1 and v2 exact
bytes/hash/metadata/reflection and malformed cases, actual private first retain,
no-op, ordered append, intent, exact archive, capacity, unsafe files and stale
same-content inode replacement. v1 local root load/no-op stayed byte-identical;
paired retain advanced revision and chose v2 while preserving that root. Removing
paired/local roots and publishing local again retained v2.

Eight pairs of independent processes raced root publication, competing append,
intent versus append and archive versus intent, once per version. Each had one
winner and one refusal; a fresh process read the winning bytes. Separate seed/load
processes checked restart without any credential, API or model work.

`mise exec -- mix woh.native.generation.flow.smoke` passed existing six both-family
Store/native cohorts plus explicit local-consumer paired refusal. The refusal
fixture had selected local metadata matching the live context, an available empty
pending coordinator, and a valid paired entry with an existing attempt and no
cancellation intent. All six local entry points returned unavailable before a
capture callback that would fail the test if called. No workspace/pending write
followed. Existing publication failures, original reconciliation, repair, assessment,
cancellation, expiry, authority retirement and Store/native restart still passed.

Formatting, warnings-as-errors compile, catalogue (22 contracts), HTML ExDoc with
warnings-as-errors and Git whitespace checks passed. Toolchain: Elixir1.19.6 /
OTP28.5.0.6; Swift6.4 on arm64 macOS27, Swift6 language mode targeting arm64 macOS15.
Logs: /tmp/home-native-generation-workspace-v2.log,
/tmp/home-native-generation-workspace-v2-flow.log and
/tmp/home-native-generation-workspace-v2-docs.log.

NGW2-T1/T2 have focused representation/private-process evidence. v2 custody creates
no actual signed session. Paired manual/generation consumers and installed signed
publication/interaction, live-model, power-loss and physical qualification remain
separate. No push, visibility change, release, firmware or installed app occurred.
