# Native generation workspace custody evidence

Recorded: 2026-10-15. Contract:
[native generation first decisions](../specs/native-generation-ui-v1.md).
Runtime: b072310ff3159ca74f193358a16aa3428752efd2 on local main.
The complete first-decision contract and 24 independent workspace roots preceded
code in 78d1985. This record establishes its custody dependency, not the full UI.

NativeGenerationWorkspace retains complete immutable root/attempt inputs, original
context/custody/basis metadata and local cancellation intent. It checks exact
canonical links, ordered explicit repair and selected attempt budget. The existing
private-document owner publishes its separate fixed file/lock with descriptor,
content, revision and inode CAS. Existing network/pending/association kinds retain
their names and limits. Load has no API/capture/model port. The workspace does not
store a receipt, current permission, timer or result, and cannot authorize export.

Frozen test/fixtures/profiles/native-generation-workspace.json raw SHA-256:
bee6472673bba59c208894e3fc30ea5288bc8f134b3572f01801b0ee086b3b1b.
Python allocated roots/links/order/hashes from frozen preparation originals,
including both families, Unicode, maximum S64, zero through three explicit attempts
and cancellation intent, without Home/BEAM/Swift invocation.

`mise exec -- mix woh.native.generation.workspace.smoke` passed independent byte/
hash/metadata correspondence, malformed canonical/scalar/context/order cases,
private publication, exact no-op, ordered append and intent, stale snapshot,
same-content inode replacement, exact archive/versioned empty file, sixteen-entry
capacity, unsafe mode/hardlink/symlink, and a separate-process restart/load.
Four pairs of independent processes raced first root, competing append, intent
versus append, and archive versus intent. Each pair produced exactly one commit
and one refusal; subsequent process load preserved the winning document.

The scanner bounds outer bytes to2097152, depth four, nodes1024, arrays16 and
path-specific decoded strings before creating a typed tree. It permits UTF-8 and
quote/backslash escaping only in the original slots; ordinary identity strings
remain128-byte ASCII. A native role/basis/root replacement cannot overwrite a
retained entry; removing one requires exact latest entry and whole-file CAS.
Reflection hides original instruction/handle contents.

Formatting, warnings-as-errors Elixir/Swift compilation, catalogue checking
(22 contracts), full HTML ExDoc with warnings-as-errors and Git whitespace checks
passed. Toolchain: mise Elixir1.19.6 / OTP28.5.0.6, Swift6 arm64 macOS15 target.
Logs: /tmp/home-native-generation-workspace.log and
/tmp/home-native-generation-workspace-docs.log.
The fixture corrected Foundation's serialization of native1.0 as integer1 by
supplying literal1.0 bytes, and accepted the owning unavailable error for unsafe
file refusals. Neither correction widened the workspace codec or private guards.

The app compiler list and macOS CI register this dependency. No installed app,
release, firmware or hosted green run was produced; nothing was pushed. No schema,
dependency or sibling API changed. Signed custody/disk power-loss and physical
qualification remain separate. NGU-T1/T2 have focused software evidence; guarded
driver decisions, publication ordering across workspace/pending/Store, cancellation
reconciliation, first panel and generated manual review composition remain NGU-T3–T5
work. Unrelated drafts and client settings were preserved.
