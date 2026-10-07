# Native pending-operation custody v3

Version: 0.1.2. Accepted rule-input extension with codec/storage evidence, 2026-10-07. WOH.08 owns the private
client journal; WOH.04/14/15 retain rule, Store and current authorization semantics.
This extends [v2](native-pending-custody-v2.md) with the closed
[explicit rule operation](explicit-rule-operation-v1.md) correspondence.

The root is `["wotex-home.native-pending.v3",revision,entries]`. Keep every v1/v2
entry byte-for-byte, their ordering and one category per controller owner, the
same private file/lock paths, full-content/revision/inode CAS and all existing
65,536-byte/depth-four/member-thirty-two/string-128/sixteen-entry bounds. Older
roots refuse new input. Unknown versions and records fail closed without reset.

The existing `rule` category adds one input: the complete flat canonical explicit
rule operation array, including its format, kind, epoch and operation ID. Its
only phase is `["pending"]`. Epoch must equal the retained context. Manual
custody remains the original fixed account/verifier; native custody must be the
original Operator role, with expected revision (where present) at least its
creation revision. No secret, proof, time source, editable request or activation
token is added. An old suspension and a new explicit operation conflict under
the existing category key; neither can replace the other.

Read and unchanged confirmation never rewrite a root. The first explicit rule
publication upgrades v1/v2 to v3 under the shared CAS and advances revision
once while preserving all old inputs. Keep v3 after resolving the last new input,
on later ordinary publication and when empty. Concurrent ordinary/upgrade
publications have one winner; stale originals remain available for recovery.

Publish the complete original before any recorded review, admission, activation
or invocation mutation. Recovery opens existing original custody, verifies its
bytes and authenticated controller/principal and uses the read-only exact
original-status join or exact typed retry. Compare returned kind/digest and
scalar receipt against that original before durable resolution. Missing status,
changed custody/controller, publication uncertainty and later refusal retain
the original. No automatic lookup, retry, approval or new operation runs on load.

A recorded review is a screening result, admission retains an independently
checked restricted artifact, activation changes the generation and invocation
creates an ordinary held request. Each remains a separate explicit decision.
Receipt removal does not establish protocol acknowledgement, observation or
physical qualification; default-disabled dispatch remains unchanged.

Required evidence includes independently literal records of all four kinds,
complete source/digest reconstruction, old-root refusal, unchanged v1/v2 vectors,
wrong epoch/custody/phase/range rejection, mixed originals and category conflicts;
actual file CAS/version preservation and competing publication; actual Store
lost replies, missing results, revocation and process restart through shared
recovery. Software fixtures do not qualify installed signed custody or storage
survival.

The Swift document accepts the exact v3 root and complete typed operation,
without expanding either older root or the bounded scanner. Independent literal
records for all four kinds reconstruct the source and cross-language digest;
tests cover old roots, mixed originals, retained empty v3, original epoch,
native roles, phase and category-conflict refusal. The serializer keeps explicit
signed-64-bit integer identity before Foundation can coerce values.

Actual private-file tests upgrade v2 with old power/access records retained,
preserve exact bytes on no-op, refuse stale snapshots and competing rule inputs,
and keep v3 after resolution/ordinary publication. Two actual processes contend
from one v2 snapshot: explicit v3 publication and ordinary v2 suspension have
exactly one winner, followed by a fresh-process read of the preserved originals.
Existing v1/v2 crash, file-guard and race fixtures also pass.

The shared recovery runner reconstructs the complete typed operation and uses
`NativeRuleClient` for exact lookup/retry; its result is tied to that input and
principal before resolution. Legacy coordinator recovery remains unchanged.
Native rule-model and actual Store lost-reply/restart composition remain the
next evidence joins. These fixtures open no Keychain and send no device effects.
