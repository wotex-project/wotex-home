# Explicit rule operation v1

Version: 0.1.6. Accepted input correspondence with native model and recovery evidence, 2026-10-08. WOH.04 owns rule
semantics; WOH.14/15 own durable receipts and current authorization. WOH.08
consumes this closed profile for native explicit-rule drafting and recovery.
It does not expand `home-explicit-light-admission-v1` into a timer, edge or
composed automation profile.

The canonical input is a compact flat JSON array beginning
`"wotex-home.explicit-rule-operation.v1"`. Bound it to 4,096 bytes, one array
depth, nine scalar members and 128 bytes per string. Reject objects, nested
arrays, null, floats, alternate numeric/escape encodings and trailing bytes.
Integers are nonnegative signed 64-bit values within their owning ranges.
Booleans are accepted only for the final power value of review/admit.
Identifiers retain Home's closed ASCII syntax. The exact ordered records are:

| Kind | Fields after format and kind |
| --- | --- |
| review / admit | positive authority epoch, operation ID, expected Store revision, rule ID, source revision, target ID, power Boolean |
| activate | positive authority epoch, operation ID, expected Store revision, admission revision |
| invoke | positive authority epoch, operation ID, active rule generation, rule ID |

Expected Store revision is below the maximum signed 64-bit value, leaving room
for the authority event. Admission revision is zero for suspension or positive
and no greater than expected revision for activation. Invocation generation is
positive. Source revision is a nonnegative signed 64-bit value and remains part
of the complete source identity.

Review/admit reconstruct exactly one version-1 rule: supplied rule ID and source
revision; explicit-request trigger; literal-true predicate; supplied target's
absolute Boolean `power` effect; automation authority; block-on-unknown policy;
one-millisecond ownership; zero cooldown; causal budget one. These constants are
the existing independently admitted explicit profile, not caller defaults for a
broader rule grammar. Source reconstruction uses the owning Rule/Codec validators.
Decoding cannot admit, activate, invoke, grant a target or dispatch a device.

Original-input digest is SHA-256 of this exact canonical record. The bounded
read-only original-status join authenticates the current principal, compares
all original input against retained Store history and then return its matching
scalar result plus this digest. Review, admission and activation results are
immutable; invocation returns its current retained request receipt. An edited source, action, expected
revision, admission, rule or generation under the same principal/epoch/operation
refuses. Missing history remains unresolved. It must never call a first-write
path merely to perform lookup. Existing status and mutation routes keep their
exact shapes; no historical receipt or durable schema is rewritten.

The local route contains exactly `api_version: 1`, `operation:
"rule_original_status"`, `credential` and `original` (the closed array above).
Success contains exactly `api_version`, `outcome: "ok"` and `rule_original`;
the latter contains `kind`, `input_digest` and `result`. Results retain existing
scalar review/admission/activation/request receipt fields. Admission and
activation preserve their status `kind` fields. Missing history returns the
ordinary `not_found` envelope. Current permission and private principal scope
are checked even after a prior success. Retired source and quarantined Store
guards remain fail-closed. The read calls no checker, prepare path or writer,
does not advance a revision and cannot create missing work or a generation.

Native pending composition requires a separately versioned successor preserving
all v1/v2 records, the same shared private file/lock and original revision CAS.
Publish the complete closed input before each mutation. Recovery uses original
custody and matching status or exact retry, with digest/result correspondence
before durable removal. Review, admission, activation, invocation and actual
observed state remain separate user decisions and results. Missing or refused
later recovery retains the original; source edits cannot replace it.

Required evidence includes independent literal records/digests and complete
source reconstruction; unchanged existing rule grammar; malformed, expanded,
out-of-range, changed-source/action and Boolean-placement refusals; actual Store
original-status reads without revision changes; framed route correspondence;
and native lost-reply/restart recovery. No fixture substitutes for installed
signed custody or physical dispatch qualification.

`Rules.OperationInput` implements the bounded canonical records, digest and
exact existing Rule/Codec source reconstruction. Independent tests cover the
four literal records, an independently fixed admit digest, complete compiled
source fields and closed/range/allocation refusals. The existing compiler and
rule suites also pass: 23 tests total. The codec contains no Store, credential,
listener, writer or clock. `RuleOriginalRead` synchronously borrows the sole
Store connection through Authority; it validates the complete canonical source,
retained artifact and journal identity, historical admission/activation and
invocation origin before returning the matching result. Actual Store and framed
UNIX tests cover all four missing records without writes, complete-input
conflicts, private principal scope, later revocation, evolving cancellation,
restart without a review checker and a damaged review journal disabling writes.
The original-read, candidate-history and codec suites pass 47 tests.
`NativeRuleOperationWire` implements the same inert typed four-kind profile and
complete source construction. Independently literal Swift vectors match the
Elixir admit digest and reject expanded, nested, numeric/Boolean, escaped,
overlong and malformed input. The complete app includes this codec; no listener,
writer, clock or custody is introduced by it. `NativeRuleClient` constructs only
this typed source and its owning mutation fields through the existing strict
socket client and original peer lease. Preview distinguishes pending screening
and proposal-only basis; mutation and original lookup require complete scalar
receipt identity, expected revisions, generation/count correspondence and the
matching lookup digest. An immutable decoded result remains tied to the supplied
original input and authenticated principal. Forty-six independent socket cases
cover all four mutation/status routes, missing results, permission refusal,
changed principal/operation/digest, extra fields, numeric coercion and activation
counts. [Native pending custody v3](native-pending-custody-v3.md) now retains this
complete operation under the existing shared journal, and its typed runner uses
the exact original-status read or retry. Independent records, actual publication,
retained-version resolution and competing upgrade fixtures pass.

`NativeRulePanel` supplies the closed single-action draft and separate review,
confirmation and submission for screening, admission, activation, invocation
and suspension. Editing invalidates a prepared decision. Publication checks
the original credential bytes, custody reference and complete controller identity;
later recovery cannot substitute the editable draft. An admission hint is created
only after a matching successful durable resolution, never from a refused first
submission. Invocation displays its ordinary staged request ID for receipt lookup.
Twenty-two actual private-Store model/shared-recovery workflows cover each kind's
lost reply and exact lookup/retry, missing results, revocation, definite first
refusal, changed drafts/custody/controller, failed publication and fresh-process
recovery followed by explicit invocation of retained active policy. Legacy
thirty-four session-operation and coordinator recovery fixtures also pass. The
complete Swift app compiles with warnings as errors, and rendered reviewed and
unconfirmed views retain the original target/action. These fixtures qualify no
installed signed client, physical storage survival or device.
