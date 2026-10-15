# Paired generation workspace custody v2

Version: 0.1.1. Updated: 2026-10-15. Status: accepted successor target.
Owner: WOH.08 H08-09/H08-T9; WOH.15 H15-07/H15-T8;
WOH.18 H18A-02/04/05 and H18-T15/T16/T17.
Implementation: v1/v2 representation, monotone private custody and local-consumer
paired refusal implemented; signed composition remains separate.
Evidence: [executed vectors/private CAS/races/restart/local refusal](../provenance/native-generation-workspace-v2-2026-10.md).

## Result, shape and inherited obligations

This extends the private [v1 workspace](native-generation-ui-v1.md) to paired
original custody. It owns representation and private CAS only. The
[paired composition](native-paired-authoring-generation-v1.md) owns actual signing,
current scope and submission; [v8 pending](native-pending-paired-authoring-v8.md)
owns complete publication before mutation. No new Store or producer API is required.

**NGW2-01.** Keep fixed native-generation-workspace-v1.json/.lock and the same
nonlinked same-user 0700 directory, regular single-link0600 files and exact
descriptor/content/revision/inode CAS. v2 root is exactly
`["wotex-home.native-generation-workspace.v2",REVISION,ENTRIES]`, positive S64
revision, at most2097152 bytes and0–16 entries. Entry remains exactly
`[CONTEXT,CUSTODY,BASIS_SHA,PREPARATION_DOCUMENT,ATTEMPT_DOCUMENTS,CANCELLATION_PENDING]`.
Sort/uniqueness remains canonical deployment/owner/epoch bytes, regardless of
principal. Native/manual records keep all v1 checks unchanged.

Paired custody is exactly the five-slot array from v8: paired tag, lower hex64
association/controller, positive S64 creation revision and lower hex64 verifier.
Context has lower hex64 deployment/owner, positive S64 epoch and exactly
paired-controller-v1:EPOCH:lower-hex64-client principal. Each preparation/attempt
matches context epoch and expected revision is at least custody creation revision.
Basis SHA is lower hex64 metadata, not current authority.

Complete canonical preparation and attempts retain their32768/2048 decoded UTF-8
ceilings. There are0–3 ordered attempts, no more than the selected root budget;
indices equal one-based position, preparation operation/SHA match, operation IDs
are unique, expected revisions strictly increase above preparation, initial
predecessor null/repair false, later predecessor exactly prior ID/repair true.
Cancellation_pending is a boolean intent, not a cancelled/stopped result.

Keep depth4/nodes1024/arrays16/ordinary unescaped ASCII strings128 before allocation.
Only exact original-document slots allow their inherited larger UTF-8 and canonical
quote/backslash escaping. Revalidate canonical bytes/links on every access; reject
floats/bools/overflow integers, malformed identity, slot bleed and unknown versions
without reset. Redact reflection. Store no credential/seal/endpoint/key, source or
draft bytes, clock or current grants.

## Upgrade and consumer boundary

**NGW2-02.** v1 cannot encode paired custody. Load/no-op preserves original version
and bytes. First paired root retention upgrades to v2 once under CAS, preserving
every native/manual root and monotonically increasing revision. Subsequent append,
intent change, archive and empty/local publication retain v2. Existing entry fields
remain immutable except one exact attempt append or independent intent toggle.
Same-scope another root conflicts; stale archival cannot remove a newer entry.
Uncertain write retains memory and blocks dispatch until explicit reload/CAS.

**NGW2-03.** Decoder and storage supply no signed session. A consumer opens actual
existing association/Keychain custody under its signed purpose, repeats exact
context/association/controller/creation/verifier/current scope and file witnesses,
then publishes v8 pending before mutation. Opening/loading/editing makes no RPC.
Original recovery uses the retained association even when another controller is
selected; no local fallback, imported key or edited-input retry is permitted.

## Acceptance

Before code freeze independent Python roots from frozen complete originals and
paired identity literals; do not derive valid roots with the Swift encoder.

| Case | Requirements | Stimulus / falsifier | Level |
| --- | --- | --- | --- |
| NGW2-T1 | 01/02 | Exact paired/mixed/Unicode/boundary roots, wrong epoch/creation/links/phase/marker, v1 paired refusal and private reflection. Alias or widened old syntax fails. | Native software |
| NGW2-T2 | 02/03 | Actual v1 upgrade, no-op, append/intent/archive, sixteen capacity, unsafe file and competing publishers; independent restart makes no request. Lost root, downgrade, multiple winner or dispatch on load fails. | Private file/process |

Signed publication/first submission and installed/physical/power-loss acceptance
remain separate composition obligations. Record only executed evidence.
