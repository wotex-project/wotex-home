# Local controller and extensibility research

Version: 0.1.0. Updated: 2026-10-07. Decision research and source audit; no runtime, installation or hardware evidence is established here.

## Question and result

Can one simple, locally owned product control supported home devices, let an
operator add sensors without modifying the application, and optionally move
execution off a laptop without requiring a dedicated Pi or a cloud?

Yes, with explicit layers: WoTEx protocol mechanics; immutable device mapping
data and optional isolated decoders; Home capability semantics, Authority,
Store and admitted scheduler; then host delivery and clients. The Mac is a
complete supported controller while available. A shared server provides another
execution location and resources; a Nerves image is an optional appliance.
Moving a home requires fencing its previous owner. Device scope can be open
without promising that descriptions erase protocol, firmware or safety gaps.

The decisions are recorded in [the delivery plan](local-controller-delivery.md),
[WOH.19](../specs/WOH.19-shared-server-host.md) and the owned
[mapping](../specs/device-profile-mappings-v2.md),
[scheduler](../specs/local-scheduler-v1.md) and
[connection](../specs/controller-connections-v1.md) profiles.

## Evidence discipline and local sources

Inspection used sibling working trees read-only. HEAD identifiers below locate
the observed source cohort; concurrent/uncommitted work and prose status are
not a locked dependency selection or consumer qualification. Home's main build
continued independently during this research. Existing locked dependencies
were not changed. Producer target, implementation, Home integration and physical
qualification are four separate claims.

| Repository / observed HEAD | Sources inspected and disposition |
| --- | --- |
| Home `b10e7ff9b96033efbb26c592d38130c44ad978e8` | README, catalogue, WOH.00/01/03/04/08/09/14–18, plans, capability/profile/binding code and native local client. Current portable data is a single LIFX power binding; vocabulary is Light/SmokeDetector; explicit rule invocation exists but autonomous timers/edges do not. UDS client and development appliance are not paired LAN delivery. |
| WoTEx `c8c727a7c8c18fec82d80cc5ba88d246af3c67fc` | Root and Zigbee/MQTT/BLE/Matter package guides. Reusable protocol lifecycle/values stay upstream. Zigbee ZNP/ZDO/ZCL code does not supply Home network formation/key custody. MQTT command plans require a consumer connection owner. Current native BLE targets Linux BlueZ, not Mac CoreBluetooth. Matter software peers are not a Home physical controller/bridge qualification. |
| Orvane `f16a4eb0fcfedd3284928345f0cbbcea7d682d71` | `CN.00`, `CN.06.01`, `TH.21`, `TH.21.01`, `IG.17` and codec sources. Adopt direction/lifecycle/security/evidence binding descriptors, immutable recipes and typed property provenance. Its planned binding registry and external Refpath integration are not implemented merely because specs describe them. QuickJS source exists, but advertised broader quotas/containment are unfinished; do not copy an in-process untrusted codec model. |
| Refpath `df6b47e62512df87108a937d8fbace52e9a28d37` | Plugin specs 00/13/14, portable authoring, worker plugin guide, RT.80/SY.23 and artifact-layout verifier. Reuse the separation of native bundled plugins, inert data, independently delivered executables, trust and execution authority. Bounded artifact tools exist; complete worker installation/broker/runner integration is still partial/planned. No mandatory Refpath engine or runtime BEAM loading is inferred. |
| Frameshift `efcfdd56c6cff4e844aa4eb4eea5de64ab2b3c12` | Capability architecture, producer-contract ledger, decisions and README. Adopt capability-oriented WoT affordances, unknown-required-contract rejection and exact producer/consumer qualification. Content data and application/native runtime are distinct. Its window-owned lifetime does not meet Home's background scheduling requirement. |
| Conjunct `299c332d9b3c7f054eb234d36f3e24e83b43402f` | README, CJ.03 pack format, CJ.09 language/selection contracts. Adopt immutable closure and distinct pack/executable/runtime/application/effect identities. Its passive, clock/I/O-free kernel is a semantics precedent, not a home device driver or service host. No new dependency is justified. |
| RPOS `16d0ce59bb724dd164d2a82e2e8a0007d157488b` | Boot/install/enrollment, network/offline, update/recovery specs and README. Borrow separate immutable code/persistent state, unique enrollment, offline closure and explicit activation/recovery. These are draft institution/OS targets, not installed Home facilities. Its x86/UEFI/TPM/VM policy is disproportionate to an optional shared home service and does not establish Pi support. |

## External primary sources

