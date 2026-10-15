# HTTP header dependency evidence — October 2026

The [remediation contract](../specs/http-header-dependency-v1.md) was committed
before implementation. This record establishes its bounded software cases,
not network deployment, a release build or device qualification.

## Reviewed inputs and decision

On October 15, official Hex metadata reported Cowlib 2.21.0, Gun 2.7.0 and
EMQTT 1.16.1 as latest stable releases. Locked resolution exposed
CVE-2026-43966. The [CNA record](https://cna.erlef.org/cves/CVE-2026-43966.html),
updated October 14, identifies Cowlib's encoder defect and fix commit
[4401b858f2229abb3ea115c60924f6c77e5f8aa3](https://github.com/ninenines/cowlib/commit/4401b858f2229abb3ea115c60924f6c77e5f8aa3).
It also identifies Gun 2.4.0 onward's default invalid-request-header rejection
as a client mitigation. Gun 2.7.0's actual public code retains that default.

Cowlib now uses that exact canonical upstream Git source in both locks, with
an explicit transitive override. Its unchanged declared version is 2.21.0.
The six upstream commits since that release update erlang.mk, accept zero
content-length on 204 responses and percent-encoded Host values, adjust a
content-range property generator, and implement RFC 9651 structured-field
parsing/canonical serialization. The selected encoder's relevant final clause
accepts only bytes 32–126. No local fork or patch is introduced.

Gun remains the same exact released Hex 2.7.0 artifact. The only acknowledged
advisory is GHSA-w4f7-4cxr-rv3c, justified jointly by the patched encoder and
tested client mitigation. Root and firmware `mix hex.audit` both exit zero
while explicitly listing **one ignored Gun advisory**, with no other finding.
This is a documented acknowledgement of a registry finding, not a claim that
the advisory has disappeared or that Git dependencies receive Hex advisory
coverage. The fixed source/lock and executable tests supply separate coverage.

## Executed evidence

Root used Elixir 1.19.6 / OTP 28.5.0.6; the native/nerves host bootstrap used
its own pinned OTP 29.0.4 with Elixir 1.19.6-otp-28. All commands retained
`WOTEX_HOME_GIT_DEPS=1`; native commands used `MIX_TARGET=host` and
`EX_MAUDE_BUILD_CNODE=0`.

- Root and firmware `mix deps.update cowlib`: passed; only Cowlib's lock entry
  changed at this step. Other package versions were retained.
- Firmware `mix deps.get --check-locked`: passed.
- Root and firmware `mix hex.audit`: passed with the single explicit
  acknowledgement described above.
- `mix test test/wotex_home/http_header_dependency_test.exs test/wotex_home/producer_cohort_test.exs test/release_components_test.exs test/isolated_smoke_test.exs --warnings-as-errors`:
  **19 passed**, seed **280119**. Four new cases check fixed paired locks and
  exact acknowledgement, all 161 forbidden bytes in four string positions,
  all 95 printable bytes and quote/backslash escaping, plus synchronous Gun
  CR/LF/NUL name/value rejection before any process cast and valid cast controls.
  Existing legal/source/profile/MQTT/staging fixtures also pass.
- A separate isolated VM compiled only the actual released Cowlib structured
  header module from the retained exact Hex archive
  `0960248773762a5319b3c17285028bc76f54f58ef0f9451367401bdf67b46274`.
  The literal string `before\r\nafter` returned CR/LF inside serialized header
  bytes, confirming the old counterexample. No socket or packet was used.
- Root `mix compile --warnings-as-errors` and scoped formatting passed.
  Cowlib's erlang.mk prints a GNU Make 4 upgrade warning on this Mac; compilation
  succeeds. Native EMQTT bootstrap also prints upstream OTP deprecation warnings.
- `git diff --check`: passed.

Retained identities after this remediation:

| Input | SHA-256 |
| --- | --- |
| root mix.lock | ae70114ab7789eb98446a7792d5db516ed1936be08d1b894259dd2492bb2c2a7 |
| firmware mix.lock | 1656b599b6e6f115e79a9450df87575e5fdc218c8c37b6e0ad9cfed99a5b62c8 |
| selected cow_http_struct_hd.erl | 69a5d5b3c41a562489532bfb7385801fcefa6e47cbc0a6a9675cdc4105686ab7 |
| Cowlib LICENSE and Gun LICENSE, each | edb14e8a204b4ef3d5d7ce75e553126e3bd58dc5342decedc3fbf0d2bd023098 |

The existing release legal step copies those actual license bytes; its fixtures
pass with the new checkout. No full suite, Dialyzer, firmware image or release
assembly ran for this slice. Private counterexample and test fixture directories
were removed. Dependency/build caches remain for subsequent focused development;
no Docker or standalone generated documentation artifacts were created.

Revisit the exact source and acknowledgement when a fixed Cowlib release or
corrected advisory metadata is published. The strict cohort test requires an
explicit review for source/version or acknowledgement changes.
