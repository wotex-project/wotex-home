---
name: authority-journey
description: Change or verify authoring review, target/grant selection, original-operation replay/status or framed native requests when human admission and current durable authority can diverge. Excludes presentation-only styling and packet codecs.
---

# Prove an operation through current Authority

Input: the authenticated peer/credential, exact original operation and reviewed
subject/basis, transport and visible result. Output: the native/framed request to
Authority/Store path, semantic replay/refusal assertions and explicit shell or
physical proof limits.

Read [Authority](../../../lib/wotex_home/authority.ex), its
[ReviewGate](../../../lib/wotex_home/authority/review_gate.ex) and the affected
stateless Store writer. Follow closed framed input and authenticated peer into
the transport-independent use case; identify who owns the credential, principal,
authority epoch, operation ID, subject version, target and payload being reviewed.
Store owns current checks and the commit, never the UI or adapter.

For review/install/target changes, bind human admission to the exact retained
subject/version, payload and current session/basis. Recheck current grants,
artifact/declaration/runtime witnesses and Store receipt-clock freshness at the
actual mutation. Read-only guidance, inspection snapshots and generation
preparation create no continuing authorization. Model output or a valid producer
schema is still a proposal until this consumer's current guards admit it.

Use [authoring review vectors](../../../test/wotex_home/authoring_review_test.exs)
for independent wire meaning,
[external input installation](../../../test/wotex_home/external_input_installation_test.exs)
and [history assertions](../../../test/wotex_home/external_input_history_test.exs)
for actual admission/replay state. Select changed/revoked basis, foreign target,
wrong peer, expiry and lost-reply cases. After a lost reply, recover the original
operation's immutable receipt/status before considering new work; creating a new
operation can spend a second causal root. Replay/status and revocation must not
silently depend on a newly available live producer when the owner contract says
otherwise.

For a changed native/framed route, exercise
[local API routing](../../../test/wotex_home/local_api_route_test.exs) and
[exchange semantics](../../../test/wotex_home/local_api_exchange_test.exs) against
the same Authority/foreground Store where appropriate. Compare exact typed
results, original identity and refusal state across clients. A codec round-trip
alone does not prove current Store checks, and a window screenshot does not prove
an operation or replay. Establish semantic operation proof before shell claims.

Preserve distinct staging, admission, durable handoff, protocol acknowledgement
and observed readback outcomes. Uncertain effects require owner reconciliation;
UI cancellation, retry or transport loss must not refund a spent root or blindly
resend. Workers receive scoped work, never the Store connection or operator bearer.
Use [durable changes](../durable-changes/SKILL.md) for transaction/history mechanics
and [delivery verification](../delivery-verification/SKILL.md) for actual lanes.
This workflow supplies no physical dispatch or production authority.
