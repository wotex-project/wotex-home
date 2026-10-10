# Authenticated controller session scope v1

Version: 0.1.1. Owner: WOH.08 H08-09/H08-T9, WOH.15 H15-07/H15-T8. Status: authenticated read and typed native SDK implemented; local Core/UDS/TLS/native evidence below, actual signed session composition pending.

Native remote selection needs current authorization from the selected owner.
The [public association](native-controller-associations-v1.md) retains historical
approved access, while the existing `controller_identity` read intentionally
exposes only current ownership and the caller's principal. Neither public
metadata nor successful Keychain custody supplies live grants.

## One owned read

Add `Authority.controller_scope` backed by one synchronous read on the single
Store owner. Authenticate the exact 32-byte credential using the existing
registry/access boundary, including native/paired principal integrity. Validate
active ownership through the existing controller history gate. Return only the
authenticated principal's existing permission vocabulary and bounded assigned
target IDs, together with deployment, owner, positive epoch and Store revision.
Permission and target arrays are sorted, unique and bounded to ten and thirty-two
entries respectively. Permission order in existing durable rows is unchanged.
Target IDs are authorization assignments, not active/qualified device claims.
Every later use case still authenticates its current grants and resource guards.

Any authenticated role may inspect its own scope without gaining `read`, target
access, maintenance or transfer authority. No principal selector, caller identity,
requested role, grant edit, credential provisioning or bearer/verifier field is
accepted or returned. Unknown/revoked credentials, corrupt principal/grant rows
and retired ownership fail closed. The read changes no schema, revision,
principal, journal, history, maintenance state or execution clock.

## Closed wire and native value

The ordinary request is exactly `{api_version,operation,credential}` with integer
version `1` and operation `controller_scope`. UDS and the explicit paired TLS
listener consume the same Authority route and ordinary request budget. The
successful envelope is exactly `{api_version,outcome,controller_scope}`. Its
inner object is exactly:

```
{format,deployment_id,owner_id,authority_epoch,store_revision,principal_id,permissions,target_ids}
```

`format` is `wotex-home.controller-scope.v1`. Identity fields use the existing
identity-read grammar. The closed permission vocabulary is shared with durable
storage; a transfer permission is exclusive and has zero targets. Arrays refuse
unknown members, duplicates, unsorted content and excessive bounds. Integers
refuse booleans and floating-point representations. Existing identity requests
and responses remain unchanged.

The shared native SDK returns a typed public value containing identity and live
permission/target arrays. It works through both the existing UDS path and the
[operation-scoped TLS adapter](native-controller-domain-sdk-v1.md), retaining
strict decoding and no local fallback. This value describes one authenticated
read, not a signed Keychain/selection seal, perpetual authorization, execution
clock or physical qualification. A decoded fixture cannot manufacture a live
session; the production session factory must itself perform actual signed
custody, selected association CAS, trusted certificate-clock and pinned TLS
checks before accepting the matching owner/principal response.

The ordinary CLI command `controller-scope` uses the same exact request through
its existing private credential-file/socket custody. It accepts no principal,
role or grant arguments and cannot provision access.

## Evidence and remaining composition

Check zero-target diagnostic/maintenance/transfer roles, ordinary scoped and
actual paired principals, sorted projection without durable rewriting, exact
framed fields, malformed/unknown/revoked keys, corrupted principal/grant rows,
retired ownership, restart and foreign owner refusal. Assert unchanged revision,
complete table/journal counts and original identity behavior. Independent native
peers must reject malformed identity/permission/target fields; actual UDS/TLS
reads must agree through the shared typed SDK with dispatch disabled.

Actual signed session/selection seals, exchange-time custody/selection checks,
stale UI completion, original paired journal capture/recovery and shared
window/menu-bar integration remain required successors. Scope load is explicit;
loading public metadata starts no network, Keychain or local fallback owner.

## Implementation and development evidence

`ControllerWriter.authenticated_scope` executes only on the Store owner's read
path. It reuses credential hashing, active-principal/native/paired integrity,
full ownership history and bounded own-grant reads. Sorted projection does not
rewrite the original permission document. Authority, the closed ordinary route,
CLI and `LocalHealthClient.fetchControllerScope` consume this boundary. The
existing identity response is unchanged. No schema or durable writer is added.

Eleven actual SQLite/Authority cases check zero-target roles, current sorted
assignments, the 32-target bound and a corrupted 33rd grant, corrupt vocabulary,
unknown/malformed/revoked keys, exact framed fields/CLI request, a real UDS,
restart/foreign owner, maintenance/retirement and actual consumed pairing.
Snapshots inspect every table count and all meta values before/after reads;
stored permission bytes remain unchanged. Together with original identity,
listener, CLI and pairing-consumption regressions, 65 Core cases pass on the
pinned development Mac and Linux arm64 toolchains. The Linux runner freshly
compiles Home against locked test dependencies and excludes no socket cases.
Actual TLS/UDS comparisons include scoped ordinary and
zero-target readers, refusal of injected grants and a freshly network-paired
principal with exact approved read access. Dispatch remains disabled.

`mix woh.native.controller.scope.smoke` passes one literal valid response and
40 independent native refusal cases, including every missing member, loose
integer/identity fields, unknown/duplicate/unsorted permissions, transfer
combination, oversized/invalid targets and envelope substitution. The real
owner portion of `mix woh.native.controller.domain.smoke authority` now compares
32 typed SDK calls, including current scope, across actual pinned TLS and UDS.
Native warnings-rejecting app typechecking passes with Swift 6.4/macOS 27,
targeting macOS 15. These checks open no Keychain and qualify no hardware.
Format, warnings-as-errors compilation, the twenty-contract metadata check,
shared health/identity and the full seventeen-case domain adapter regressions
also pass, together with seven focused packaged-probe/macOS inventory tests.

The software read is explicit and available for the remaining actual signed
session/selection, stale completion and original journal composition. A public
decoded scope still cannot manufacture that session. Installed macOS 15 TLS,
app signing/profile/SecItem success and physical qualification remain separate.
