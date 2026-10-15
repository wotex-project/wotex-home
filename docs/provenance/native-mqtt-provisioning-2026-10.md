# Native MQTT foreground publication and Setup software evidence

Executed 2026-10-15 on Apple Silicon macOS 27.0.1, Apple Swift 6.4,
Elixir 1.19.6 and OTP 28.5.0.6 from `.tool-versions`, with locked test
dependencies and `WOTEX_HOME_GIT_DEPS=1`.

The [owning contract](../specs/native-mqtt-setup-v1.md) and literal foreground
vectors were committed first in `a3f2021`. Foreground producer implementation:
`18f5d25`; signed native parent/service: `9aab3b5`; Setup composition:
`3fdb719`. The [earlier bootstrap evidence](native-mqtt-bootstrap-2026-10.md)
remains a separate executed milestone. This record supersedes its pending
foreground/UI work; positive installed custody remains open.

## Implemented boundary

The explicit local Setup panel prepares two private immutable documents through
the actual producer, reviews only digests/channel count/authentication mode,
requires source-scoped credential import for Keychain policy and explicitly
publishes the same original for the next Host start. It performs no load-time
work. Shared busy/session fences prevent concurrent actions; invalidated late
results cannot publish for another selection. Unknown publication preserves the
original and allows only explicit identical retry. Stopping a registered
background controller remains possible while that outcome is uncertain.

Production operations require the actual protected signed app gate. Its private
seal derives the bundled release and fixed foreground entry; inert drafts and
fixtures cannot mint that seal. The child starts dependencies without Home,
Store, socket, registration or broker connection. Preparation is read-only.
Publication holds the existing Host advisory gate, rechecks exact source/root
witnesses and publishes authoring before MQTT using immutable writers. A failed
second write can leave inert authoring policy; this is not an atomic pair.
Exact installed confirmation precedes reading vanished original inputs.

One original 15-second native deadline covers launch, bounded frames,
diagnostics and child exit/reap. Foreground replies buffered before normal exit
remain readable; ordinary Core lifetime checks retain their existing behavior.
Malformed or lost replies after possible publication remain uncertain.

## Executed checks

Mix commands used `MIX_ENV=test WOTEX_HOME_GIT_DEPS=1 mise exec --`:

- `mix test test/wotex_home/native_mqtt_provisioning_test.exs`: **9 tests,
  zero failures**. Frozen wire/representation cases, actual producer preparation,
  immutable publication and source-loss confirmation, changed inode/root,
  destination conflict, active Store refusal, unsafe mode/hardlink and injected
  third-sync failure followed by exact retry. Two fresh actual foreground entry
  processes also prepare/publish over their original pipes without SQLite or IPC.
- `mix test test/wotex_home/native_core_channel_test.exs test/wotex_home/native_mqtt_bootstrap_test.exs`:
  **19 tests, zero failures**, retaining existing Core/bootstrap behavior.
- `mix woh.native.mqtt.provision.smoke`: passed Swift 6 warnings-as-errors,
  independent literal vectors and private-file checks, actual unsigned production
  refusal, and a trusted fixture shim running the real producer over original
  pipes. Publication and confirmation after input deletion passed. Oversized,
  extra, dead, excessive-stderr and silent children fail closed; the silent case
  checks the original 15-second bound. Every actual child PID was reaped.
- `mix woh.native.core.pipe.smoke`: passed existing actual-Core receipt recovery,
  bootstrap/lifecycle and adversarial pipe checks after shared parent changes.
- `mix woh.native.mqtt.setup.smoke`: passed inert-draft refusal by live operations,
  explicit work, remote/busy guards, duplicate-click suppression, required import,
  invalidated late preparation, lost publication and original-only retry,
  including invalidation during publication. Prepared and uncertain panels were
  rendered and visually inspected at 620 by 760 points; labels and both digests
  fit, and uncertainty is visible without duplicate messages. Fixture operations
  do not simulate successful signed import.
- All **80 native app source files** passed Swift 6 typechecking with
  warnings-as-errors for `arm64-apple-macos15.0`. An earlier attempt detected a
  source file edited while compilation was running and exited unsuccessfully;
  the stable final source passed in 14.1 seconds. No bundle was assembled.
- `mix format --check-formatted`, `mix compile --warnings-as-errors`,
  `mix woh.spec.check` and `git diff --check` passed on the implementation
  worktree. The catalogue covered 22 working contracts including unrelated
  uncommitted research. An isolated staged export also passed all **21 staged
  contracts**, and **536 local Markdown targets** in staged changed documents
  exist. Unrelated research is excluded from these commits.

The documentation-only agent improved the foreground and shared entry headers.
Its patch passed AST equivalence excluding documentation, reference and exact
following-blank checks. Test/helper modules retain `@moduledoc false` followed
by one blank line. Runtime work was not delegated.

Neither dependency lock nor sibling source changed. The root lock remains
SHA-256 `3de9b75ee702ed6bd95f846b2681b071c1e8266cd2daa4615bf625f55741f913`;
Nerves lock remains
`05a334979d42c0717e7df1c0f85e1bb6529d9b370acb9f871fba3750c8afc34f`.

## Cleanup and remaining acceptance

Completed fixture tasks remove their own temporary directory, including native
compiler caches. The final app typecheck cache was removed after success. Old
Home compiler caches and a completed recovery fixture were removed, together
with the unused WoTEx Linux/Matter build images and their attributable reclaimable
layers: approximately **5.1 GB** total measured cleanup. Current small previews
and locked test dependencies remain. Other projects' or unattributed Docker
volumes were preserved. The post-cleanup filesystem reported **21 GiB free**;
that shared-machine snapshot is not an ongoing disk-space guarantee.

NM-01 through NM-05 have the software implementation above. Real protected
Developer ID app/agent artifacts, positive Keychain add/read/reread, locked,
denied, missing and conflicting items, account isolation, fresh-account
registration and installed lifecycle remain unexecuted. No full suite,
Dialyzer, new release/app/firmware artifact, board or physical device
qualification ran. Source authenticity, sample age, target reselection and
default-disabled physical dispatch retain their separate obligations.
