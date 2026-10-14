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
That initial adapter introduced no target, observation or control route.

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
current observation adoption remain separately required. Existing host
reader configuration is trusted and default-unavailable; callers cannot install
one. All commits remain local on main and dependency pins are unchanged.

## Durable target operator successor

On 2026-10-14, the target operator extension was specified in `e6b1d77` and
implemented in `d04624b`, consuming the [schema 34 target owner](external-target-selections-2026-10.md).
`external_target_change` and `external_target_status`, with CLI commands
`external-target-change` and `external-target-status`, forward the same original
and receipt through Authority. They add no source publication, grants or report/
control route. Current status of a selection remains distinct from original lookup.

The focused operator, existing local route and CLI files passed 18 cases in
1.7 seconds. Those include target original-file modes, extra/duplicate/oversized
input, numeric/ID status bounds, closed wrappers, current permissions, missing
originals, expired dispatch and an actual stopped Store. A real peer reads and
discards the target mutation frame; CLI exits 3, names the exact target status
original and never prints the bearer or sends another ID.

The exact existing three-archive `--profile-target-store-consumer` passed 64
isolated profile cases in 11.2 seconds and 22 real Store cases in 11.0 seconds.
Its updated fixture SHA-256 is
`ee6d4e694bcecbd9fa98b68dd24d04f1a4c7e2c0a95c04560e8adb37f664e4cd`.
Temperature, unfamiliar density and multi-channel sources each perform a fresh
selection through the real private socket, compare Authority's exact original,
recover the same receipt through CLI change/status without a new revision, then
revoke through a restarted private server after Store restart without a source
owner. Source/private documents are absent from responses. The other owning
transaction, source-race, corruption and recovery cases remain green in that run.

Format, warnings-as-errors compilation, catalogue and whitespace checks passed.
No socket exclusion, full application suite, native packaging, Dialyzer or
physical qualification is claimed. Producer archive and consumer-lock identities
remain the same as the linked target evidence; application pins were not changed.

## Guarded reported-value read successor

On 2026-10-14, the read adapter contract was committed in `b1f3947`. The private
`external_report_current` and `external_report_status` routes and CLI commands
forward the owning identifiers through Authority to the schema 35 Store. No
report-body, timestamp, source-publication or admission route was added. Read
timeouts and lost replies remain ordinary read errors rather than mutation
uncertainty.

The focused external operator, CLI and local route files passed 22 cases in
2.0 seconds. Exchange and same-user peer identity files passed five cases in
1.2 seconds. New cases cover exact report-owner identity, lowercase hex and ID
bounds, field rejection, permission denial before missing-original lookup,
missing-original CLI exit 4, expired dispatch, stopped Store, and actual peers
that read a complete frame then discard the reply. Both read commands exit 1
without mutation recovery instructions or bearer disclosure on lost replies.

The same three-archive `--profile-target-store-consumer` command recorded in
[observation evidence](external-observations-2026-10.md) passed 81 isolated
profile cases in 10.4 seconds and 39 actual Store cases in 14.6 seconds. Consumer
lock and producer archive hashes are unchanged. Updated Store fixture SHA-256:
`0c90f72d3ed3ba9e3af3f99c4023c9900d1650bbd3569976f3f50926c01e19db`.
Temperature, unfamiliar density and multi-channel fixtures each use the real
private socket and CLI for a fresh preview and exact immutable receipt. Their
coordinates match the independent observation vectors; age only advances,
remaining freshness only decreases, management credentials cannot substitute
for read grants, and no read adds a Store revision. After Store/server restart
without source/report owners, original status remains identical while preview
is null with external_selection_restart_required.

Format, warnings-as-errors compilation, the 22-contract catalogue and Git
whitespace checks passed. Real sockets ran without exclusions. No full
application suite, Dialyzer, native packaging, installed-host adoption or
physical qualification is claimed. Native presentation and actual host source/
meaning installation remain separate delivery work.
