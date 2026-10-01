---
name: durable-changes
description: Change or review SQLite schemas, durable receipts, rule activation, maintenance barriers, or effect guards when retry, restart, backup, or command-handoff behavior can change. Excludes presentation-only changes.
---

# Durable changes

Input: the requested behavior or failure, affected durable transition and
existing schema/data compatibility requirements. Output: a change preserving
operation history and guarded execution, focused regression evidence, and any
remaining compatibility or recovery limits reported in chat.

## Follow the affected transition

Trace the use case through [Authority](../../../lib/wotex_home/authority.ex),
[Store](../../../lib/wotex_home/durable/store.ex) and its relevant stateless
writer. Inspect the transaction and journal links, not just the public return
value. Identify which inputs can change between staging, queue, claim, handoff
and settlement; cover each affected boundary.

For execution or retry changes, read the relevant parts of the
[durable execution contract](../../../docs/specs/WOH.14-durable-execution.md).
For rule or invariant changes, use the
[automation contract](../../../docs/specs/WOH.04-state-automation.md) and the
actual artifact/runtime gate code. Expand an admission profile only with
correspondence and guard evidence for the new semantics.

Check immutable principal/epoch/operation identity, revision CAS, active
generation, current grants, declaration/artifact bindings and Store-owned
freshness where the transition uses them. A lost reply uses the original
operation; cancellation, restart or fencing must not refund a spent root or
replay an uncertain handoff. Inject a transaction failure when changing a
multi-row barrier so rollback is observable.

## Schema and recovery changes

Inspect [Schema](../../../lib/wotex_home/durable/store/schema.ex),
[Integrity](../../../lib/wotex_home/durable/store/integrity.ex) and
[Backup](../../../lib/wotex_home/durable/backup.ex) together when persistent
shape changes. Preserve historical receipt/journal identities and use each
supported schema's actual table set. Migration must not manufacture current
authorization, freshness or qualification from old rows.

Read the affected [recovery contract](../../../docs/specs/WOH.16-release-recovery.md)
for backup or maintenance work. Verify retained history, damaged links and
restart behavior. Restored data remains quarantined until the actual transfer
requirements are satisfied.

## Focused validation

Use the existing suites for the changed domain: `durable_store_test.exs`,
`durable_requests_test.exs`, `durable_rule_activation_test.exs`,
`durable_invariant_test.exs`, `durable_maintenance_test.exs` and
`durable_causal_roots_test.exs` under `test/wotex_home/`.
Choose relevant cases rather than running every domain for an unrelated edit.
Test an actual SQLite transaction or public authority operation for durable
behavior; source-text searches alone do not prove a guard executes.

For a changed external route, also exercise its framed adapter with the same
typed result and original identity. Inspect failures, rejected operations and
historical receipts as well as the successful path. Software restart/rollback
tests establish software behavior, not target-storage power-loss survival.
