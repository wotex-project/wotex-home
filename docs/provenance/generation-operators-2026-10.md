# Generator operator software evidence

Recorded: 2026-10-14. Contract:
[authenticated generation operators](../specs/generation-operators-v1.md).
Runtime: 1030f640ec96aeb00c16fe63b2fae828c5008cc3 on local main.
The contract and independently allocated wrapper/policy vectors preceded code
in 738d39e.

## Source and executed scope

Authority/Store expose actor-scoped generation policy metadata; the private
Server forwards unchanged preparation/attempt/status/cancellation inputs.
Exchange classifies lost mutation replies as uncertain. CLI reads bounded
private originals, verifies generation-specific responses and names the exact
recovery operation after uncertainty. GenerationOperator is a pure closed
response/policy checker; it has no file, provider or Store port.

The frozen options/wrapper fixture is
test/fixtures/profiles/generation-operators.json, raw SHA-256
6e91c116d6f7f7d062a68af09e59e70019f64f64bf9a459f93028bd97a6c2320.
Python explicit field allocation used the independently frozen policy/input
vectors, without Home or BEAM invocation. Actual socket preparation receipts
match every frozen operation/projection/policy field; the historical frozen Home
basis is intentionally checked separately against the actual installed contract
basis, rather than relabelled as current.

Consumed core/Runtime/Profiles source remains
ba8ea373244ce57987f47a731b8eca3ccae9b45f. No dependency, receipt encoding or schema
changed; root mix.lock SHA-256 remains
3372ef86b264343efeedea270b3a8d0548650898043aa0e360daba46c7aaf184.
Checks used mise Elixir 1.19.6 / OTP 28.5.0.6 on macOS and current schema 37.

## Executed checks

The final affected run passed **41 tests, zero failures, 20.4 seconds**:

```
mise exec -- mix test test/wotex_home/generation_operator_test.exs \
  test/wotex_home/generation_operator_codec_test.exs \
  test/wotex_home/authoring_operator_test.exs \
  test/wotex_home/local_api_route_test.exs \
  test/wotex_home/local_api_exchange_test.exs \
  test/wotex_home/local_api_peer_identity_test.exs \
  test/wotex_home/cli_test.exs
```

New suites contribute eleven actual Store/process/socket/filesystem cases and
five pure response/metadata cases. No socket-free exclusion was used. Root
formatting, warnings-as-errors compilation, catalogue checking (22 workspace
contracts matched), full HTML ExDoc with warnings-as-errors and Git whitespace
checks passed. Host guides now document the commands and current disabled
installation boundary. No Swift, firmware or release artifact was rebuilt.

Raw synthetic logs are /tmp/home-generation-operator-final.log and
/tmp/home-generation-operator-docs.log. Earlier runs exposed only fixture issues
(missing context root, an invalid cancellation wrapper and comparison of an old
frozen basis to the current basis). The single-link file case established the
new original-reader requirement; CLI now checks it by descriptor before/after
reading, with existing non-generation file behavior preserved. The shared socket
credential decoder now explicitly enforces the existing canonical 43-byte
unpadded bearer encoding.

## Acceptance correspondence

GO-T1 checks both quantities' independent actor-only options, empty foreign
installation, missing provider/producer/custody, native policy digest
reconstruction and unchanged revision/call count. Process presence remains a
declaration rather than model/schema/capacity readiness.

GO-T2 runs actual private Unix sockets and CLI files for both families' prepare,
start, preparation/attempt status, candidate metadata and cancellation. A separate
explicit CLI repair sends exactly the previous invalid draft and encoded report;
compatible mechanics still reports source_review not_assessed and fixture_status
not_supplied. Original start replay sends no second provider call.

GO-T3 forwards an actual request to the real endpoint and drops its reply after
prepare/start/cancel. CLI exits 3 with the correct recovery command, original
status resolves the result and exact retry preserves the original. Endpoint
restart retains the Store-owned running attempt; it neither renews nor resumes
the provider. A suspended Store test lets the 150-ms exchange budget expire,
then resumes the queued original: it can still commit once. Transport loss
therefore remains uncertainty, and exact retry does not call the model again.

GO-T4 checks foreign/unprivileged/revoked operators, extra wrapper fields,
floating version/revision, padded credential and duplicate frame members. CLI
file cases reject wrong mode, symlink, hardlink, duplicate JSON and 131073-byte
preparation file before connection. Existing common frame/parser and peer checks
remain in the affected suites. No rejected operation changes the revision or
provider call count.

GO-T5 checks stopped Store mutation/read classification without raw logs,
malformed fake-peer wrappers with private canaries and mismatching receipt SHA,
and closed pure response mutations: member, actor policy binding, identity,
revision, hash, status/result/cancellation relation, ordering and unknown fields.
Malformed mutating replies are unprinted/exit3; malformed reads are
unprinted/exit1. Valid missing original retains exit4; other exit meanings remain.

## Remaining delivery and qualification

Fixtures use scripted local provider processes and contact no external model.
Trusted immutable provider/export-policy installation, provider-specific
authentication/confinement, native generation UI and signed paired delivery
remain successors. Ordinary host generation remains disabled. Full aggregate
attempt pool, full hosted suite, installed signing, storage power-loss and
physical qualification remain their separate milestones. These operator checks
create no device, profile approval, rule activation or dispatch authority.

All commits are local on main; no refs were pushed. Unrelated research/audio
drafts and local client settings were preserved.
