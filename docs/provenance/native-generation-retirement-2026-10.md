# Native generation authority retirement and restart

Recorded: 2026-10-15. Contract:
[native generation first decisions](../specs/native-generation-ui-v1.md).
Clarified retirement requirements preceded code in 0f50510. Runtime:
ecc37367bcf481e0c94cdea948de4fb601bcf1c4 on local main. No schema, dependency,
sibling API, journal version or workspace representation changed.

## Corrected failure boundary

A failed refresh previously kept the private workspace/status in the generation
view. The model now retires context, displayed entry/status, private instruction/
feedback, prepared decisions and confirmations after authority/scope, transport,
malformed-response, delivery or custody failure. Complete private workspace and
pending originals remain intact. Failure handling performs no RPC or implicit
recovery; another explicit load is required.

Pure invalidProfileRequest refusal preserves entered input and the original
view while retiring prepared decisions/confirmation. A conflict caused by missing
archive uncertainty confirmation does likewise only while neither private
coordinator requires reload. Uncertain or conflicting custody with reload-required
retires the private view. This preserves the existing separately confirmed archive
workflow without retaining stale content after loss of authority.

## Executed cases

`mise exec -- mix woh.native.generation.flow.smoke` passed six both-family
Store/native cohorts: complete flow, running-attempt restart, and removed-policy
restart for each family. They used ten actual native process executions and ten
Store boots, including the second boot in each restart cohort.

- Complete flow revoked the authenticated principal between before-identity
  and the original preparation-status read. The refresh failed and retired all
  displayed private state and confirmation. The exact workspace root remained;
  pending stayed empty. The earlier publication/refusal/CAS/repair/manual review/
  cancellation/compatible/expiry cases also passed. Only the two explicit attempts
  called the scripted provider.
- The restart seed published preparation and attempt originals before their
  deliberately dropped replies. Actual status was running with null result.
  After stopping Store/custody/socket and starting the same database again, a new
  native process loaded the same files. Root status was retired; attempt status
  was unknown/null. New attempt preparation refused. Existing lookup and absence
  acknowledgement retained the pending original unchanged. Store revision and
  workspace bytes did not change; provider call count stayed one.
- The withdrawal seed prepared a root without starting an attempt. Restart
  omitted generation policies/providers while retaining database and private
  originals. A new native process read retired root status and empty options.
  Attempt preparation refused and retired displayed private content. No pending
  original, provider call, fallback or revision change followed. Workspace stayed
  unchanged and provider count stayed zero.

The fixture holds the restart provider for two seconds to observe its running
reservation before shutdown. That is scripted fixture behavior, not a production
deadline change. Complete-flow providers retain their 500ms fixture delay. Every
observed preparation/start operation dispatched once, after exact workspace/pending
publication. Physical dispatch stayed disabled. No model/account, Keychain access
or installed signed session was used.

`mise exec -- mix woh.native.generation.sdk.smoke` passed all 3942 codec/original-
delivery cases and its default both-family Store/socket/queued-result/restart
cohorts after the shared fixture changes. Formatting, warnings-as-errors compile,
catalogue (22 contracts), full HTML ExDoc with warnings-as-errors and Git whitespace
checks passed. Toolchain: Elixir1.19.6 / OTP28.5.0.6; Swift6.4 on arm64 macOS27,
Swift6 language mode targeting arm64 macOS15.

Logs: /tmp/home-native-generation-retirement.log,
/tmp/home-native-generation-retirement-sdk.log and
/tmp/home-native-generation-retirement-docs.log.
NGU-T3–T5 now include these local branch observations; they do not prove installed
interaction/accessibility, signed custody or complete host acceptance. Signed
paired generation and installed/physical/storage qualification remain separate.
No push, repository visibility change, release, firmware or installed app occurred.
