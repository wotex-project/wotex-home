# Native session presentation v1

Version: 0.1.9. Accepted native presentation mechanism with software evidence,
2026-10-08. WOH.08 owns this app session, joining the
[credential broker](native-credential-broker-v1.md) with the existing ordinary
Authority routes. It changes no role permission, Thing grant or dispatch gate.

The app has one explicit selected local session shared by its windows. The user
chooses one of the four fixed native roles and explicitly requests its session
from the authenticated broker. Registration and a status check select no role.
Do not automatically request a credential, display its bytes, copy it to the
clipboard, serialize it or put it into the legacy manual-import Keychain item.
Hold exactly one current native credential in memory with redacted descriptions
and reflection; closing the app discards it. A fresh explicit selection reconciles
the same original agent item/principal. Failed setup leaves the prior selection
unchanged and explains uncertainty without creating another operation or secret.

Keep native setup state/owner/epoch/role separate from background registration,
ordinary health, current permissions and hardware observations. Display roles in
plain language and state that device access needs a separate grant. Transfer
authority does not acquire ordinary read or control by being selected. No status
or count qualifies a device or enables physical dispatch.

The existing manual-import mode remains available for development and trusted
external custody. Selecting native custody supersedes it in memory only.
Explicitly ending a native session leaves no selected credential; it cannot
silently resume the saved manual item. The user can explicitly select manual
custody or import a new manual credential. Preserve that item's existing service,
account, non-syncing policy and unrelated client settings. Native selection/end
performs no SecItem operation. A successful explicit manual import selects that
mode; a failed import changes no current selection.

Use a bounded synchronized memory holder so background client work can capture
one original credential safely. Source UI tasks must not hold its lock during
IO. An already-created uncertain operation/review keeps its original credential,
identity and exact request; selecting another role cannot rewrite those inputs
or make a principal-private receipt public. New setup/mutation controls must
respect existing busy/uncertainty guards. This profile does not implement
persistent pending-operation custody, target grants, rule editing or transfer UI;
their separate contracts/evidence remain required.

The current session, health, maintenance and profile models are shared across
windows. Session selection/import/end refuse while any of
these models is busy or retains an unresolved request/review. Selection clears
credential-scoped views and their captured credentials; a fresh read is needed
before another mutation. An original creation receipt is displayed as session
metadata and is never used as the current Store watermark. A successful setup
check remains available for an unresolved original when no model is in flight;
it selects no credential. A successful authenticated check identifying another
deployment/owner/epoch reports that change and preserves the prior selection
until an explicit session choice. The pending-operation coordinator may permit
a separate current session while preserving old-owner records, as specified in
[pending-operation custody](native-pending-custody-v1.md). File metadata alone
cannot establish that owner change.

Health requests retain at most one original in each of three categories: power
submission/cancellation, override issue/revocation and rule suspension. Each
stores a captured credential and closed typed input before IO; lookup matches
the original epoch/operation and retry sends those exact inputs. A missing
receipt or unsuccessful retry retains the original. Cancellation lookup clears
its original only for a rejected request; revocation lookup needs the revoke
revision. A definite initial policy refusal can clear an unsent original, but
a later retry refusal does not disprove an earlier commit. New work cannot
overwrite an unresolved original in that category. Every multi-route health
refresh captures one credential. Credential-bearing models redact reflection.

Software evidence checks inert memory selection without opening Keychain,
native replacement/end/manual transitions, malformed credentials and secret
redaction. Actual unsigned setup must fail without changing current selection.
Compile the actual app and inspect the rendered setup panel. Never render a
real credential or invent signed/Keychain success. Actual signed role delivery,
fresh-account usability, accessibility and installed lifecycle remain their
own obligations.

Implemented software evidence: `mix woh.native.session.panel.smoke` checks
inert memory transitions and actual unsigned refusal without any SecItem call,
and renders the unselected panel. Its PNG was inspected for unclipped controls
and readable role explanations. The actual app compiles under Swift 6/macOS 15
with warnings as errors. `mix woh.native.session.operations.smoke` exercises
seventeen live private-Store workflows: lost committed power/cancel/override/
revoke/suspension responses, original-credential lookup and exact retry after
replacement, plus three requests dropped before reaching Home. Missing receipts
retain pending state; the retry commits once. Four more cases discard an actual
not-found cancellation/revocation reply, replace the selected credential and
repeat the original through Retry Original or the same mutation control.
Lookup and not-found retry preserve the unresolved original, keep setup blocked
and create no Store revision. Such retries do not refresh another selected
credential's views automatically. Committed retries leave the Store
watermark unchanged, and another equally scoped principal cannot read the
receipt. Setup guards refuse before broker work, new requests cannot replace
originals, and session invalidation clears scoped views. Eight live profile
workflows also pass with shared model injection, including preservation after
principal revocation and refused retries. These are temporary
ordinary Authority credentials, not signed native custody or physical evidence.

Health mutations now join the private pending-operation coordinator. Startup
loads its records before session/mutation work; publication precedes delivery
and verified resolution is persisted before clearing the memory guard. The
seventeen actual Store workflows also check the exact original journal before
each mutation, two health windows sharing the same coordinator, durable empty
file retention after resolution and preservation after missing retry results.
App startup reads no custody or API automatically. Persistent recovery controls
and the remaining profile composition retain their separate work. Maintenance
begin/end also publish through the coordinator and retain the same status
credential for original lookup/retry. Twelve actual private-Store panel workflows
check lost replies, unsent requests, replaced snapshots, refused retries and
definite first refusal, plus the shared-window guard. Matching principal/action/
revision is verified before durable removal clears memory. The uncertain panel
was rendered and inspected. These checks grant no device access or signing
qualification.


Profile operations now join the private journal as well. Preparation holds the
published original until actual review metadata is saved. Commit/cancel first
save their immutable intent, and selection retains the same prepare input.
A vanished review does not authorize commit; cancellation intent cannot change
to commit. The eight live profile workflows check exact journal input/phase
before each actual mutation, including retained failed retries. Positive result
removal is durable before controls clear. Authenticated owner change may allow
explicit session selection while preserving old-owner profile originals; file
metadata supplies no owner authority. Persistent recovery controls and installed
custody keep their own obligations.


The app exposes explicit original lookup/retry and held-review cancellation
through its shared pending panel. Existing custody and authenticated original
identity are checked before any operation call. Publication and verified
resolution keep all windows guarded, and domain memory is released only for
the exact confirmed original. Health and maintenance fixtures also exercise
this shared recovery entry point, with private Store evidence for lost replies,
unsent requests, missing results and revoked principals. Startup remains file
read only. Installed signed custody retains its separate qualification gates.


The profile fixture now runs sixteen domain/shared-recovery workflows.
Recovered held reviews permit lookup/cancellation and refuse renewed approval
before custody work. Positive cancellation releases the exact original model
after durable resolution. Expiry, vanished review and lost cancellation remain
retained; a revoked principal fails authenticated identity before retry can
reach a profile mutation. Actual Store history and absent selection are checked
separately from scripted capture. No installed signing or device qualification
is supplied by these fixtures.

Stable-ID permission lookup for a retained native author now repeats original
native creation/revocation history, just as bearer authentication does. An
active row contradicting a retained revocation cannot authorize a retained
policy or a future credential-free runner. Rule status propagates corrupt
native custody as corruption, and ordinary Store reads disable writing on
native custody/target-history damage. The private-Store regression checks valid
permissions, actual revocation, altered current projection and the real rule
status refusal without advancing revision. This changes no role or grant and
does not establish installed custody.
