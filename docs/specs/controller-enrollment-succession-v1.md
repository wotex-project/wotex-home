# Controller enrollment succession v1

Version: 0.1.1. Accepted mechanism before implementation, 2026-10-07.
This is the narrow retained compiled-enrollment successor of the
[controller transfer](controller-transfer-v1.md) and WOH.03/15 boundaries.
Portable selected profiles keep their separately reviewed lifecycle.
Their historical maintenance link may name an independently validated `begin`
or `transfer` barrier; a transfer barrier must retain its complete acceptance
history and cannot be supplied as a caller truth decision.

An accepted destination receives enrollment-review permission with no target
grants. A retained compiled enrollment still names its revoked source reviewer.
The destination may make a fresh operator-bound re-review of that exact retained
binding. Acceptance never supplies interview evidence or automatically makes
that re-review current. Ordinary same-reviewer behavior remains unchanged;
an unrelated reviewer cannot take a binding merely by possessing review or
control permission.

The Store authorizes a reviewer change only through its fully validated schema
22 ownership history and the current active acceptance head. The caller must
be the original receiving principal of that head, currently authenticated with
enrollment-review permission. The previous reviewer remains revoked. The
current eleven-column binding must exactly equal the archived current binding
in that acceptance's canonical domain document, and its fourteen-column latest
review must equal the archived head review. Binding revision precedes acceptance.
The new interview/review keeps the exact Thing declaration, stable identity,
method, profile and qualification reference; its identity digest freshly binds
the new authenticated reviewer. No caller supplies acceptance, domain or epoch
proof. Missing, changed or unsupported retained scope fails closed.

The existing review-history row and `thing_enrollment_rereviewed` event retain
the new reviewer at one original revision. The binding changes reviewer in the
same transaction, using its prior reviewer/revision as CAS. Current reports,
source grants and qualification are cleared or revoked and held/unsent work is
invalidated through the existing re-review barrier. Failure rolls back the
entire change. Exact current retry returns the original decision revision; a
changed or superseded input conflicts. Status stays private to its reviewer.
This creates no target grant, qualification, admitted rule or dispatch authority.

Startup and every archive validate each adjacent historical reviewer change.
A change must be either an exact existing portable-profile selection binding
or this succession. For succession, the latest acceptance before that review
must name its new reviewer and contain the exact previous binding/head review;
no intervening retirement is allowed. Stable identity, method, profile and
qualification reference must remain equal across this compiled succession.
Historical validation uses original immutable acceptance/domain bytes, never
current issuer keys or clocks. It does not require past reviewers to remain
active. There may be at most 4096 reviewer crossings: 2048 portable selection
crossings plus the bounded 32 accepted owners × 64 retained domains. Unsupported
schemas keep their existing validation. No new table or inferred migration
authority is introduced by this mechanism.

Required software evidence includes unrelated/old/current reviewer cases,
private retry/status, changed binding/domain substitution, final multi-row
rollback, restart and encrypted archive validation, another owner transition,
and coexistence with existing portable-profile history. Fresh device capture,
installed custody and physical qualification remain separate obligations.
