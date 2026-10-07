# Explicit rule operation v1

Version: 0.1.1. Accepted input correspondence with inert codec evidence, 2026-10-07. WOH.04 owns rule
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

Original-input digest is SHA-256 of this exact canonical record. A new bounded
read-only original-status join must authenticate the current principal, compare
all original input against retained Store history and then return its matching
immutable scalar result plus this digest. An edited source, action, expected
revision, admission, rule or generation under the same principal/epoch/operation
refuses. Missing history remains unresolved. It must never call a first-write
path merely to perform lookup. Existing status and mutation routes keep their
exact shapes; no historical receipt or durable schema is rewritten.

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
listener, writer or clock. Original-status, native codec/pending composition and
controls remain the next implementation joins; these pure vectors qualify no
rule, installed client or device.
