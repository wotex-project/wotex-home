# Native pending-operation custody v5

Version: 0.1.2. Owner: WOH.08 H08-09/H08-T9, WOH.14 H14-06/H14-T7, WOH.15 H15-07/H15-T8. Status: paired-original codec, private publication and local recovery refusal implemented; original-purpose recovery foundation implemented separately; remote capture/coordinator/UI composition pending.

This extends [v4](native-pending-custody-v4.md) with an original reference to
[public controller association custody](native-controller-associations-v1.md).
It creates no Keychain item, authenticated scope, transport selection or API
request. The [original-purpose consumer](native-paired-recovery-v1.md) now binds
this metadata to actual signed acquisition and a closed runner. Remote capture,
coordinator and shared presentation composition remain successors.

The root is `["wotex-home.native-pending.v5",revision,entries]`. Keep the exact
existing private file/lock, descriptor/full-content/inode CAS, canonical ordering,
one category per deployment/owner/epoch, sixteen entries, 65,536-byte root,
depth-four and member-thirty-two bounds. All older entries keep their bytes,
local/manual custody meaning and unchanged typed input/phase syntax. Only the
existing schedule-document slot permits 8,192 decoded ASCII bytes with canonical
quote/backslash escaping; every other string retains its 128-byte unescaped
ASCII bound. No older root admits the new custody tag.

The new custody array is exactly:

```text
["paired",association_id,controller_id,creation_revision,credential_verifier]
```

Association/controller/verifier are 64-character lowercase hexadecimal digests;
creation revision is a positive signed-64-bit integer. The unchanged context is
`[deployment_id,owner_id,authority_epoch,principal_id]`. Its principal is exactly
`paired-controller-v1:EPOCH:CLIENT_ID`, using the context's canonical positive
epoch and a 64-character lowercase hexadecimal client ID. A different namespace,
epoch spelling, missing/extra field, Boolean or overflow refuses. No key, TLS
seal, certificate, endpoint, clock sample or current grant is stored.

Original matching requires the complete retained association ID, controller,
creation revision and verifier, plus exact context deployment/owner/epoch and
principal. Validate the public association's own canonical binding first.
Label/endpoint metadata edits preserve this join; another controller/principal,
trust binding or credential generation cannot substitute. This pure matching
function is a refusal guard, not a successful Keychain/TLS/authorization seal.

Existing ordinary power, cancellation, override, maintenance, profile, explicit
rule and schedule input/phase grammars apply unchanged. Paired rule/schedule
Store-basis revisions must be at least the paired creation revision, matching
the existing native-generation guard. Native target-access operations remain
local-broker-only and refuse paired custody. Public permissions/targets do not
authorize any original or widen a grant.

First paired publication upgrades an older root under the existing CAS,
advances revision once and preserves every original. Read, unchanged confirmation
and failed publication never upgrade it. Retain v5 after resolution, when empty
and on subsequent local publication. Stale publishers cannot overwrite an
upgrade or remove another original. Corrupt/unknown custody never resets the
journal or falls back to a local/manual key.

Before any remote mutation, the first-capture consumer must capture actual existing
[paired Keychain custody](native-paired-keychain-v1.md), fresh verified TLS and
authenticated owner/principal/grants, then publish this exact original. Recovery
must use that original association irrespective of saved selection. It must
verify matching current custody and original response correspondence before
removal. Lost/missing/refused responses retain the original and never move it to
another owner or retry with a new ID. Load sends no lookup, retry or device
request. Until shared remote composition exists, the local recovery coordinator, local
operation runner and window controls refuse paired rows before credential or
socket activity; they cannot pass them through the local broker/Unix socket.

Required evidence: independent literal valid/refusal roots and association
joins, wrong controller/principal/epoch/verifier/creation, unchanged old roots,
rule/schedule generation bounds and native-access refusal; actual v4-to-v5
private publication preserving old originals, no-op bytes, stale CAS, restart,
resolution with retained v5 and competing ordinary/upgrade publishers with one
winner. Existing codec/storage/coordinator regressions remain required. These
establish client metadata custody only; actual paired capture/recovery,
installed signing/Keychain and physical/storage qualification remain open.

## Development evidence

`mix woh.native.pending.paired.smoke` compiles production codecs, storage,
coordinator, local runner and association matching with Swift 6 warnings as
errors. Seven independent valid roots and 31 refusals cover ordinary, rule and
schedule originals, paired principal/generation bounds, older-root refusal and
native target-access exclusion. Pure joins reject substituted association,
controller, creation, verifier or context while accepting editable metadata.

Actual private files retain the independently authored v4 original through v5
publication, exact no-op bytes, stale CAS, resolution, empty v5 and later local
publication. Twelve ordinary/paired two-process races have one winner and a
separate process reloads its retained version/originals. Actual coordinator and
both production/local-fixture runner entries refuse paired lookup/retry/review
cancellation before any credential opener, broker or socket activity; original
bytes remain unchanged. This is metadata and refusal evidence, not successful
remote recovery. The changed pending view has a separate 480-point fixture.
Installed signed custody, real paired capture/receipt recovery and storage
survival remain required. The existing codec, private storage and actual-Store
coordinator regressions also pass. The v5 local-original compatibility check
replaces the older fixture's obsolete assumption that v5 was unknown; v6 still
refuses. The 480-point view was rendered and inspected with paired controls
disabled and local controls unchanged. Checks use the development Swift
6.4/macOS 27 host targeting macOS 15, not an installed signed or physical host.