Sources checked on the date above; mutable implementation examples require an
exact source pin when adopted. The implications below are Home design choices,
not upstream endorsement or compatibility evidence.

| Source | Finding and Home implication |
| --- | --- |
| [W3C TD 1.1](https://www.w3.org/TR/wot-thing-description11/) | Properties/actions/events/Forms and Thing Models describe interfaces/templates. Description does not implement a protocol or grant control. Consume WoTEx values rather than build another TD parser. |
| [openHAB Things/channels](https://www.openhab.org/docs/concepts/things.html) | A Thing can have multiple typed channels. Use shared capability presentation rather than one branch per model. |
| [Zigbee2MQTT external converters](https://www.zigbee2mqtt.io/advanced/more/external_converters.html), [new-device support](https://www.zigbee2mqtt.io/advanced/support-new-devices/01_support_new_devices.html) | Reusable standard feature mappings make model additions cheap; proprietary deviations still need code. External JS converters are executable extensions, not inert profile data. Home's smaller data grammar needs an isolated decoder escape boundary. |
| [ZHA device handlers](https://github.com/zigpy/zha-device-handlers/blob/dev/README.md) | Manufacturer deviations require quirks despite a standard protocol. Fingerprints alone do not prove a decoding model. |
| [Z-Wave JS device configuration](https://github.com/zwave-js/zwave-js/blob/master/docs/config-files/file-format.md) | Device identity, endpoint and compatibility/configuration data can evolve separately from the protocol engine. Apply this pattern without claiming a Home Z-Wave driver. |
| [HA MQTT discovery](https://www.home-assistant.io/integrations/mqtt/#mqtt-discovery) | Local descriptors can introduce multi-component devices and availability/state topics. Home treats discovery as a proposal; retained state is not a fresh physical event or enrollment grant. |
| [ESPHome packages](https://esphome.io/components/packages/), [external components](https://esphome.io/components/external_components/) | Reusable configuration is distinct from Python/C++ code generation and device firmware. Useful DIY sensor path; it does not eliminate the host API/binding or install arbitrary controller code. |
| [BTHome format](https://bthome.io/format/), [SenML RFC 8428](https://www.rfc-editor.org/rfc/rfc8428) | Standard measurement IDs/representations reduce custom mappings. Transport security, units, source freshness and unsupported fields still need explicit consumer policy. BTHome remains a candidate, not admitted Mac BLE support. |
| [HA Matter integration](https://www.home-assistant.io/integrations/matter/) | Thread and Matter are different layers; standard projection may omit vendor features. Matter is an additional local integration, not a replacement for every profile or radio. |
| [WIT](https://component-model.bytecodealliance.org/design/wit.html), [Wasmtime security](https://docs.wasmtime.dev/security.html) | Typed worlds and restricted host imports support pure decoder isolation. Types do not specify behavior; guest linear memory does not bound all native host allocation or child retirement. Qualify containment before production. |
| [Apple launchd lifecycle](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html) | Per-user agents end at logout. A background window-independent service does not make a sleeping/off Mac an always-on hub. Keep the current per-user choice and disclose availability. |
| [Debian 13](https://www.debian.org/releases/trixie/), [systemd service](https://github.com/systemd/systemd/blob/v257/man/systemd.service.xml), [resource control](https://github.com/systemd/systemd/blob/v257/man/systemd.resource-control.xml) | A supported arm64/amd64 OS and unprivileged system service can coexist with unrelated jobs. Service restart and cgroup resource bounds need explicit settings and actual installed tests. No measured Home minimum follows from these docs. |
| [Nerves getting started](https://nerves.hexdocs.pm/getting-started.html), [HA installation choices](https://www.home-assistant.io/installation/) | Dedicated appliance images and application/container deployments solve different ownership needs. Retain Nerves and add a native shared service; containers remain optional future delivery profiles. Home does not need another product's supervisor. |
| [Raspberry Pi RTC documentation](https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#real-time-clock-rtc) | Clock hardware is model/configuration dependent. A Pi label alone cannot establish offline time accuracy. Qualify RTC/local time or require explicit local clock setup; do not silently require public NTP. |
| [RFC 5545](https://www.rfc-editor.org/rfc/rfc5545) | Recurring nonexistent times are omitted; repeated local times have defined interpretation. Home chooses a narrow visible DST policy, rather than accidentally inheriting a library's full calendar semantics. |
| [TLS 1.3 RFC 9846](https://www.rfc-editor.org/info/rfc9846/), [service identity RFC 9525](https://www.rfc-editor.org/info/rfc9525/), [DNS-SD RFC 6763](https://www.rfc-editor.org/rfc/rfc6763) | Use standard encrypted transport with invited identity and explicit certificate checks; discovery is only location. Disable early data and preserve application idempotency. RFC 8446 has been superseded; the adopted TLS cohort still needs implementation interoperability. |

## Alternatives and decisions

| Decision | Chosen path / reason | Alternatives and condition to reconsider |
| --- | --- | --- |
| Controller location | Mac standalone plus optional shared Linux service and optional appliance; same supported core | Mandatory Pi excludes the stated use case. Mac-only cannot execute while off. Active-active/failover cannot fence unauthenticated actuators during partitions. Reconsider failover only with a separately proved physical fencing mechanism. |
| Shared-host packaging | Native self-contained OTP release first; limited service registration and resource ownership | Mandatory Docker adds another required lifecycle for no established benefit. A container can follow when its device/network/credential/update closure is qualified. Nerves/RPOS image replacement remains an explicit dedicated-host choice. |
| Device adaptability | Standard selectors + host-owned channel semantics as data; optional typed decoder for real quirks | Fixed brand tables force rebuilds; unrestricted scripts give device authors ambient host power. If two independent standard sensors cannot be added with the proposed grammar, refine the data binding before adding a general plugin framework. |
| Semantics | Shared capability contracts, exact units/provenance and explicit risky-load semantics | A universal ontology or vendor Device Type cannot replace authority or physical evidence. Unknown optional metadata is inert; unsupported required meaning needs review. |
| Executable reuse | Keep the optional pure component boundary; evaluate public Refpath pieces only for a demonstrated missing mechanism | Adopting the whole engine now couples Home to incomplete consumer integration. Native SDK/stream adapters need their own reviewed upstream/isolated contract, not additional pure-decoder imports. |
| Scheduler | Durable occurrences within existing rule/effect admission, local clock confidence and default skip | OS cron/Swift timers split authority; replay on wake can repeat unsafe effects. Catch-up requires a separately proved bounded absolute-effect profile. |
| Remote control | Explicit out-of-band identity invitation, TLS and existing scoped bearer/receipt semantics | LAN location/first-user-wins discovery is not authentication. A short code needs a vetted PAKE before it can replace the private invitation. Cloud relay and Internet-facing listener are outside the baseline. |

## Iteration and counterexample review

Pass one inspected implementation against product claims: the existing data
path and Mac/Nerves packaging cannot yet deliver arbitrary sensors, autonomous
schedule execution or remote control. Those gaps are now planned successors,
without upgrading catalogue evidence.

Pass two compared sibling ownership and external alternatives. It removed the
assumptions that a server needs its own OS, that a portable description supplies
protocol support, or that a sibling executable verifier implies a Home runner.
It selected shared-service packaging and data-first capability mapping.

Pass three traced failures through the existing durable boundary: Mac sleep,
lost remote replies, clock/DST changes, shared-radio contention, retained MQTT
messages, profile grant widening and copied Stores. The resulting contracts
require skipped missed occurrences, current time/grant checks at handoff,
original receipt scope, explicit resource ownership and source fencing. A
server never becomes an automatic local fallback or a silently reactivated
backup. A fourth consistency pass separated ordinary same-owner restart from
transfer/restore: unattended restart may resume only a revalidated retained
schedule, with fresh current effect guards and skipped missed work. It also
made sensor representations exact, occurrence windows exclusive at their end,
and whole-set arbitration independent of batch/timer order; prolonged downtime
uses bounded summaries instead of an unbounded missed-tick backlog. Public
time/registry services and optional decoder engines are removed
from normal-operation prerequisites.

The design is settled enough for ordered implementation. Exact new wire/schema
encodings, native TLS/time/resource settings and physical cohorts remain
explicit entry/exit obligations in the plan. They cannot be honestly resolved
by more desk research or claimed as completed qualification.

## Documentation validation

`mix woh.spec.check` passed for all 20 contracts using Elixir 1.19.6 and
OTP 28.5.0.6 with `WOTEX_HOME_GIT_DEPS=1`. A local reference check covered 133
links in 29 documents with no missing paths; `git diff --check` passed, and
`mix.lock`/`.tool-versions` were unchanged. Initial cache compilation emitted
dependency deprecation warnings in NxSignal/Bumblebee and a missing optional
OpenJDK linker search-path warning; the task completed successfully and its
repeat passed without rebuilding. No application suite, installed service,
firmware or hardware qualification was run for these documentation changes.
