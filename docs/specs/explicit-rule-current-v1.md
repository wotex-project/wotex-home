# Current explicit rule v1

Version: 0.1.3. Accepted read-only native restart view with model evidence, 2026-10-08. WOH.04 owns
the existing restricted explicit admission; WOH.14/15 own Store, current grants
and generation identity. This view supplies no proof, activation or invocation.

The local request contains exactly `api_version: 1`, `operation: "rule_current"`
and `credential`. It authenticates the current rule manager/reviewer/ordinary
controller and, when a retained active admission exists, requires that caller's
current target grant before revealing its source. Source ownership or permission
revocation never becomes current authority by reading history.

Success contains `api_version`, `outcome: "ok"` and `rule_current`. Its exact
fields are `format: "wotex-home.explicit-rule-current.v1"`, `principal_id`
(authenticated caller), `authority_epoch`, `store_revision`, `rule_generation`,
`admission_revision`, `state`, `reason`, `artifact_digest` and `rule`. The latter
is null for inactive policy, or the closed `[rule_id,source_revision,target_id,
power_boolean]` projection of the exact retained restricted source. Artifact
digest is null when inactive, otherwise its actual retained SHA-256. State and
reason retain the existing active/inactive/suspended current-basis semantics;
active describes rule policy, not dispatch permission or observed state.

The projection reconstructs the owning fixed explicit source and must equal
the actual retained canonical source bytes. Validate historical artifact/journal
and current generation links before reading it. Suspended policy can show its
retained source under the caller's current grant; absent source cannot be filled
from a client draft. A corrupt link refuses and disables writing. Retired or
quarantined Store guards remain fail-closed. No schema, history, revision, active
pointer, clock, checker or device session is changed by this read.

After an app restart, explicit refresh can display the retained rule and review
its current generation before a separate invocation decision. New credential,
owner, epoch, target or generation requires a new review. Every invocation still
publishes its complete original input first and passes the Authority's ordinary
current guards. No automatic refresh, activation, invocation or recovery runs
on window load.

`RuleWriter.current_source` borrows the sole Store connection through Authority;
the strict local route and `rule-current` CLI use that same read. Actual Store
tests distinguish inactive/admitted/active states, project the exact source,
repeat current permissions and target grants, preserve a suspended source after
author revocation and restart, and refuse a damaged generation journal while
disabling writes. Reads do not advance revision. `rule-original-status
ORIGINAL_FILE` separately reads a private canonical original record (4,096-byte
ceiling) and uses the existing-only status join; alternate bytes refuse before
the API. The focused rule/input/CLI suites pass 35 tests.

`NativeRuleClient.current` decodes the closed source, numeric/Boolean ranges,
state/null/digest and complete field shape through the original peer lease.
Eight independent current-source cases join the existing 46 original-operation
cases. The native panel refreshes and displays this source only on an explicit
action. In the actual private-Store restart fixtures, the first process retains
an uncertain admission, a second recovers that original and separately confirms
activation, and a third new draft reads and separately confirms invocation of
the retained active rule. Its new draft identity cannot replace that source.
These cases join the twenty-two model/shared-recovery workflows; these reads
grant no authority or physical qualification.
