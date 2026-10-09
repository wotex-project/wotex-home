# WOH.19 — Optional shared server host

Version: 0.1.0. Status: accepted target; partial development implementation, installed-host and physical evidence missing.

## Product and host choices

**H19-01.** Home has one controller runtime and three delivery choices. A
standalone Mac runs the supported core locally. An optional shared server runs
that core on an existing supported Linux machine, including a Raspberry Pi.
An optional Nerves image provides a dedicated appliance. A server is not a
prerequisite for profiles, ordinary control, rule admission or scheduling.
Hardware, operating-system support and qualified transport availability can
limit a capability; choosing standalone mode cannot impose an artificial
software feature limit.

| Choice | Execution owner | Availability | Machine ownership |
| --- | --- | --- | --- |
| Standalone Mac | Operator-enabled local OTP host | While the Mac is awake and its user service runs | Ordinary personal computer |
| Shared server | Home system service on supported Linux | While that machine, service, network and required radios run | Shares the host with unrelated applications |
| Nerves appliance | Home firmware host | While the appliance and required infrastructure run | Explicitly selected dedicated image |

Closing a control window does not stop a running controller. Sleeping, shutting
down or logging out of the standalone Mac removes its execution availability
under WOH.08. With a paired server as owner, those Mac events do not stop server
schedules. A server failure still stops server-owned work; optional hardware
is not a high-availability guarantee. Devices' own schedules may continue only
when that separately qualified device capability is explicitly selected.

**H19-02.** First shared-host delivery targets Debian 13 on arm64 and amd64
using a self-contained OTP release and a systemd system service under a
dedicated unprivileged account. Qualification records the exact OS, kernel,
architecture, libc, release and native dependency closure. Raspberry Pi is a
host candidate, not a required product identity. Pi board/radio qualification
and the Nerves Pi 4 target remain separate. Other distributions, NAS packages,
containers and macOS system daemons are later delivery profiles requiring
their own host evidence; they are not implied by this contract.

The shared service does not require a GUI, an interactive login, Docker, a
vendor account, hosted registry, distributed Erlang or an external broker.
An integration that needs a local broker or radio declares that dependency;
Home neither installs it silently nor takes ownership of a shared instance.

## Coexistence and installation

**H19-03.** Installation from a verified local artifact is one repeatable
setup operation followed by a guided controller connection and device
enrollment. Privilege is limited to installing Home-owned files, service
registration and explicitly approved device access. Runtime is unprivileged.
The installer must not flash storage, replace the host OS, upgrade unrelated
packages, change global firewall policy, start BlueZ on the operator's behalf,
or disable unrelated services. A dedicated image is a separate explicit choice
that identifies the storage it will erase before writing.

Preflight checks OS/architecture, artifact closure, writable private local
storage, available port, service identity and selected interfaces/devices before
registration. A repeat verifies the installed cohort and preserves data,
credentials and local configuration. A conflicting path, account, unit, port
or symlink fails with a concrete diagnostic rather than replacing another
owner's resource. Setup interruption leaves either the previous usable
installation or an inert, identifiable staging area. No shared default
credential or pre-enrolled home is shipped.

**H19-04.** Use one private local-filesystem Store/custody namespace per
instance; SQLite on a network share is not a supported shortcut. The system
service owns only its release, state, runtime socket, selected network
listeners and expressly assigned device handles. Immutable release files are
separate from durable state. Installation and uninstall preserve unrelated
files. Uninstall stops Home and removes registration; deleting private state
requires a separate explicit choice.

Measure and publish CPU, memory, process, disk/log and helper limits for each
qualified cohort. Enforce process/memory containment and bounded restart
backoff through host facilities in addition to application queues. Exhaustion
must preserve receipts and handoff uncertainty, stop affected work and report
degradation rather than consume the whole machine or restart without bounds.
Exact limits and service sandbox exceptions are part of the release manifest
and host guide, not an unmeasured minimum-resource promise. Other applications
can still exhaust the host or its network; Home reports that failure honestly.

A Zigbee coordinator or serial device has one transport owner. Bluetooth
adapter-wide changes, network formation, factory resets and shared broker
administration require explicit host/device ownership; discovering a device
does not acquire it. Prefer WoTEx's supported borrowed-resource mode where
available. Failure to obtain an exclusive required resource disables that
binding without taking over or restarting another application's resource.

