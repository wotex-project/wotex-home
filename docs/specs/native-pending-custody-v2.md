# Native pending-operation custody v2

Version: 0.1.2. Accepted extension with codec/storage/model evidence, 2026-10-07. WOH.08 owns this private client
journal. [Pending custody v1](native-pending-custody-v1.md) retains its exact
encoding, bounds, publication and recovery rules. This extension adds explicit
[native target access](native-target-access-v1.md); it creates no authority,
credential, receipt or physical qualification.

The canonical root is `["wotex-home.native-pending.v2",revision,entries]`.
The revision, sixteen-entry ceiling, depth/member/string/byte bounds, ordering,
one-category-per-controller-owner rule and exact five-field entries remain v1.
Every v1 category, context, custody, input and phase has its identical encoding
inside v2. V1 documents never accept the new category or inputs. Unknown versions
and fields fail closed without resetting or pruning the journal.

The new category is `access`. Its only inputs are:

| Action | Exact input |
| --- | --- |
| grant | `["native_target_grant",operation,expected_revision,target,resource_revision,binding_revision,selection_generation,artifact_digest]` |
| revoke | `["native_target_revoke",operation,expected_revision,target]` |

Access requires original native **operator** custody, with principal exactly
`native-setup-v1:<epoch>:operator`. Manual and other native roles refuse. Its
only phase is `["pending"]`; held review or commit/cancel phase cannot appear.
The context and custody reconstruct the complete original target-access wire
record, including deployment, owner, epoch, native creation revision and
verifier. Mutation fields retain that codec's exact identifier, positive
profile-pin, digest and revision ranges; expected revision is at least native
creation revision and leaves room for the change event. No endpoint, credential,
caller code, arbitrary request or authority token is added.

Keep the existing fixed `native-pending-v1.json` and `native-pending-v1.lock`
paths so there is one shared journal and one publication lock. Reading v1 does
not rewrite it. The first explicit access publication upgrades the root to v2
inside the existing full-content/revision/inode CAS, preserves all original v1
entries and advances the existing revision once. Preserve v2 after removing its
last access entry or publishing ordinary v1 work; never downgrade or reset its
revision. An unchanged publication or resolution confirmation keeps exact bytes
and revision. Older clients fail closed on v2 rather than accepting less guarded
work. Concurrent upgrade and ordinary publication use the same lock and CAS.

Publish original input before any grant/revoke send. Recovery opens only that
original existing custody, checks its verifier and actual controller/principal,
then uses the signed broker for exact original lookup or retry. Verify a receipt
against the reconstructed complete mutation, including its canonical digest,
before durably removing the original. Missing status, later refusal, lost reply,
unavailable custody or changed controller retain it. No general credential
selection, role creation, fallback, input edit, new operation or implicit grant
is provided. V1 recovery semantics remain unchanged.

Required software evidence includes independent v2 grant/revoke vectors and
their complete access-wire correspondence; unchanged v1 literals; rejection of
new inputs under v1, manual/expanded roles, changed custody/pins, unsupported
phase and version; mixed original entries; upgrade and retained-v2 resolution;
stale-snapshot refusal; exact bytes on no-op; and process restart without sends.
Actual signed custody and installed storage survival keep their host obligations.

The typed Swift document implements both exact roots and validates new access
entries against their complete reconstructed native target wire record.
`mix woh.native.pending.codec.smoke` retains the independent v1 literals and
adds independent grant/revoke v2 literals, a shared complete-input digest,
mixed categories, retained empty v2 and invalid role/custody/phase/version
vectors. The existing bounded scanner is unchanged.

`mix woh.native.pending.storage.smoke` exercises actual private-file upgrade,
preserved v1 inputs, unchanged bytes on no-op, stale pre-upgrade CAS refusal,
retained v2 after access/ordinary resolution and later ordinary publication.
Two actual competing processes publish access upgrade versus ordinary work
from the same v1 snapshot: exactly one wins, the other refuses, and restart
preserves the winning version and both original records. Existing v1 crash,
file guard and concurrent publication checks also pass. These tests open no
credential custody and send no API or physical request.

The access model and shared typed recovery now compose this document with the
actual Authority ledger. The coordinator can require the exact native reference
from explicit review as well as its original bytes, before identity work or
publication. Receipt correspondence precedes durable resolution and the exact
model callback. `mix woh.native.access.panel.smoke` checks fifteen real Store
workflows, including two-process lost-reply lookup/exact retry, changed bytes or
reference, publication refusal/known-original recovery, missing result,
wrong returned digest and refused later retries. It validates the actual v2
journal against each trusted mutation and leaves physical dispatch disabled.
Its foreground adapter supplies no signed custody seal. Existing coordinator,
health and profile recovery regressions retain their v1 behavior; installed
signed custody and storage survival remain separate host obligations.
