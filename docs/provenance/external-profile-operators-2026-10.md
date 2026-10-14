# External inspection and trust operator software evidence

The [operator contract](../specs/external-profile-operators-v1.md) was committed
in `29c60e1`, its initial independent adapter cases in `602130a`, and the socket/
CLI implementation and completed cases in `1e4dc7f`. It consumes the existing
[inspection](external-inspection-store-2026-10.md) and
[trust](external-trust-2026-10.md) transitions without another authority/store.

On 2026-10-14, Elixir 1.19.6 / OTP 28.5.0.6 executed:

- `mise exec -- mix test` selecting external_profile_operator_test,
  local_api_exchange_test and cli_test: 15 cases passed in 1.6 seconds.
- Existing local API route and same-user peer identity suites: six cases passed;
  portable_profile_api_test: four v1 cases passed. Actual sockets ran without
  socket exclusions. Format, warnings-as-errors compilation, the working
  22-contract catalogue and Git whitespace checks passed.
- The exact three-archive `--profile-store-consumer` command recorded in
  [trust evidence](external-trust-2026-10.md) passed 35 pure and 69 actual Store
  cases, the latter in 87.1 seconds. Archive and consumer-lock identities are
  unchanged. No full application/native suite, Dialyzer, packaging, installed
  host or physical qualification was run.

Actual Store fixture source SHA-256 is
bbf2f8146330bcb5f20f90b760623114d0108c9b7b62d140c14992e8b35a68cd.
Focused operator source SHA-256 is
944fa3d2cfa3b784772468ef8c2b4267c5964a7c98efcf8ce488e815798f4e30.

Both independent quantities import their actor-owned frames, then use the real
private socket and CLI for inspection, approval, revoke, current catalogue and
original status. Returned receipts equal direct Authority originals and frozen
envelope/artifact identities. Discarding a committed revoke response and reading
its scoped status preserves the original revision; exact retry does not create
another decision. Current revoked catalogue and historical approval are distinct.
The adapter does not introduce any target, observation or control route.

Two real same-user scripted peers consume a complete mutation frame and close
without replying. CLI returns exit 3 with the correct original epoch/operation
status command and no bearer in diagnostics. Expired Exchange budgets and actual
Store-call failures classify both mutations as outcome_unknown; read failures
remain read errors. Existing Exchange cases cover guarded worker teardown after
caller loss/deadline with a suspended Store. No forced assertion of physical or
transaction rollback is made after uncertain transport outcomes.

Strict original-file cases reject wrong modes, extra fields, duplicate JSON
members and byte excess. Status rejects zero, overflow, trailing characters and
malformed IDs. Framed wrappers reject extra fields and retain current permission
and owned-handle guards. Empty current catalogue and missing-original CLI exits
are exercised through actual sockets. Initial fixture corrections replaced an
absent-path pre-send refusal with a real dropped-reply peer and preserved the
Store's ownership check before optional reader selection.

This is the inspection/trust adapter slice for already imported objects. Typed
byte-upload, source/candidate/review client flows, native v2 presentation and
current target/observation adoption remain separately required. Existing host
reader configuration is trusted and default-unavailable; callers cannot install
one. All commits remain local on main and dependency pins are unchanged.