## Controller identity and clients

**H19-05.** Every delivery uses WOH.15's Authority and WOH.14's single Store.
There is one active effect owner per home. The Mac can connect to its local
owner or a paired remote owner through the
[controller connection profile](controller-connections-v1.md). The client
shows the selected home, controller identity, location and current reachability.
It cannot quietly start a local copy to replace an unreachable server.

Moving an existing home uses the explicit fenced WOH.15/WOH.16 transfer and
recovery lifecycle, including profile bytes, pinned artifacts, credentials,
rule generations, receipts and uncertain effects. Copying a database, pairing
a client, restoring a backup or discovering an endpoint does not transfer
authority. A network partition supplies no proof that the previous owner is
retired. Automatic failover and shared writable databases are outside the
baseline. An unavailable source requires the existing reviewed isolation path;
an installer cannot invent a faster ownership reset.

**H19-06.** Health exposes service registration/running state, controller
ownership, Store readiness, maintenance, clock confidence, scheduler state,
transport/resource availability, qualification and pending/unknown effects
separately. A remote client's disconnection is distinct from a stopped server.
Information is scoped and redacted through the existing Authority permissions.
Server administration and effect authority are distinct permissions; pairing
does not grant a device write, profile approval or authority transfer.

## Offline lifecycle and support boundary

**H19-07.** After provisioned artifacts and local commissioning, normal
operation and restart work with WAN, public DNS, update servers and public time
services unavailable. Time-sensitive operations follow
[the scheduler profile](local-scheduler-v1.md), rather than treating internet
time as a hidden prerequisite. Optional update checks do not gate startup,
control or already admitted work. Signed offline release import follows
WOH.16; downloading a release does not activate it, update a profile selection
or widen grants. The host administrator remains in the trusted-computing
boundary; the service cannot protect secrets against the machine's root user.

## Acceptance

H19-T1: install, repeat, interrupt, upgrade and uninstall from local artifacts
on each qualified architecture beside an unrelated service; its files,
configuration, ports and operation remain intact. No source compiler or WAN is
required on the target. Record fresh-host evidence, not only a release build.

H19-T2: execute the same supported capability/rule corpus on standalone Mac,
shared Linux and appliance profiles through the same Authority. Missing radio
or native runtime reports a specific capability limit without imposing a
server-only software feature gate.

H19-T3: close, sleep and power off the paired Mac; admitted server work continues
with WAN/DNS blocked. Repeat in standalone mode and confirm unavailable and
missed work follows the scheduler policy, without claiming execution in sleep.

H19-T4: partition clients, start a copied Store and restore an old backup; no
second effect owner appears. Explicit transfer fences the source before a new
owner can dispatch, preserving original receipt scope and unknown outcomes.

H19-T5: contend for a coordinator, borrowed BLE resource, local port, account and
data path. Refusal/degradation does not reset the radio or displace unrelated
owners. Record exact resource ownership and physical recovery where applicable.

H19-T6: exhaust helper/process/memory/log/disk limits and induce repeated startup
failure beside another service. Bounds, restart backoff, responsive diagnostics,
durable integrity and uncertain-effect handling hold on the installed cohort.

H19-T7: reboot with WAN, registry and public time blocked; a provisioned supported
local configuration starts, clock-dependent work is explicit, offline updates
retain the maintenance/recovery boundary, and no default secret exists.

H19-T8: pair, revoke and reconnect two scoped clients; endpoint substitution,
lost mutation replies and accidental local fallback fail under H15-T8/H08-T9.

## Delivery ownership

The [local controller delivery plan](../plans/local-controller-delivery.md)
owns implementation order. Executable procedures live in the
[Linux host guide](../../native/linux/README.md). Its development arm64 payload,
independent bootstrap, inert systemd profile and
[resumable initial installation](linux-installation-v1.md) implement a bounded
subset. Updates, hard durable-state disk containment, paired LAN setup, amd64
delivery and actual installed/coexistence/physical qualification remain missing.
Accepting this target does not establish those gates or widen physical dispatch.
