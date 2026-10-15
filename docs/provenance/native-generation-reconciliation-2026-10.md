# Native generation missing-original reconciliation

Recorded: 2026-10-15. Owners: [SDK recovery](../specs/native-generation-sdk-v1.md),
[v7 custody](../specs/native-pending-generation-v7.md) and
[first decisions](../specs/native-generation-ui-v1.md).
Accepted requirements: 970756b. Implementation:
582567b101efd8553d0c0c25fc5d2c399ab2b632. Refused-root/archival test extension:
2dc6ed3d2ff885ad4f57d25cb2bbcb3ce098902f. All are local main commits.
No dependency, sibling API, Store schema, pending version or phase changed.

## Decision and guards

Ordinary lookup/retry retains an absent original. The separate local
acknowledgeAbsent confirmation accepts uncertainty, then repeats authenticated
original controller/principal/custody checks around an existing-only status read.
Validated not_found may resolve only that pending original through exact
whole-file CAS. It sends no mutation, cancellation, export or provider request;
it does not stop a model, refund a budget or prove that a late request/result
cannot arrive. Workspace originals remain retained until separate archival.

Running and null-result unknown remain pending. Unknown still requires the
distinct acknowledgeUnknown confirmation. A now-present preparation or settled/
cancelled attempt resolves with its checked actual outcome. Read/malformed/scope/
custody/CAS failure retains custody; other categories and paired custody refuse
before credential/transport. The panel keeps the chosen entry/action together
through its dialog and repeats busy/reload/action guards on confirmation.

## Executed acceptance

`mise exec -- mix woh.native.generation.flow.smoke` passed for both frozen
quantity families against actual SQLite Store and framed local sockets. For
preparation and attempt originals, it checked missing lookup retention, wrong
verifier/controller refusal, dropped read reply, malformed status, same-content
inode replacement between status and resolution, reload and exact confirmed
absence resolution. Stale CAS retained the entry and required reload. Resolution
kept the versioned empty v7 file, unchanged workspace and unchanged Store revision.
Each family's only provider calls remained its initial attempt and explicit repair.
A settled candidate encountered during absence acknowledgement resolved as its
actual outcome rather than being labelled absent.

The follow-up test changed Store revision after both private publications and
before forwarding preparation. The actual preparation refused resnapshot_required
and had no original status. Lookup retained it; acknowledged absence cleared only
pending. The generation model then refused workspace archive without its separate
uncertainty confirmation, and archived after that confirmation. A subsequent
explicit preparation used newly read current configuration and a fresh reviewed
identity. The proxy observed every preparation/start mutation only after matching
workspace and pending publication, with one dispatch per operation ID.

`mise exec -- mix woh.native.generation.sdk.smoke` passed 3942 codec/original-
delivery cases and default both-family Store/socket/queued-result/restart cohorts.
The actual cancelled-root first refusal retained its new attempt on lookup and
resolved after absent acknowledgement, without another provider call or revision.
Running reservations and stable unknown status after Store restart refused absent
acknowledgement; the original unknown-confirmation action remained separate.

`mise exec -- mix woh.native.pending.coordinator.smoke` passed original publication,
process restart/recovery and unsupported-action guards. The added unrelated-rule
absence action refused before capture/execution and left its file/entry intact.
`mise exec -- mix woh.native.pending.storage.smoke --generation` passed independent
v7 bytes, private guards, CAS, process crash/restart and concurrent publication;
both generation kinds allow the new local decision without encoding drift.

The initial expanded flow exceeded its previous 15-second fixture execution bound.
The added deliberate read-failure cohorts passed with a 30-second flow-only bound,
including the refused-root extension. Ordinary SDK fixtures retain 15 seconds;
the native compiler remains bounded separately. No production exchange deadline
was changed. Final formatting, warnings-as-errors compilation, catalogue and Git
whitespace checks passed. Toolchain: Elixir1.19.6 / OTP28.5.0.6; Swift6.4 on arm64
macOS27, Swift6 language mode targeting arm64 macOS15.

Logs: /tmp/home-native-generation-absent-{flow,root-race,sdk,coordinator,storage}.log.
NGS-T5 and NGU-T3–T5 have focused software evidence. Remaining selected-panel
withdrawal/expiry/unknown scenarios, signed paired generation and installed
interaction/accessibility retain their acceptance obligations. No installed app,
signed host, external model/account, storage power-loss or physical qualification
was produced. No push or repository visibility change occurred.
