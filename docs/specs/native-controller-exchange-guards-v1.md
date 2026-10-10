# Native controller exchange guards v1

Version: 0.1.0. Owner: WOH.08 H08-09/H08-T9, WOH.15 H15-07/H15-T8. Status: accepted additional transport guard; implementation and installed session evidence pending.

This extends the [shared typed transport](native-controller-domain-sdk-v1.md)
with additional refusal checks for the future actual signed session. It adds no
wire fields, credentials, grants, selection, Keychain backend or session seal.
A supplied successful closure cannot manufacture custody or authorization.

## Original exchange boundaries

An explicitly supplied guard checks before opening a connection, after actual
TLS verification immediately before application send, after validated response
decoding, and after the typed SDK has decoded a successful result before async
delivery. Existing entries without a guard retain their original behavior.
Each exchange and page uses its original peer, bearer and absolute deadline.
Checks cannot renew an expired custody lease, select another association or
extend handshake/request budgets. The final typed check uses the last original
exchange deadline, including its original clock-production/scheduling budget.

Production composition must itself supply actual current signed custody and
original association/selection checks, following the [paired custody
contract](native-paired-keychain-v1.md). These platform/file checks may block.
They run on a separate executor from the socket owner, with a finite continuous
deadline and cancellation. A blocked check cannot prevent socket cancellation
or async completion. No late check may send application data or publish a value.
Platform work already in progress may finish later; no memory erasure or forced
termination of Security APIs is claimed.

A failed check before possible send refuses with the closed `invalidRecord`
transport error. After possible send, failed/expired/cancelled checks retain
`outcomeUnknown`, including a previously validated server reply. No raw guard or
platform error is serialized, reflected or logged. Timeout and cancellation
stop the original owner; no replacement connection, local fallback or automatic
retry is created. Existing TLS trust/clock and typed receipt guards still run.

## Required evidence

Use real independent TLS peers to check all four boundaries, success ordering,
pre-connect and pre-send refusal without application data, post-send refusal,
and guard failure after typed decoding. Block each boundary beyond its original
deadline and cancel while blocked; require finite owner completion and no late
application send/delivery or second connection. Preserve existing unguarded
bootstrap/API/domain and actual Authority/UDS parity regressions. Fixtures may
exercise additional closures but cannot create a signed session or touch the
operator's Keychain. Installed signed selection, revocation, original paired
recovery and macOS 15 interoperability remain separate successors.
