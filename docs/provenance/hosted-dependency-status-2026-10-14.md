# Hosted dependency status renewal

Read-only verification on 2026-10-14 renews hosted availability separately from
the [dependency review](dependency-upgrade-2026-10.md) and subsequent local
archive/Store evidence. No dependency, remote, release or visibility was changed.

[ExBooking CI](https://github.com/futhr/ex_booking/actions/runs/38498874961)
passed at exact source 28dadcaa4ce1a806401868a7a4a0bf83761ccb8a on 2026-10-14.
That source is now hosted; its original-occurrence/timezone additions remain
outside the published 0.2.3 Hex release. It is available for an explicit future
source/archive adoption, rather than an unexplained missing producer.

[WoTEx CI](https://github.com/wotex-project/wotex/actions/runs/38375782626)
failed at 80c8b9188eef4f3414ddccc5fc913356bc50d7ae on 2026-10-13. Job and failed
log inspection identifies Decimal 3.1.1 advisory failures across package gates,
BACnet/Modbus software fixture failures, BLE source-download failure and separate
Thread, OPC UA, Matter and CoAP native lane failures. That hosted revision
predates the local dependency/harness/native fixes in fbcfc58a, 5071d546,
05c9c5bd, fc2ee2e6 and 4b686545. Current package locks contain Decimal 3.2.0;
the owning WoTEx docs/plans/dependency-refresh-2026-10.md records executed
remediation checks and outstanding native milestones. These local changes do
not establish a green hosted run. The unresolved CoAP OSV-2022-150 Git range
continues to fail its advisory gate; no suppression or unsupported clean claim
is introduced. The user performs every remote push and publication.

Direct primary registry API reads confirm [ExBooking](https://hex.pm/packages/ex_booking)
latest stable 0.2.3 and [ExMaude](https://hex.pm/packages/ex_maude) latest stable
0.5.0. The exact names wotex_profiles, wotex_runtime and wotex_routines each
return HTTP 404 from hex.pm/api/packages. Their local 0.1.0 labels and inspected
archives are not published dependency artifacts. Home keeps its existing pins
and separate exact archive consumer evidence; no runtime dependency is inferred
from neighboring checkouts or a newer sibling HEAD.

Commands executed were gh run list/view with exact run IDs, failed-log read,
local committed source/lock inspection and bounded HTTPS registry API reads.
The web reader could not open the registry API URLs, so the primary responses
were read directly. No new full package/native build or CI rerun was executed.
