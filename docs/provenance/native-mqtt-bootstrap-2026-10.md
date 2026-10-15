# Native MQTT bootstrap software evidence

Executed 2026-10-15 on Apple Silicon macOS 27.0.1, Apple Swift 6.4, using
`.tool-versions` Elixir 1.19.6 and OTP 28.5.0.6 with the locked test cache and
`WOTEX_HOME_GIT_DEPS=1`.
Core source: `7aacb32`; native source: `3922d0ddc219f75840af457c5f58e7c26a580371`.
This record captures the bootstrap milestone. Its pending foreground/UI work
was subsequently implemented with
[separate publication and Setup evidence](native-mqtt-provisioning-2026-10.md).
Positive installed custody remains open; the remaining-work text below records
the obligations at this bootstrap milestone.

## Implemented boundary

The installed agent's existing fixed, protected release child now exchanges one
initial source-scoped credential request/reply before Store startup. Keychain
mode requires verified TLS and the exact sealed source digest/file witness.
The child retains the decoded pair in a redacted linked owner for one resolution
or at most 30 seconds. Checks do not consume it. Ordinary startup without that
capability refuses before Store/socket acquisition; none/password modes retain
their existing custody. No credential file is created by native bootstrap.

The Swift custodian implements actual-self/protected-bundle gates, a dedicated
exact access group, fixed service and raw-source-digest account. App import is
add-only with exact reread; agent access is read-only. Both roles retain their
existing distinct operator-custody group. Each SecItem operation rechecks its
actual access seal before/after; no fixture can construct a successful seal.
Neither automatic source publication nor a Setup button is implemented here.

## Executed checks

All Mix commands used `MIX_ENV=test WOTEX_HOME_GIT_DEPS=1 mise exec --`:

- `mix test test/wotex_home/native_mqtt_bootstrap_test.exs test/wotex_home/private_mqtt_installation_test.exs test/wotex_home/native_core_channel_test.exs`:
  **36 tests, zero failures**. Literal frozen wire vectors, canonical/bounded
  parsing, maximum binary password/UTF-8 username, wrong reference/hash/seal,
  consumed/expired/parent-lost custody, redacted status and blocked request-write
  timeout are covered. Expiry refusal uses an injected elapsed owner deadline;
  it does not claim a 30-second wall-clock soak.
- The same run executes an actual Core/Host/SQLite/TLS broker behind controlled
  parent pipes. The broker receives the supplied fixture pair only through TLS;
  the source digest is requested before SQLite exists. Parent EOF closes the
  Host and releases its advisory gate; no credential document is persisted.
  Changed raw source and expired capability refuse before Store. A Store-child
  restart cannot reuse the consumed capability or reconnect.
- After tightening the shared monotonic exchange deadline, the affected
  `native_mqtt_bootstrap_test.exs` rerun passed **8 tests, zero failures**,
  including a blocked request write. The native actual-Core check below also
  passed against that freshly compiled code.
- `mix woh.native.core.pipe.smoke`: passed Swift 6 warnings-as-errors compilation,
  actual Core original-receipt recovery including a real `none` bootstrap on
  restart, and scripted none/credential/malformed/oversized/denied/timeout/slow
  custody cases. The original five-second bound includes slow custody; expiry
  closes/reaps the original child and drops late results. Ordinary request/reply
  and bootstrap request ceilings remain 4096; only the one initial reply admits
  8192 bytes. Actual native-parent SIGTERM/SIGKILL cleanup also passed.
- `mix woh.native.keychain.policy.smoke`: passed Swift 6 warnings-as-errors,
  independent canonical credential/bootstrap vectors, maximum password/username,
  inert service/account/query/group/error policy, duplicate/noncanonical input
  refusals and wrapper redaction. Actual unsigned lookup/import fail in the
  self-signing gate before SecItem; no positive Keychain operation was executed.
- `mix woh.native.broker.socket.smoke`: passed existing socket ownership and
  actual unsigned refusal with the new installed broker composition compiled.
- `mix woh.native.setup.peer.smoke`: passed existing closed signing policy,
  kernel peer capture and actual unsigned refusal after the dedicated group
  extension.
- `mix format --check-formatted`, `mix compile --warnings-as-errors`,
  `mix woh.spec.check` and `git diff --check`: passed on the implementation
  worktree. Catalogue checks covered 22 working contracts, including unrelated
  local research. An isolated index export also passed all **21 staged
  contracts**; **512 local Markdown targets** across staged documentation exist.
  Unrelated research changes were excluded from these commits.

The native lifecycle fixture originally failed while Python reopened the stopped
fixture database read-only. An isolated actual-Core probe reproduced this after
parent loss: this SQLite build refuses that read-only open and succeeds through
ordinary WAL recovery. The fixture now waits for the original Core PID to exit
and opens the existing database with `mode=rw`, which cannot create a missing
replacement. It verifies the unchanged empty principal table after recovery.
This changes verification, not Store's durability or recovery implementation.

The documentation-only agent improved seven affected module/task headers.
Its proposals passed AST equivalence excluding documentation, reference,
formatting and exact following-blank checks. Test/helper modules retain
`@moduledoc false` followed by one blank line. No runtime behavior was delegated.

Root lock SHA-256:
`3de9b75ee702ed6bd95f846b2681b071c1e8266cd2daa4615bf625f55741f913`.
Nerves lock SHA-256:
`05a334979d42c0717e7df1c0f85e1bb6529d9b370acb9f871fba3750c8afc34f`.
Neither lock nor a sibling repository changed for this consumer mechanism.

## Remaining acceptance

NM-04 still needs the fixed foreground bundled-producer entry, stopped-host
publication guard, source preparation/import/publication state machine, native
file panels and rendered/inspected local Setup UI. Its bounded uncertain-retry
and session/busy fences remain requirements, not implemented claims.

Actual signed protected app/agent artifacts with both exact access groups,
positive add/read/reread, missing/locked/denied/conflicting items, source-account
isolation, fresh-account registration and installed lifecycle remain unexecuted.
No new release/app/firmware artifact, full suite, Dialyzer, board or physical
device qualification was run. MQTT remains observation-only; source authenticity,
sample age, target reselection and default-disabled physical dispatch retain
their independent obligations.
