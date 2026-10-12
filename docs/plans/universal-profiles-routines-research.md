# Universal profiles, behaviours and routines

**Research date:** 2026-10-12  
**Status:** consolidated research and proposed implementation plan; not a change to normative specifications or runtime behaviour.  
**Research branch:** `routines`  
**Home baseline:** `c73d7ac50d64cbae3fa3000184d47a136e70d3a2`  
**Scope:** universal WoTEx mechanisms, direct ExBooking and ExMaude reuse, and Wotex Home as a proving consumer.

> **Architectural decision: exclude Refpath completely from this plan.** There is no Refpath dependency, package wrapper, booking facade, planner, deployment requirement or implementation milestone. The reusable foundations are WoTEx, `ex_booking` and `ex_maude`. Ordinary control and admitted routines must not depend on an LLM, a vendor cloud or an internet connection.

This document consolidates the device-integration research and the subsequent decision to build universal profiles and behaviours rather than one-off household scripts. It supersedes earlier research suggestions that inserted an unrelated AI engine, introduced a second device-description format, or treated existing Home scheduling and verification work as absent.

Research examples below are **proposed shapes**, not accepted production input. Where a source describes tests, that is attributed source evidence: this research did not execute those tests or qualify physical hardware. Unknown model details remain unknown. No private network addresses, device identifiers, QR payloads, credentials or household photographs are included.

## Contents

1. [Decisions and boundaries](#1-decisions-and-boundaries)
2. [Verified repository baseline](#2-verified-repository-baseline)
3. [Standards and alternative designs](#3-standards-and-alternative-designs)
4. [Package architecture](#4-package-architecture)
5. [Universal profile contract](#5-universal-profile-contract)
6. [Observations, units and sensor semantics](#6-observations-units-and-sensor-semantics)
7. [Universal behaviour and routine model](#7-universal-behaviour-and-routine-model)
8. [Scheduling and direct ExBooking reuse](#8-scheduling-and-direct-exbooking-reuse)
9. [Behaviour analysis with ExMaude](#9-behaviour-analysis-with-exmaude)
10. [Durable execution and authority](#10-durable-execution-and-authority)
11. [Protocol and package changes](#11-protocol-and-package-changes)
12. [Device inventory and integration decisions](#12-device-inventory-and-integration-decisions)
13. [HomePod and Google voice reuse](#13-homepod-and-google-voice-reuse)
14. [Proving workflows](#14-proving-workflows)
15. [Security, privacy and supply chain](#15-security-privacy-and-supply-chain)
16. [Home interface and observability](#16-home-interface-and-observability)
17. [Migration and implementation work packages](#17-migration-and-implementation-work-packages)
18. [Conformance and acceptance](#18-conformance-and-acceptance)
19. [Open questions and decision records](#19-open-questions-and-decision-records)
20. [Source register](#20-source-register)

## 1. Decisions and boundaries

### 1.1 Universal means reusable semantics, not universal authority

A routine must address capabilities and declared behaviours rather than brands, rooms, protocol bytes or particular applications. A sensor supplies observations; an actuator exposes effects; a remote supplies events; a bridge supplies topology and transport; a media device exposes sessions and playback. These are different roles that can coexist on one device.

A universal library must not become a hidden global controller. Each consumer still owns its identities, authoritative state, credentials, storage, clocks, supervision and authorization decisions. Home remains one such consumer, with its existing single Authority/Store boundary. Another consumer can use the same routine representation and interpreter without importing Home, a household ontology or Home's SQLite schema.

This preserves the existing WoTEx ownership contract rather than replacing it with a mandatory platform server. See [R1], [R2], [R3] and [R4].

### 1.2 Reuse the existing standards and code

The universal description foundation is **W3C Thing Description 1.1 and Thing Model 1.1**, already represented by WoTEx. Do not invent a competing Wotex Device Profile language that repeats Properties, Actions, Events and Forms. Behavioural metadata and profile-admission rules are explicit WoTEx/consumer extensions, not new W3C vocabulary. [R3][R4][S1][S2]

Reuse `wotex-continuum` for compatible exchange values before adding new observation, intent, result or evidence envelopes. It already distinguishes inert values from persistence and dispatch authority. Its wire-schema versions are independent of package versions. [R5]

Reuse Home's source-bound rule compiler, three-valued predicates, current guards, receipts, profile lifecycle and scheduler contracts. Extract generic mechanisms through public interfaces; do not add an alternative executor alongside them. [R6][R7][R8][R9][R10]

### 1.3 Responsibilities

| Component | Responsibility | Must not own |
|---|---|---|
| WoTEx core | TD/TM values, parsing, validation and derivation | Household policy, timers, a database or automatic discovery |
| WoTEx Runtime and bindings | Form selection and bounded protocol interactions | Consumer authorization or claims of physical completion |
| WoTEx Continuum | Versioned portable exchange values | A second authoritative event store or effect dispatcher |
| Proposed opt-in WoTEx routines package | Behaviour contracts, source/IR, deterministic decisions, temporal integration and consumer-host interfaces | A mandatory storage engine, vendor-specific commands or global mutable authority |
| `ex_booking` | Pure temporal, interval, availability and resource decisions | Clock ownership, jobs, persistent reservations or physical effects |
| `ex_maude` | Generic rewriting/search infrastructure and attributable analysis results | Device credentials, automatic activation or undocumented proof guarantees |
| Wotex Home | Household UI, policies, reviewed device mappings and authoritative execution | The only implementation of reusable routine semantics |

The table is the target ownership decision. The new routines package is proposed, not an existing package claim.

### 1.4 Fixed exclusions

No mandatory AI, external workflow service, MQTT broker, Kubernetes, cloud account, separate profile registry or dedicated appliance is introduced. Optional transports and hosts remain optional. No estimated completion percentages, invented development durations or release-stage promises are used in this plan.

No schema-only validation, publisher signature, protocol acknowledgment, successful search call or integration-library README can substitute for current authorization and the evidence appropriate to a physical effect.

## 2. Verified repository baseline

### 2.1 Source snapshots

| Repository | Revision inspected in this research chain | Relevance |
|---|---|---|
| `wotex-project/wotex-home` | `c73d7ac50d64cbae3fa3000184d47a136e70d3a2` | Existing Home semantics and implementation plan |
| `wotex-project/wotex` | `80c8b9188eef4f3414ddccc5fc913356bc50d7ae` | Current upstream package boundaries and targeted native packages |
| `futhr/ex_booking` | `212cffa61e32b596f7a19d5a830ff64f39e830e1` | Pure API, availability expansion and recurrence source |
| `futhr/ex_maude` | `2c61558fc541fa1aacf7c81e40510cb49108528a` | Current public generic and IoT APIs |
| ExMaude consumed by Home | `dc41e3331c025ce77ddcaf87883425c997d69af8` | Home's actual dependency pin, not the current upstream head |
| WoTEx UDP consumed by Home | `dde1837f03f88a847ba5a0ec4479711a5ff1cf96` | Home's actual UDP dependency pin |

The dependency pins come from Home's `mix.exs`. Reading a newer upstream head does **not** authorize updating those pins or transferring existing qualification. [R2]

This was a targeted source and specification review, not an exhaustive execution of every package's test suite. The package graph was inspected across the family; detailed follow-up focused on existing Home boundaries, Continuum, BLE, Matter, ExBooking and ExMaude. Each implementation work package must reconcile its complete owning catalogue and code at the revision actually used.

### 2.2 What already exists, and what must not be claimed complete

| Area | Existing baseline | Remaining boundary |
|---|---|---|
| Application authority | One Home application and single durable Store; immutable operations and current guards | Generic extraction must preserve that ownership |
| Semantics | Capability and unit contracts, scenes and three-valued observations | Current executable vocabulary is narrower than the universal target |
| Scheduling | `local-scheduler-v1.md` explicitly specifies calendar, intervals, countdowns, clock confidence and occurrence identity | Its header distinguishes implemented pure arbitration from planned autonomous scheduling and temporal admission |
| Rules | Source-bound compiler/IR, negative model projection and a restricted explicit Boolean-light admission path | General sensor-triggered, temporal, multi-step and composed execution are not granted by those subsets |
| Arbitration | Pure whole-Thing proposal-set correspondence | Does not prove that a scheduler collected the complete current active set |
| Device profiles | Inert import, custody, local approvals, selection/history and native/shared operator flows under WOH.18 | Broader multi-channel mappings, some host boundaries and physical evidence remain separate |
| Extension helpers | Optional WIT/component work with an unqualified preview boundary | No requirement for Wasm in ordinary profiles or routine source |
| LIFX | Local protocol codecs, observations and a guarded direct-power execution structure | Physical dispatch qualification remains a separate gate; current default-disabled behaviour is preserved |
| Hue | Verified HTTPS read subset and bounded resource projection | Enrollment, event-stream continuity and guarded writes are separate work |
| Matter | Home has pure export/command/report proposals; upstream has a substantial native controller implementation | Consuming a Matter device is not hosting an exposed bridge; server/export and ecosystem qualification remain distinct |
| Native hosts | macOS background service/client and optional shared Linux/Nerves direction | Native/macOS BLE support cannot be inferred from a Linux BlueZ backend |
| ExBooking | Independent deterministic library | Not currently a Home dependency; no autonomous job runner is supplied |
| ExMaude | Already a pinned Home dependency | Current negative checks are not a complete positive temporal/composed proof |

Sources: [R1]–[R12]. In particular, the earlier statement that scheduling could not be found was incorrect. Empty GitHub code-search results did not establish absence.

### 2.3 Reconcile prior research before implementation

Earlier research overstated or misplaced several responsibilities. This document makes the corrections explicit:

* Do not create another device-description parser: use existing TD/TM support.
* Do not create another exchange model without reconciling Continuum.
* Do not replace the Store with a generic workflow database.
* Do not route Home through an unrelated booking wrapper: call ExBooking directly.
* Do not label an absolute set operation automatically safe to repeat after uncertain dispatch.
* Do not infer a universal minute/second freshness default for every sensor.
* Do not equate Bluetooth support with native macOS Bluetooth support.
* Do not equate a HomePod Thread border router with a generic BLE gateway, Zigbee coordinator or exported sensor server.

## 3. Standards and alternative designs

### 3.1 Standards selection

| Standard or design | Use here | Boundary |
|---|---|---|
| W3C WoT TD/TM 1.1 | Authoritative affordance and reusable interface description | Not the routine executor or authorization policy [S1][S2] |
| WoT Forms and protocol bindings | Preserve transport-specific interaction information below semantic routines | A supported Form is not evidence that a physical model is qualified [R3][R4] |
| ETSI SAREF | Optional semantic annotations and cross-domain terminology | No online ontology lookup needed to run a routine [S3] |
| IETF SenML | Measurement interchange and unit vocabulary where useful | Not a complete device, actuator or authority model [S4] |
| OGC SensorThings Sensing | Optional export/import for observations, datastreams and features of interest | Not a replacement for actuator admission or the local Store [S5] |
| Matter device types/clusters | Consumer and export projections | Matter is not the internal universal capability ontology [R10][R12] |
| Zigbee ZCL, BLE GATT, OPC UA and industrial protocols | Source semantics and transport mappings | Protocol fields do not directly become user-authorized capabilities [R3][R4] |
| RFC 5545 | Recurrence interoperability and calendar edge-case reference | Current Home and ExBooking each support narrower explicit subsets [R6][R13][S6] |
| CloudEvents | Optional external event envelope | An event ID is not a command receipt, physical causation proof or authorization [S7] |
| SCXML | Reference for hierarchy, parallel states and transition ordering | Do not adopt arbitrary script execution or replace the existing IR without a demonstrated need [S8] |

A general JSON Schema validator for a WoTEx extension manifest must not silently redefine the DataSchema dialect used by TD 1.1. Keep TD/TM validation and any closed extension-manifest validation separately versioned. Unknown annotations can be preserved as inert metadata where the standard requires interoperability; unknown executable semantics remain unavailable.

### 3.2 Runtime alternatives

Home Assistant's explicit execution modes are useful product references: overlapping runs can be rejected, queued, restarted or run in parallel. WoTEx should define those behaviours with durable occurrence and effect semantics rather than copy a mode name without defining cancellation. [S9]

Temporal's durable workflow model is a useful comparison for immutable execution history and recovery. It is not selected as a mandatory service: Home already owns authoritative storage and command settlement, and introducing another orchestrator would require resolving duplicate persistence and authority. [S10]

Oban's cron plugin is a valid Elixir scheduling mechanism, but cron job insertion does not by itself implement Home's clock-confidence windows, source/profile admission, physical-uncertainty rules or device-owned timers. Reuse ExBooking's calculations and the existing Store boundary first. A host may later supply an alternative wakeup driver only if it passes the same host contract. [S11]

Do not replace the existing three-valued expression language with a second CEL/JSONLogic/script language merely for familiarity. A future translator must define its accepted subset, reject unsupported semantics and prove agreement with the same IR. General-purpose scripts introduce another execution and review boundary; they are not needed for universal routine composition.

No CRDT or distributed consensus layer is needed to arbitrate one household's physical effects. Replicated read models may be useful later. Distributed writers require an explicit fencing/ownership protocol and cannot be justified by convergent state alone.

## 4. Package architecture

### 4.1 Proposed dependency direction

```text
Consumer application: Home, lab application, industrial application
  |
  +-- owns Store / authority / credentials / clock / dispatch / UI
  |
  +-- opts into proposed wotex-routines
  |     +-- reusable behaviour contracts and routine compiler/interpreter
  |     +-- direct ex_booking temporal/resource calculations
  |     +-- wotex and wotex-continuum public values where appropriate
  |     +-- optional ex_maude analysis adapter and host-owned worker pool
  |
  +-- uses wotex-runtime and explicitly selected protocol packages
        +-- HTTP / MQTT / CoAP / BLE / Matter / Zigbee / UDP / industrial
```

`wotex-routines` is a proposed package name, not an existing dependency. Begin with one coherent optional package rather than many new micro-packages. Split a verification adapter only when independent packaging has concrete value. Neither the base `wotex` package nor every protocol package should depend on ExBooking or Maude.

Adding the package requires updating the actual package graph, tooling catalogue, archive-consumer checks and dependency rules. It must not silently violate the current sibling-boundary policy. New code uses public sibling APIs, not Home's private modules or a sibling's hidden functions. [R4]

### 4.2 Consumer-host boundary

The generic kernel produces decisions from explicit immutable inputs. The host validates and commits them against current state. Suggested interface responsibilities, **not current API names**, are:

```text
compile(source, capability_basis) -> canonical program or typed errors
consider(program, event, snapshot, time_basis) -> bounded proposal
advance(run, admitted_fact_or_receipt, snapshot) -> bounded transition
host_commit(expected_basis, transition) -> committed result or stale basis
host_dispatch(committed_effect_reference) -> existing guarded device path
```

The host contract must include authorization, complete active-set selection, revision checks, occurrence reservation, command-root accounting and durable outcome recording. A callback that simply returns `:ok` is not a conformance demonstration.

The optional driver returns a child specification. Loading the library must not start timers, read application environment, discover devices or access a filesystem. A consumer can run the pure kernel in a simulator without any device transport.

### 4.3 Data ownership remains singular

For Home, all authoritative transitions continue through `WotexHome.Authority` and the single Store. The generic package receives bounded values, not the Store's SQLite handle. There is no dual writer and no second scheduler database.

Existing Home protocol workers keep custody of sockets, BLE sessions and credentials. A routine step cannot choose a raw address, inject packet bytes or obtain a generic unrestricted transport client.

## 5. Universal profile contract

### 5.1 Separate five artefacts

| Artefact | Purpose | Authority |
|---|---|---|
| Reusable Thing Model | Interface for a capability/device family | Defines affordances, not trusted physical support |
| Concrete Thing Description | Actual exposed interactions and Forms | Describes reachability/security requirements; not an enrollment grant |
| Device mapping profile | Exact fingerprint and selection of installed mappings | Inert until reviewed and selected by the host |
| Behaviour contract | Versioned transition/effect semantics for installed capabilities | Reviewed implementation contract, not arbitrary device-supplied executable policy |
| Instance enrollment and qualification | Bind a physical/virtual Thing to selected mappings and evidence | Consumer-owned durable authority |

Model, profile and instance are not interchangeable. Rooms, household names and transport addresses do not belong in portable family profiles. Serial numbers and native identifiers remain private binding/enrollment data.

A bridge can expose multiple children; one physical product can implement multiple capabilities; one capability can have several transport routes. Preserve these relationships without treating an IP address or bridge endpoint number as the permanent global identity.

### 5.2 Standard model example

The following illustrative Thing Model uses the standard model/affordance structure. It is not a complete physical sensor profile and does not imply any device is installed:

```json
{
  "@context": ["https://www.w3.org/2022/wot/td/v1.1"],
  "@type": "tm:ThingModel",
  "title": "Temperature observation interface",
  "version": {"model": "1.0.0"},
  "properties": {
    "temperature": {
      "type": "number",
      "readOnly": true,
      "unit": "degree celsius"
    }
  }
}
```

A host derives a concrete TD with the required communication/security information from its reviewed binding. A standalone native library, a bridge and a virtual test producer can all represent this interface. Exact numeric representation in Home remains governed by its capability contract, not by a blind copy of this illustrative model. [S1]

### 5.3 Behavioural extensions

The shared behavioural contract needs the following fields or equivalent typed values:

| Area | Required semantics |
|---|---|
| Identity | Contract version, immutable byte identity and semantic projection identity |
| Preconditions | Required capabilities, input domains, current-authority and observation requirements |
| Effects | Whole-resource domains touched, possible outcomes and side effects |
| Completion | Evidence sufficient for protocol acceptance, reported equality or another named disposition |
| Time | Deadline, transition duration, dwell/cooldown rules and timing uncertainty |
| Concurrency | Exclusivity, compatible simultaneous operations and stopping/supersession semantics |
| Retry | Separate logical resubmission, transport retry and physical repetition policies |
| Events | Source epoch/sequence, continuity, replay classification and causal attribution limits |
| Privacy | Collection/export/session requirements; no grant embedded in the profile |
| Model | Installed semantic/model compiler identity and declared analysis scope |

For a blind, this means target position, reported position, motion state, stop support and possible loss of feedback are explicit. A speaker adds a playback session and media identity rather than pretending to be a dimmable light. A button is an event source rather than a writable switch.

Do not add arbitrary mathematical expressions, module names or packet templates to portable profile data. Profile data selects reviewed installed semantics. A genuinely new semantic operation requires a reviewed host/runtime change and conformance vectors. [R9]

### 5.4 Preserve WOH.18's admission lifecycle

The existing profile lifecycle already separates inert staging, structural validation, approval, target selection and qualification. Preserve immutable raw bytes, separate semantic projections, original operation identities, retained dependencies, selection generations, revocation and explicit permission changes. [R9]

The universal successor should generalize this boundary, not weaken the existing loader. In particular:

* Keep v1's closed format and limits unchanged; add a separately identified successor.
* Require offline-resolvable pinned dependencies; do not fetch JSON-LD contexts or profile includes during dispatch.
* Retain original byte identity even when normalized semantics match.
* Never let a new matching profile automatically win by version number, publisher label or discovery order.
* A wider capability declaration does not widen existing credentials or active routines.
* Profile replacement fences old observations and unsent effects. It does not erase unknown handed-off outcomes.
* A signature establishes provenance under a policy, not runtime authority or physical truth.

Ordinary profiles require no Wasm engine. Optional WIT helpers remain a separate bounded implementation-delivery path with explicit resource limits, code identity and containment obligations. [R9][R10]

## 6. Observations, units and sensor semantics

### 6.1 Three separate facts

Always distinguish a requested value, a protocol report and what that report establishes. `requested = on` is not an observation. An acknowledgment is not a sensor reading. A reported matching state is not proof that the last command caused it.

Retain source time when supplied, but separately record the Store's receive boot epoch and monotonic receipt time. A sender's timestamp cannot establish host clock trust. Receiving a retained MQTT value or replaying storage must not renew its measurement age. [R7][R8]

A proposed logical observation record contains:

```text
Thing and capability identity
profile/selection/declaration basis
value with exact unit and representation
quality: usable / stale / unknown / invalid
source identity, source epoch and sequence when available
source timestamp and its trust classification when available
host receipt boot epoch and elapsed time
continuity/replay classification
provenance or derivation inputs
```

Reconcile each field with Continuum's existing public values before adding a new wire kind. Receipt-age freshness and source-age freshness must remain distinguishable. [R5]

### 6.2 Capability inventory

This is a required semantic catalogue, **not a claim that every family is implemented** and not a list of fixed freshness defaults.

| Family | State or events | Important restrictions |
|---|---|---|
| Motion | Detection and source event identity | No motion is not proof of no occupancy |
| Contact | Open/closed plus unknown and tamper where supported | Reconnect snapshot is not a new open edge |
| Temperature | Named quantity, exact unit, scale and validity | Device internal temperature is not room temperature |
| Humidity | Relative humidity with validity and bounds | Do not conflate relative and absolute humidity |
| Illuminance | Lux or explicitly qualified alternative | Brightness percentage is not lux |
| Occupancy estimate | Derived state, contributors and expiry | Never label a derived estimate as raw PIR evidence |
| Presence | Entity/zone, provenance and expiry | Device online state is weak evidence, not a person's identity |
| Electrical power | W, A, V and optional frequency/power factor | Only expose channels the exact device reports |
| Energy | Counter with unit, epoch and reset/wrap handling | No inference from a field name alone; no negative consumption on reset |
| Battery | Percentage, voltage, charging and low state separately | No voltage-to-percentage conversion without a qualified curve |
| Light | Power, level, colour space, temperature and transitions | Power and zero brightness remain distinct |
| Plug/load | Relay state and optional metering/protection | The connected load changes actuation policy |
| Cover/motor | Position, target, movement and stop | Tilt, obstruction and calibration only when actually supported |
| Remote | Button identity and press/hold/release events | Preserve real event distinctions and duplicates without fabricating gestures |
| Media | Playback/session, volume, source, queue/favourites and grouping | Local transport control and remote media availability are separate |
| Bridge/network | Topology, link and child health | A healthy bridge does not prove every child is reachable |
| Smoke/safety report | Detector-specific alarm/test/fault/battery facts | No automatic hush, reset, OTA or replacement of the standalone alarm |
| Camera/microphone | Authorized capture session and stream health | No persistent raw recording by default; no implied microphone access |
| Virtual/calculated | Derived quantity and full input provenance | A virtual capability needs its own implementation and confidence limits |

The implementation must support family-specific validation without vendor branches in routine evaluation. New quantity channels should compose the same scalar validation/rendering path, while actions retain their richer behaviour contracts. See [R7], the existing mapping successor [R11], and measurement references [S3]–[S5].

### 6.3 Units and limits

Preserve Home's existing exact representations where applicable: parts per million for fractions, millidegrees for hue, Kelvin for colour temperature and explicit milliseconds for durations. New quantities use declared integer/rational scales or a deliberately admitted numeric type, with independent conversion vectors. Never silently admit arbitrary floating-point values through a previously integer-only profile. [R7][R9]

For the proposed cover contract, choose an explicit name such as `open_fraction_ppm`: zero means closed and one million means open. Motionblinds' reference position convention is inverse, so the adapter must convert and test both endpoints and intermediate values. This is a **new semantic choice to ratify**, not a migration of an existing Home cover field.

Freshness is selected from a reviewed device/reporting contract and constrained by the consumer's intended use. Do not assign every sensor a thirty-second expiry. A sleeping battery sensor, continuous meter and button event have different report expectations. A routine may require stricter freshness than a display; it cannot make an old observation fresh.

Use hysteresis, debounce, sustained-condition windows and minimum actuation intervals as separately declared behaviours. Hysteresis prevents threshold oscillation; debounce filters transitions; cooldown limits repeats. They are not interchangeable.

## 7. Universal behaviour and routine model

### 7.1 Terms

| Term | Meaning |
|---|---|
| Capability | Typed supported interaction and its semantic contract |
| Behaviour | Reusable bounded transition pattern over capabilities |
| Scene | Desired-state composition with per-member outcomes |
| Routine | Versioned composition of triggers, conditions and executable steps |
| Schedule | Temporal trigger definition and execution ownership |
| Occurrence | One original temporal event, independent of polling time |
| Run | Durable execution of one immutable routine version |
| Step | A bounded transition or effect proposal within a run |
| Receipt | Evidence of a committed decision or effect disposition |

A schedule is not the routine. A scene is not the scheduler. A device profile must not install either an active routine or a hidden timer.

### 7.2 Language and semantics

Generalize Home's current compiler/IR rather than replace it with a new interpreter. The target language needs explicit, bounded forms for manual/time/report-event triggers; three-valued conditions; absolute capability actions; sequence; parallel branches; branch selection; waiting with a deadline; delay; cancellation; notifications; and parameterized subroutines.

Every construct requires defined input types, maximum expansion, declared effects, runtime interpretation, model projection or explicit unsupported-analysis classification, and independent test vectors. A Markdown description alone does not make a construct admissible.

Nested routines pin child versions and bind parameters before execution. Bound nesting depth, node count, total effects, waits, parallel width, subscriptions and retained outputs. Do not accept recursive invocation merely because each routine separately validates.

### 7.3 Triggers and conditions

Reported-edge triggers use qualified current observations. A first sample, restored snapshot, reconnection snapshot or retained replay establishes a baseline rather than a synthetic rising edge. Source epoch changes and profile replacement invalidate the baseline. [R6]

Conditions evaluate against an explicit revisioned snapshot. Unknown stays unknown through conjunction, disjunction and negation. `not(unknown)` is not true. A branch must define whether an unknown condition blocks, waits within a bound, or selects an explicitly declared unknown branch.

Triggers propose work; they do not authorize it. The current author's permissions, target/input grants and applicable constraints must be checked again when the effect can occur.

### 7.4 Sequences, parallelism and failure

A sequence advances when the preceding step reaches its declared evidence threshold. It must not confuse local dispatch with device completion. A parallel group retains each branch's identity and outcome. Initial join semantics should be all-required or explicitly nonblocking; add quorum/race semantics only with complete cancellation and evidence rules.

A failure policy may stop unstarted branches, continue independent branches, record partial completion, or propose an explicit compensation. Compensation is a new authorized effect, not a database rollback. It must not restore an obsolete light state over a later manual change.

Cancellation prevents future unsent work. It cannot unsend a BLE command or make a handed-off motor movement disappear. A stop action is a separate effect with its own authorization and receipt. A successful stop report is not evidence that previous movement never occurred.

### 7.5 Arbitration and manual control

Arbitrate by reviewed **effect domain**, conservatively whole-Thing until narrower domains are justified. Two different properties may share one underlying command packet or actuator. Brightness and colour changes can contend even when their field names differ.

Preserve the existing pure arbiter's complete-set requirement. Collect every eligible proposal in the bounded active set before applying the batch cutoff. Equal-authority incompatible effects are a conflict; timer arrival order and map iteration do not choose a winner. [R6][R8]

Hard runtime constraints remain non-overridable. Manual precedence is a consumer policy applied through a bounded override lease with scope, author, expiry and epoch. A manual label is not a grant. Routine priority can order permitted work but cannot override a denied safety constraint or expired authorization.

Dynamic capability selectors are valuable, but unrestricted discovery cannot silently expand an active routine. Initial execution pins an authorized resolved set. A membership change either creates a new admitted basis or follows a separately proved bounded selector policy that rechecks grants and effect domains.

## 8. Scheduling and direct ExBooking reuse

### 8.1 Existing Home semantics are the baseline

Home's accepted scheduler target already separates:

* Calendar once, daily or selected weekdays at a local time.
* Fixed UTC-anchored intervals, without drift from command completion.
* Boot-local monotonic countdowns.
* Clock uncertainty, eligible occurrence windows and missed outcomes.
* Original authorship, generation changes, occurrence identity and durable no-repeat history.

Its current bounds include a total active set of 64 rules/schedules, a 16-candidate batch, fixed intervals from one minute to 31 days, and countdowns from one second to 24 hours. These are existing first-profile limits, not universal constants to impose on every future consumer. Generalization must make accepted bounds explicit and preserve the currently qualified subset. [R6]

### 8.2 What ExBooking actually supplies

ExBooking is pure decision logic. It has no database, supervisor, jobs or clock reads. The caller passes time and normalized state. Its interval algebra, schedule expansion, exclusions, validation and deterministic resource selection are useful without modeling every event as a booking. [R13]

Use direct calls to public ExBooking APIs for temporal calculations and genuine availability/capacity questions. Do not introduce a booking facade from another project. Do not create a fake `MeetingType` for a motion event, light command, cooldown or immediate manual override.

A decision that a resource is available is not a reservation. When reservation semantics are actually needed, the consumer must revalidate and persist against its coherent transaction snapshot. A pure calculation cannot prevent another process from using the same resource. [R13]

### 8.3 Important source-level differences

| Existing path | Spring-forward gap | Autumn repeated time | Output |
|---|---|---|---|
| `ExBooking.Schedule` | Moves a window boundary to the first valid instant after the gap | First occurrence | Merged/clipped availability intervals |
| `ExBooking.RRule` | Skips nonexistent recurring occurrences | First occurrence | Duration-bearing intervals clipped to the query horizon |
| Home calendar recurrence target | Skips nonexistent recurring occurrences | First occurrence once | Original occurrence with durable execution identity |

The distinction is visible in `schedule.ex` and `rrule.ex`; it must not be hidden by a function named Schedule. [R14][R15][R6]

The current recurrence parser supports daily/weekly `FREQ`, `INTERVAL`, `COUNT`, UTC `UNTIL` and weekly `BYDAY`. Unsupported parts fail explicitly. It is not a complete RRULE implementation. Its expansion requires a positive duration, and clipping can change the returned interval's start. That is appropriate for availability but unsuitable as the sole identity of a routine trigger. [R15]

### 8.4 Proposed ExBooking extension

Add a backward-compatible public **occurrence enumeration API** using the existing recurrence kernel. Exact module/function names remain to be specified. Required outputs are original nominal local occurrence, resolved UTC due instant, recurrence ordinal or stable position, time-zone basis and fold/gap resolution where relevant. Do not fabricate a duration and recover identity from a clipped interval.

Required inputs include finite horizon and work/occurrence limits. Preserve COUNT semantics relative to the original recurrence, not a truncated search window. A pagination/cursor design must bind rule and time-zone identity; a cursor must not silently resume under different tzdata. Long historical ranges need bounded seeking or an explicit bound error, not an unbounded walk from an ancient DTSTART.

Keep existing availability APIs unchanged. Add policy options only through a documented versioned API; do not silently change booking customers' gap handling to match routine-trigger semantics. ExBooking remains independent of Home and WoTEx.

### 8.5 Clock semantics

Calendar schedules bind an IANA zone and the installed time-zone data identity. A traveling laptop or OS zone change must not change the home's intended schedule. A reviewed tzdata update creates a successor calculation basis; historical occurrences retain the old basis. [R6]

Use the host's UTC confidence interval and boot/clock generation. Before an effect is admitted and before unsent work is handed off, the whole confidence interval must fit the admitted occurrence window. A wall-clock correction invalidates old monotonic projections; moving backward cannot reissue a considered occurrence. Moving forward does not produce a catch-up burst.

A calendar recurrence, UTC interval and monotonic delay are separate representations. Never persist a raw monotonic deadline across a boot and assume it remains meaningful. Countdown restart policy is explicit; Home's current target expires boot-local countdowns after restart or unqualified clock discontinuity.

Default missed policy stays skip. Bounded catch-up is a future admitted behaviour, not a free consequence of using an absolute target. Calendar exceptions and solar triggers are additional source forms requiring deterministic calculation inputs and tests. A solar routine must also define polar no-rise/no-set cases and location privacy; those facts should not come from an undisclosed remote lookup.

### 8.6 Device-owned schedules

Represent ownership as controller, device or external, with a separate confidence/source field. A timetable manually copied from a screenshot is not a verified device read. Readability, writability, synchronization and authority are separate capabilities.

The CMD-03's existing 06:00 and 19:00 timers demonstrate the issue: suppressing a Home routine does not disable a motor's own timer. Avoid two owners independently executing the same intention. Keep working native timers intact during integration. [S17][S18]

A migration protocol is: prepare a disabled host schedule; request or guide device-timer removal; confirm or explicitly record the limits of that confirmation; then activate the host schedule. This is a recoverable staged change, not an atomic distributed transaction. A failure can leave a documented interval with neither scheduler active; do not respond by blindly enabling both.

The existence of timers in the motor's app does not establish a supported BLE timer-editing command. Timer synchronization stays separate until source and hardware evidence exist.

## 9. Behaviour analysis with ExMaude

### 9.1 Existing integration and honest results

Home already depends on ExMaude. Its verification specification documents the bundled IoT model's limited conflict checks, two-valued/unknown-state differences, incomplete action semantics and missing priority arbitration. The integrated Home negative projection is intentionally narrow. A completed bounded search without a finding remains inconclusive for unproved properties. [R2][R8][R16]

Use four independent result axes: input/model validity, findings, execution completion and admission decision. Timeout, unsupported semantics, output truncation, backend loss, a counterexample and exhausted bounded search must not collapse into one Boolean.

No backend success or empty conflict list becomes a universal `safe` result. Conversely, a real counterexample is useful and should explain the triggering conditions and conflicting effects.

### 9.2 Shared behavioural representation

Compile the same canonical routine IR into the interpreter and a Maude model projection. The model must preserve every semantic feature relevant to its property: unknown/stale observations, environmental transitions, multiple writers, source continuity, manual overrides, deadlines, partial outcomes and causal budgets.

This is not permission to drop unsupported constructs. The compiler must reject the model projection or return explicit unsupported scope rather than turn an invocation into a no-op. Exact source, IR, compiler, capability, model, runtime and time-policy identities belong in the evidence basis. [R8]

Ordinary behaviours can use bounded structural arguments and independent finite correspondence tests where justified. More complex interacting behaviours need sufficient evidence for their declared properties. A finite abstraction must describe what is preserved and how abstract counterexamples are checked against concrete executions. Fairness assumptions and finite horizons must remain visible.

### 9.3 Properties worth checking

| Property | Example | Required qualification |
|---|---|---|
| Writer consistency | Two same-authority routines set opposing motor targets | Complete current eligible set and effect-domain mapping |
| Feedback control | Closing a blind changes light level and triggers reopening repeatedly | Environmental response model, hysteresis/cooldown and causal semantics |
| Unknown preservation | A stale no-motion report is used to infer an empty room | Three-valued semantics and observation freshness |
| Temporal eligibility | Work admitted before a deadline dispatches after it | Queue, clock-generation and final-handoff transitions |
| Bounded execution | Nested routines multiply actions indefinitely | Expansion limits, invocation graph and root accounting |
| Reservation consistency | Two procedures require the same exclusive instrument | Coherent host reservation transitions, not pure availability alone |
| Manual precedence | A later authorized override is undone by stale compensation | Override, revision and compensation semantics |

These are target analysis properties, not claims about the current bundled IoT checker.

### 9.4 Execution isolation

Use explicitly supervised, bounded caller-owned workers. Models are trusted compiled inputs with immutable identities, not raw source received from a device, voice request or downloaded profile. A failed or uncertain worker is retired before reuse. The end-to-end budget includes queueing, model preparation, native execution, output parsing and receipt construction.

The native process boundary is not by itself a complete memory or filesystem sandbox. Apply host-specific process, memory, file and output limits. Verification must not starve observation handling or ordinary control.

Run analysis on definition, composition and assumption changes, not on every sensor event or click. Valid admitted work continues using current runtime guards while its proof basis remains applicable. Verifier loss blocks fresh proof-required admission rather than disabling the entire home. [R8]

### 9.5 Independent oracle

An interpreter and compiler generated from the same buggy rule are not independent evidence. Keep reference AST evaluation, virtual-clock occurrence vectors and independent transition traces. Mutation tests must reject omitted guards, altered precedence, stale fact acceptance, truncated-before-arbitration sets and missing causal accounting.

## 10. Durable execution and authority

### 10.1 Persist intent before handoff

The generic runtime proposes a transition. The Home Store atomically validates the current basis and reserves its occurrence/root before creating held work. Existing queue, claim and final-handoff guards remain in place. Physical dispatch happens only after the durable handoff marker commits. [R1][R6][R8]

Routine author identity is retained and rechecked. The scheduler's process identity cannot replace a revoked author's grants. Revocation, profile selection, maintenance and authority transfer fence unsent work without rewriting original receipts.

### 10.2 Outcome vocabulary

Preserve Home's existing receipt distinctions. A future routine aggregate can report scheduled, skipped, blocked, running, partial, completed-under-declared-evidence or outcome-unknown, but it must reference underlying step receipts rather than hide them.

An adapter may report only evidence it possesses: local send acceptance; protocol response; correlated device report; reported equality or contradiction; or uncertainty. Device-reported equality should not be displayed as an independent physical measurement.

### 10.3 Three different kinds of retry

1. **Logical retry of the same API operation:** return the original scoped receipt; never mint another effect.
2. **Transport-level retry:** allowed only within the qualified protocol and command context, with its precise evidence/repetition semantics.
3. **Physical command repetition:** a new or repeated effect requiring an explicit supported policy and current authority.

An absolute `set position` is easier to reason about than `toggle`, but may still restart movement, reset a timer, disturb a newer controller action or consume another causal effect. Home's current no-replay-after-handoff policy is retained. Unknown execution is reconciled by observation when possible, not resolved by blind resend. [R6][R8]

### 10.4 Recovery and backpressure

Restore definitions and history, not automatic authority. Same-owner restart can resume retained admitted work only when the relevant basis remains valid. Transfer, backup restoration and maintenance follow their existing explicit re-admission rules. Unknown handed-off effects remain unknown until valid reconciliation.

Bound candidate expansion, subscriptions, queues, in-flight native work and storage. Slow event consumers must not accumulate unbounded device reports. Report continuity loss, advance a source generation and obtain a new baseline. Never silently drop events and still claim uninterrupted edge detection.

Use considered-through watermarks and compact missed-range summaries. Compaction cannot erase the no-repeat boundary or refund causal effects. Store migrations must preserve original receipt identities and pending uncertainty.

## 11. Protocol and package changes

The current WoTEx family contains independent core/runtime, directory, continuum, Nx, HTTP, MQTT, BACnet, BLE, CoAP, Matter, Modbus, OPC UA, Thread, UDP, Zigbee, conformance and lab packages. Package existence does not mean every intended capability is complete. [R3][R4]

| Package/boundary | Required change or reconciliation | Not a reason to rewrite |
|---|---|---|
| `wotex` | Validate reusable TM composition and inert extension preservation; resolve pinned model closure offline | Keep the existing TD/TM parser |
| `wotex-runtime` | Align public lifecycle, cancellation, resource ownership and implementation admission with routine host needs | Do not move consumer grants or Store ownership here |
| `wotex-directory` | Preserve qualified consumer indexing separately from untrusted discovery descriptions | Directory registration is not enrollment |
| `wotex-continuum` | Reuse observations/intents/results/evidence; add only demonstrated missing fields through versioned contracts | No competing receipt/event envelope [R5] |
| `wotex-nx` | Optional deterministic batching of admitted observations for derived analysis | No requirement for Nx or a model in routine execution |
| HTTP binding | Timeouts, TLS, body limits, endpoint custody and SSE continuity | No raw arbitrary URL execution from profile data |
| MQTT binding | Retained-message provenance, epoch continuity, scoped subscriptions and bounded backpressure | Broker QoS is not actuator completion |
| CoAP | Reuse protocol mechanics for appropriate device mappings | Shelly CoIoT descriptions still require exact vendor mapping |
| BLE | Add explicit write mode; qualify without-response semantics; native macOS backend behind the same contract | Existing BlueZ work is not discarded [R17] |
| Matter | Keep controller and exposed server roles separate; stable endpoint/fabric custody and typed exports | Current controller software evidence does not prove a bridge [R12] |
| Thread | Network routing/inspection and explicit network ownership | No automatic device grants from border-router connectivity |
| UDP | Preserve interface selection, bounded receive and endpoint ownership | LIFX, discovery and other vendor codecs remain separate |
| Zigbee | Reuse bounded coordinator and ZCL support; qualify exact device/coordinator combinations | No forced Zigbee2MQTT runtime or brand-wide support claim |
| BACnet / Modbus / OPC UA | Prove that the same routine interfaces can consume real industrial mappings | Do not pull every industrial stack into Home |
| Conformance / lab | Add independent generic profile/routine consumers and fault scenarios | Fixtures are not physical qualification |

### 11.1 BLE specifics

Current BLE targets BlueZ on Linux and includes acknowledged writes, discovery, pairing, reads and subscriptions. The Motionblinds reference uses a write-without-response command path. Add an explicit operation mode through validation, transport IPC and result semantics; do not return a fabricated ATT acknowledgment. [R17][S18]

For macOS, add a CoreBluetooth implementation with explicit permission/lifecycle handling, write readiness/backpressure, disconnection, notification continuity and host-bound identity mapping. Native peripheral identifiers are not cross-platform global device IDs. Neither CoreBluetooth nor BlueZ method return alone establishes motor completion. [S19]

A shared Linux controller is another supported host choice, not a reason to make the standalone Mac product depend on a new server.

### 11.2 Vendor mappings and upstream policy

Upstream WoTEx's present graph keeps product/vendor semantics outside its generic packages. Therefore do not put a Sonos radio catalogue or bedroom routine in `wotex-runtime`. Keep the initial reviewed mappings in Home's existing integration namespaces or an independently delivered consumer-neutral adapter collection with separately agreed ownership. The generic BLE/HTTP/UDP improvements belong upstream. [R4]

Reusable vendor adapters may be extracted later when their interfaces and licensing are coherent. Their existence must not require editing generic routine evaluation for each brand.

## 12. Device inventory and integration decisions

Model identifiers below come from user-provided screenshots/photos in the research conversation. Firmware strings are inventory snapshots, not claims about current latest releases. Public documentation supplies protocol opportunities; physical qualification remains outstanding unless an existing repository ledger explicitly records it.

### 12.1 Inventory

| Device | Evidence and correction | Local route / semantic profile | Outstanding work |
|---|---|---|---|
| LIFX A19 | Screenshot model `lifx_color_a19`, user label B01 | LIFX LAN over UDP; light capabilities from numeric product/firmware interview | Bind screenshot alias to exact wire identity; preserve current read/write/readback work [R1][S12] |
| Hue Bridge | BSB002; screenshot software `1781978293000` | HTTPS v2, resource inventory and event stream | Pair application key, preserve TLS checks, qualify event continuity and writes [R1][S13] |
| Hue lamp / illuminated mirror | User-described Hue fixture; exact light resource/model pending | Bridge-exposed light capabilities | Do not assume full colour/gamut from appearance |
| Hue dimmer remote | User describes standard Hue switch; generation pending | Bridge button events or explicitly qualified direct Zigbee path | Interview resource type; preserve ordinary physical behaviour and avoid duplicate handling |
| Shelly Wardrobe Light | `SHCB-1`, build `20201008-085327/master@a3d98bb0` | **Shelly Bulb RGBW**, not a generic relay controller; Gen1 HTTP/CoIoT and mode-specific colour/white mapping | Read actual operating mode and channels; firmware selection remains separate [S14] |
| Shelly motion device | `SHMOS-02`, build `20240306-093418/v2.2.3@8f5e4729` | **Motion 2 on the Gen1 API surface**; motion, illuminance and available environmental/battery channels | Do not confuse product generation with API generation; validate exact status fields [S14] |
| Shelly Plug S | `SHPLG-S`, build `20220627-131242/v1.11.8-6-g09c98037f-plug-s-selftest-calibration` | Gen1 relay plus supported metering/protection channels | Identify attached load, preserve original state and map energy units exactly |
| Motionblinds | CMD-03 Bluetooth; app displays 06:00 to 0% and 19:00 to 100% enabled | BLE roller-cover, stop, position, speed/favourite and reported battery where supported | Native Mac BLE, without-response writes, feedback qualification; firmware and timer editing remain open [S17][S18] |
| Sonos | PLAY:1 identified during photo review; exact firmware/S1-S2 installation pending | Local discovery, media state, volume, favourites and playback; UPnP/SOAP compatibility mapping | Preserve existing radio favourites and required metadata; validate subscriptions and streaming formats [S15] |
| HomePod mini | User-confirmed purchase | Apple Home hub, Matter ecosystem interface, Thread routing and AirPlay playback | No claimed open microphone endpoint; sensor import into Home requires an independently validated path [S20][S21] |
| Nest Wifi Point | H2E, Cast `1.56.514310` | Network infrastructure plus Cast playback where qualified | Do not assume Nest Mini replacement-board compatibility or raw microphone access |
| Nest Wifi Router | H2D, software `14150.883.859` | Network infrastructure | No speaker/microphone role inferred; no firmware modification needed |
| Bedroom Google speaker | Cast `3.78.540761`; hardware model not established | Cast playback first | Firmware string cannot identify a compatible replacement PCB [S22][S23] |
| Samsung The Frame | User-identified TV; year/model/firmware pending | Local WebSocket remote and model-specific Art Mode where supported | Read exact model, pairing behaviour, power/network state and Art API availability [S24] |
| Nintendo Switch | User-identified console; hardware revision pending | Indirect HDMI/TV integration, not a general sensor/action server | No homebrew requirement; no game/process control claim [S25] |
| Groove lamp | User label only; brand/model/power behaviour unknown | Undetermined | Do not silently rename to Govee or infer a smart protocol |
| Cat lamp | Decorative lamp photographed; smart capability unestablished | Standalone unless identification proves otherwise | Check rated supply, physical switch and power-restoration behaviour before considering external control |

### 12.2 Highest-value existing-hardware paths

**Shelly, Hue and LIFX:** use documented local interactions first. Gen1 Shelly models have model-specific surfaces; inspect their actual descriptions/status instead of assigning every Gen1 device the same channels. Preserve authentication and local cloud/MQTT configuration semantics. Hue v2 uses HTTPS; extend the existing verified read path rather than disable certificate checks or downgrade to HTTP. LIFX keeps its existing UDP correlation and separate readback model. [S12][S13][S14]

**Sonos radio:** prioritize browsing retained favourites, selecting an existing station, volume and stop, then preserve playback/session metadata and observable failure. A radio URI may be service-specific and require associated metadata or authentication; a station title is not a playable stream URL. Internet radio still needs internet even when Sonos control stays on the LAN. The PLAY:1 is not a native AirPlay target; do not promise synchronized AirPlay with HomePod by treating both as identical speakers. [S15][S16]

**Motionblinds:** retain the motor, pair through reviewed Bluetooth identity and map position explicitly. Distinguish currently connected feedback from a last-known disconnected position. Use bounded interactions and measured refresh policy, not permanent aggressive polling of a battery device. CM-55 is a documented optional Matter route for CMD-03, not a prerequisite for the direct BLE implementation. [S17][S18][S26]

**Hue remote:** a spare supported gesture can become a generic routine trigger after verifying its exact event vocabulary. Do not silently remove its existing lighting action or cause the bridge and Home to execute the same press twice.

**The Frame and Switch:** begin with an explicit Watch/Play scene. Later use qualified TV state as a trigger, keeping network availability, on/off, Art Mode, selected HDMI input and actual game activity separate. Nintendo documents TV power-state coordination, not a universal local console API. Avoid power-cutting a console to implement sleep. [S24][S25]

**Unknown lamps:** first establish whether each has a smart controller, a replaceable compatible bulb, a latching physical switch or rechargeable touch electronics. A controlled outlet is only an on/off solution when the lamp's actual power-on behaviour and rated load make it appropriate. Do not open mains-powered electronics or choose a power interface solely from appearance.

### 12.3 Offline capabilities are per action

A local light command can work without WAN. A Sonos station stream, hosted AI conversation or vendor account operation may not. Expose local transport availability, content-service availability and source confidence separately. Do not put one misleading offline-capable badge on a mixed routine.

No new hub purchase is necessary to validate the generic architecture. Extra radio hardware should be justified by an identified protocol or coverage gap, not by treating every integration as an opportunity to add another gateway.

## 13. HomePod and Google voice reuse

### 13.1 HomePod roles

Use HomePod mini as an Apple ecosystem client/hub and Thread border router, with AirPlay playback where an actual sender supports it. The Thread border router transports IP connectivity; WoTEx still needs its own commissioned Matter controller identity to interact with Matter devices. It does not inherit Apple's device grants merely by using the network. [S20][S21]

Two separate Matter paths exist:

```text
Import:
Matter accessory -> WoTEx Matter controller -> consumer-authorized capability

Export:
qualified Home capability -> WoTEx Matter bridge -> Apple Home / HomePod
```

Home's current Boolean-light export proposals cannot represent a blind, speaker or arbitrary routine. Add legitimate device types and supported clusters only after the upstream exposed-server path and semantic conversion are ready. Never fake a smoke detector or complex routine as a switch solely to make it appear in Apple Home. [R10][R12]

Apple Home and Siri requests entering through the bridge map to restricted consumer principals and current guards. Endpoints persist across restart. Fabric removal revokes that access without deleting the underlying physical device. Prevent re-import of Home's own exported endpoints and bridge-of-bridge loops.

HomePod's temperature and humidity sensors are useful in Apple Home, but that does not establish a supported headless WoTEx read API. Document a validated native Apple-side integration if one is built; otherwise label the readings as Apple-only. Apple also documents domestic operating/calibration limitations, so these readings are not laboratory measurements. [S20]

HomePod is not an open Siri server, raw microphone stream or arbitrary TTS/intercom endpoint. AirPlay output and conversational input are different integrations. A native App Intent/Shortcut can submit a structured request only within the platform's actual support and authorization, not bypass Home admission.

### 13.2 Real Google speaker reuse options

The available open-source work is meaningful, but hardware specificity matters:

| Route | Reuses | What it establishes |
|---|---|---|
| Stock Cast playback | Existing speaker, firmware and network endpoint | Audio output and media control; not microphone capture |
| Independent microphone plus Cast output | Existing speaker plus a separate capture source | A custom voice pipeline without replacing the stock speaker board |
| Onju replacement board | Compatible Nest Mini second-generation enclosure/speaker/interfaces as specified by its design | A real custom conversational endpoint, not a universal software jailbreak |
| Model-specific firmware exploit | Only the exact vulnerable model/build | Not established for this household's current devices |

Onju's original repository marks itself deprecated in favour of `onju-v2`. The successor describes replacement hardware for **Google Nest Mini second generation**, even though its title uses broader Home terminology. Do not infer compatibility with H2E Nest Wifi Point, H2D router, first-generation Home Mini or an unidentified Cast speaker. [S22][S23]

The reference hardware supports a tap/button interaction rather than requiring the vendor wake phrase. It demonstrates that the requested experience is possible with appropriate hardware. Its example transport and server design are references, not an already-qualified secure Home integration. Do not copy unauthenticated LAN audio assumptions into production.

### 13.3 Independent voice boundary

Proposed pipeline:

```text
physical tap / push-to-talk / explicitly selected local wake-word detector
  -> authorized bounded capture session
  -> speech recognition
  -> structured request or conversational response
  -> validated capability/routine proposal
  -> Home admission and current execution guards
  -> speech synthesis / selected playback endpoint
```

Capture sessions have visible state, mute behaviour, finite retention and expiry. Prefer no raw-audio persistence by default. Add acoustic echo cancellation and interruption only after testing the actual microphone/speaker path; otherwise use an explicit half-duplex interaction instead of claiming full-duplex performance.

Ordinary commands can use deterministic grammar or the existing optional local intent direction. Rich conversation may use a separately configured hosted or local model directly. No AI layer gets packet access, credentials, grant-management authority or raw Maude source loading.

The user's request to speak to a Sol-class model is a provider/model preference, not an API entitlement. OpenAI's developer catalogue contains Sol model entries, but ChatGPT subscriptions and API billing are separate. Select an explicitly available model and supported authentication in the deployed account; do not promise subscription reuse, scrape consumer sessions or hardcode promotional prices. Audio recognition/synthesis may be separate services from the selected reasoning model. [S27][S28]

## 14. Proving workflows

These examples are requirements for testing the proposed shared machinery, not currently executable routine files.

### 14.1 Motion-to-light with an override

A qualified motion report establishes an event. During a configured operating window, a fresh illuminance condition proposes an absolute light level. A manual-off override blocks that effect until its declared expiry. Later no-motion handling requires a defined absence interval; it does not assume a single false report proves an empty room.

The same behaviour must work with two different motion producers and two different light transports without vendor branches in the compiler/interpreter. Reconnection and retained initial data produce a baseline, not an activation.

### 14.2 Morning with radio and blinds

A calendar occurrence in the configured home zone proposes a bounded parallel lighting/blind group, then a selected radio favourite under the consumer's audible-hours policy. The scene reports partial completion if radio content is unavailable but the blind and lights succeeded.

Existing motor-owned timers are either explicitly left independent or migrated as a separately recorded operation. A Sleep In exception is effective only for schedules Home actually owns; the UI must disclose remaining external/device timers.

### 14.3 Privacy and Watch

An explicit app action or qualified remote event submits a scene with a reviewed blind position, lighting state and radio stop. A later confirmed TV input/Art state may become a trigger. A generic stop control remains available for the motor. Failure of the TV integration does not erase completed light outcomes or trigger a loop of retries.

### 14.4 Non-household calibration procedure

A laboratory consumer uses the same routine IR with a measurement producer, a reference instrument and an ordinary test actuator. ExBooking calculates an allowed maintenance window and, if required, exclusive resource availability. The consumer commits the reservation. The routine waits for a fresh stable measurement under explicit tolerances, invokes the calibration action, then waits for its declared completion report.

Transport can be a simulated public WoT binding initially and a qualified industrial binding later. Routine source contains capability references, not room names or consumer-specific modules. Record environmental assumptions; a simulation is not evidence of safe industrial operation.

### 14.5 Illustrative routine structure

This JSON deliberately uses a `proposal` format marker. It must not be accepted by today's production loader:

```json
{
  "format": "proposal.wotex.routine.v1",
  "id": "routine-example",
  "revision": 1,
  "trigger": {"kind": "manual"},
  "bindings": {
    "input": {"thing": "example-sensor", "capability": "temperature"},
    "output": {"thing": "example-actuator", "capability": "power"}
  },
  "condition": {
    "kind": "fresh_compare",
    "binding": "input",
    "operator": "lt",
    "value": {"integer": 21000, "unit": "degree_celsius", "scale": 1000},
    "freshness_policy": "reviewed-example-policy"
  },
  "unknown_policy": "block",
  "steps": [
    {
      "id": "set-output",
      "kind": "absolute_action",
      "binding": "output",
      "value": true,
      "completion": "reported_match",
      "after_uncertain_handoff": "reconcile_without_resend"
    }
  ],
  "overlap_policy": "reject",
  "limits": {"effects": 1, "parallel_width": 1}
}
```

The numeric threshold is illustrative, not a universal default. The implementation must supply the complete typed schema, current grants, immutable capability basis, qualification and host transaction contract before such a program can be admitted.

## 15. Security, privacy and supply chain

### 15.1 Threats and resolutions

| Threat or failure | Required resolution |
|---|---|
| Discovery spoofing | Discovery remains untrusted; explicit enrollment and exact binding review |
| Malicious profile | Bounded parser, inert data, pinned closure, reviewed installed semantics and no executable fetch hooks |
| Grant expansion through update | Explicit capability/permission diff, selection generation and current grant rechecks |
| Device/voice prompt injection | Untrusted input produces proposals only; no arbitrary commands, models or credentials |
| SSRF and endpoint substitution | Host-resolved enrolled routes, scheme/peer restrictions, no arbitrary URL fields in routines |
| Native decoder failure | Owned process lifecycle, bounded IPC/queues/output and OS resource limits |
| Lost/duplicated reports | Source generations, deduplication where justified, continuity loss and baseline reset |
| Split authority | One active owner, durable fencing and explicit transfer; no multi-writer assumption from multi-admin |
| Feedback oscillation | Effect-domain arbitration, hysteresis, dwell, bounded causal work and explicit manual override |
| Sensitive audio/presence | Session-scoped authorization, visible collection, minimal retention and explicit egress |
| Stale compensation | Revalidate target revision and current ownership before any compensating effect |
| Artifact rollback | Original identity/history, trust-generation checks and persistent rollback policy |
| Dependency drift | Exact source/build identities; re-run affected correspondence and host qualification |

### 15.2 Network design

Keep legacy local protocols behind the consumer controller. Separate remote client access from raw device control. Expose only authenticated Home interfaces remotely; do not forward device administration, Sonos, Cast or BLE proxy endpoints directly to the internet.

Segmentation must be protocol-aware. mDNS, SSDP, IPv6 reachability, Matter subscriptions and selected UDP discovery need explicit rules. Do not blindly put everything on an isolated guest network and then disable verification to fix discovery. Evaluate what the existing router actually supports; no VLAN or multicast-reflector capability is inferred for the H2D/H2E setup.

Local-first is not synonymous with authenticated. Where a legacy device protocol lacks strong identity, keep that trust classification visible, restrict network access and do not claim TLS/Matter-grade guarantees for it.

### 15.3 Secrets, updates and offline trust

Use consumer-owned credential providers and native secure custody. Definitions contain references, not API keys, BLE secrets, Matter operational credentials or account refresh tokens. Native workers receive the minimum needed context, never a broadly privileged user's bearer.

Maintain WOH.18's existing local digest-approval model. A future publisher-signature mode needs explicit keys, rotation, expiry, revocation and rollback semantics. Distribution freshness and an already retained local approval are different decisions. Do not claim knowledge of an offline revocation that has not arrived. [R9]

A firmware update is a maintenance workflow separate from ordinary control. Record before/after device identity and state, invalidate affected qualification and test recovery. Old firmware strings in the inventory are not an instruction to install whichever release currently appears newest.

Preserve source and binary license notices, exact native dependency inventories and reviewed redistribution obligations. No third-party implementation is copied into this research document. Using an open-source protocol reference does not eliminate the need to inspect its license before copying code or shipping binaries.

## 16. Home interface and observability

The native Home client should render capabilities and declared behaviour status, with household labels layered on top. It must not embed a separate scheduler or discover new authority merely from receiving a profile.

Required routine views include source/version, resolved participants, trigger, next occurrences, current execution owner, DST/missed-run policy, active override, blocked reason, per-step outcomes and input freshness. An authoring preview shows omitted or unsupported device capabilities before activation.

The central diagnostic question is **why did this happen?** A trace should connect observation or calendar occurrence to evaluated predicates, arbitration, author/grants, selected program version, committed intent and actual receipt. Conversely, **why did nothing happen?** must distinguish stale input, no matching trigger, override, lack of grants, conflicting writers, missed window, unreachable device and uncertain physical outcome.

Simulation operates against explicit snapshots and virtual time without physical dispatch. It displays candidate effects and uncertainty; it does not mark the simulated run physically qualified. Replaying history is read-only unless an explicit fresh authorized action is requested.

Device cards distinguish live reports, aged last-known state, unreachable transport and unknown values. Media cards separately show local player reachability and station availability. A timer card identifies whether the controller, device or external ecosystem owns execution.

## 17. Migration and implementation work packages

The following are dependency-ordered engineering changes, not created issues or PRs. Each starts with its owning specification and finishes with executable evidence. Work may proceed in parallel only when it does not bypass prerequisite semantics.

### P01 — Reconcile ownership and current evidence

**Owners:** Home documentation and WoTEx architecture/tooling.  
Map WOH.01/04/07/10/14/15/18 and their successor documents to actual public code and tests. Record which existing behaviours will be extracted and which remain consumer policy. Reconcile Continuum before designing new envelopes. Add an architecture rule excluding the removed dependency and wrappers.  
**Acceptance:** every proposed new mechanism has an existing owner, a justified new owner or an explicit gap; no current partial contract is relabelled complete.

### P02 — Public capability/behaviour basis

**Owners:** WoTEx core/Continuum and the proposed routines package.  
Define reusable TM closure, qualified mapping references, units, effect domains, observation requirements and behavioural result vocabulary. Separate descriptive metadata from executable admission.  
**Acceptance:** independent generic producers represent scalar, event, fast actuator, slow actuator and media interfaces without vendor branches; malformed and unknown executable semantics reject predictably.

### P03 — Profile successor without weakening v1

**Owners:** Home WOH.18/WOH.01/WOH.03 and shared value contracts.  
Implement multi-channel profile selection through the existing custody, approval and Store lifecycle. Preserve raw/projection identities, history, grants and active-basis fencing.  
**Acceptance:** independently authored profiles select two models with common channels; widening, stale review, revocation and changed firmware cannot retain old authority.

### P04 — ExBooking occurrence API

**Owner:** `futhr/ex_booking`.  
Add bounded original-occurrence enumeration and documented temporal policies without changing existing availability expansion.  
**Acceptance:** DST folds/gaps, COUNT, supported BYDAY, horizon clipping, historical seeking, pagination limits and invalid rules have independent vectors; original due identity is never replaced by query-window start.

### P05 — Extract the routine kernel

**Owners:** proposed `wotex-routines` and Home WOH.04/WOH.07.  
Move generic source/IR, three-valued evaluation and bounded transition decisions behind public interfaces. Keep household vocabulary and authorizations in Home.  
**Acceptance:** the existing restricted explicit-light corpus remains equivalent; no protocol or Store dependency appears in pure kernel tests; two independent consumers exercise the package archive.

### P06 — Temporal admission and driver

**Owners:** routines package and Home WOH.04/WOH.14/WOH.15.  
Connect direct ExBooking calculations to the existing occurrence reservation, clock-confidence and no-repeat contracts. Add an explicit supervised wakeup driver and host callback interface.  
**Acceptance:** duplicate ticks, restart, sleep/wake, forward/backward corrections, queue saturation and missed windows cannot produce a second effect or bypass final temporal guards.

### P07 — Sensor-event behaviours

**Owners:** routines package, Home fact/authority boundary and selected bindings.  
Implement continuity-aware edges, sustained conditions, debounce, hysteresis and cooldown using current admitted facts.  
**Acceptance:** initial/replayed/stale reports do not fabricate events; source changes reset baselines; derived occupancy retains provenance and expiry.

### P08 — Complete-set arbitration and composition

**Owners:** routines package and Home durable runtime.  
Extend from the current pure provided-set arbiter to complete active-set collection and durable multi-root handling. Add sequence, bounded parallelism, waiting and version-pinned subroutines as explicit semantic profiles.  
**Acceptance:** conflicts are decided before queue cutoff, equivalent roots retain ownership/accounting, cancellation cannot erase handoffs, and branch outcomes remain independent.

### P09 — Maude behavioural projection

**Owners:** routines model compiler; generic enhancements in `futhr/ex_maude` only where needed.  
Add faithful model projections, property scopes, result axes, evidence identity and independent reference/mutation tests.  
**Acceptance:** no bounded absence becomes unconditional safety; unsupported constructs do not disappear; changed source/profile/clock/model invalidates affected evidence.

### P10 — BLE write-mode parity

**Owner:** WoTEx BLE.  
Add explicit with/without-response operations through the public contract, native IPC, backpressure and conformance suite.  
**Acceptance:** no ATT acknowledgment is fabricated; failed queueing, cancellation, payload limits and disconnect preserve correct evidence.

### P11 — Native macOS BLE

**Owner:** WoTEx BLE with a consumer-owned native host.  
Add CoreBluetooth behind the same public lifecycle contract and bind private OS identifiers to enrolled Things.  
**Acceptance:** permission denial, re-discovery, host sleep, session loss, notifications and write readiness are tested on an installed Mac; no Linux-only dependency becomes mandatory for Home.

### P12 — Motionblinds mapping

**Owner:** Home device integration and cover semantics.  
Implement exact CMD-03 identity, position conversion, supported stop/speed/favourite operations and battery/connection reports. Preserve native timers until explicit migration.  
**Acceptance:** real read/move/stop/readback, lost feedback, app coexistence and disconnected last-known-state tests; no invented timer-edit capability.

### P13 — Shelly, Hue and LIFX completion

**Owner:** Home integrations; generic transport fixes upstream.  
Extend exact channel mappings and finish qualified events/writes through the common authority path. Correct SHCB-1 and SHMOS-02 profile identities. Preserve working LIFX code and Hue TLS verification.  
**Acceptance:** two vendors share routine semantics; WAN-cut, malformed/retained data, physical override, firmware change and partial-scene tests preserve honest results.

### P14 — Sonos radio and media

**Owner:** Home media mapping.  
Add bounded discovery, favourite/source selection, player state, volume and stop with private session/metadata custody.  
**Acceptance:** existing desired stations play on the actual PLAY:1, broken streams remain distinct from local command failure, subscription loss refreshes state, and no native AirPlay capability is falsely advertised.

### P15 — Matter export and Apple experience

**Owners:** WoTEx Matter exposed-server role and Home WOH.10.  
Complete required server semantics; add legitimate light/cover export mappings, stable endpoint IDs, restricted fabric principals and loop prevention.  
**Acceptance:** actual Apple Home/HomePod pairing, restart, subscription gaps, two-controller conflicts and fabric revocation pass without a second Home device-authority path.

### P16 — Entertainment and independent voice

**Owner:** Home optional integrations.  
Add model-qualified TV capabilities and Cast output. Identify the Google speaker before any replacement-board choice. Implement a separately authorized voice session path only after the capture hardware is established.  
**Acceptance:** ordinary routines run with every voice/model service disabled; unsupported microphones, Art APIs and Switch controls remain absent.

### P17 — Native authoring and migration UX

**Owner:** Home native client and public API.  
Expose capability-based composition, occurrence previews, owner labels, semantic diffs, manual overrides, simulation and per-step history.  
**Acceptance:** closing the UI leaves qualified owner work running; uncertain mutations recover their original receipt; a profile edit cannot silently add effects.

### P18 — Independent non-Home proof and extraction completion

**Owner:** WoTEx lab/conformance and a separate consumer fixture.  
Run the same source/IR/time/effect corpus in Home and a non-household consumer through public package archives. Remove temporary compatibility paths only after parity is demonstrated.  
**Acceptance:** neither consumer imports the other's private modules, database or terminology; package load has no side effects; old receipt/profile identities remain valid historical records.

### Migration rules across all packages

Do not dual-write authoritative state into an experimental second store. A read-only shadow projection or decision comparison is acceptable when it cannot dispatch. Keep old loaders and public semantics explicit until their callers are migrated. Native and CLI clients keep their existing operation/receipt recovery behaviour.

Source extraction changes compiled identities. Preserve original evidence as history, recompute affected software correspondence and qualify the installed cohort before activating new dispatch. Do not narrow existing full-runtime digests merely to reduce revalidation work without independent dependency evidence. Dependency upgrades are reviewed changes, not a side effect of adding this research file.

## 18. Conformance and acceptance

### 18.1 Evidence layers

Record evidence separately for schema/constructor validity, pure semantics, independent software interoperability, installed-host lifecycle, physical-device behaviour and ecosystem acceptance. No layer automatically upgrades the next. A simulator and production adapter must not share all encoders/decision logic in a way that hides the same defect on both ends.

### 18.2 Mandatory scenario matrix

| Boundary | Required cases |
|---|---|
| Profiles | Duplicate JSON keys, oversized/deep input, unknown operations, dependency change, equal labels/different bytes, revocation and rollback |
| Units | Min/max, scale conversion, invalid sentinels, signed values, counter reset/wrap, incompatible dimensions and cover inversion |
| Facts | Stale/untimed/old-boot values, retained replay, duplicate source events, missing channels and derived provenance |
| Calendar | Stockholm and another zone; fold/gap; invalid one-shot; tzdata update; bounded recurrence; long downtime |
| Clocks | Uncertainty interval, wake discontinuity, backward/forward correction, delayed final handoff and boot-local countdown expiry |
| Durable runtime | Crash before/after reservation, claim, handoff and settlement; lost API response; original receipt lookup |
| Arbitration | Full set before cutoff; conflicting/equivalent writers; manual override; coalescing and root preservation |
| Composition | Sequence evidence, partial parallel results, timeout, bounded nesting, stale compensation and cancellation after handoff |
| Verification | Unsupported models, truncation, timeout, worker death, semantic mutation and invalid cache reuse |
| Native transports | Slow peers, queue limits, disconnect, cancellation, permission denial, malformed IPC and resource cleanup |
| Devices | Actual identity/firmware, physical/manual interaction, readback, WAN cut, restart and ambiguous completion |
| Ecosystems | Stable exported identity, fabric revocation, subscription loss, duplicate discovery and denied commands |
| Privacy | Redacted diagnostics, finite audio sessions, no raw audio persistence by default and explicit egress |
| Reuse | Same routine corpus in independent Home and non-Home consumers without private cross-calls |

For each applicable case record source/build/profile identities, exact setup, expected outcome, actual outcome and evidence location. Timing and battery/latency characteristics are measured on hardware; no invented figures are acceptance evidence.

### 18.3 Delivery definition

The architecture is demonstrated when a qualified event producer, fast actuator, slow actuator and media endpoint can participate in the same capability-based routine system; existing direct controls continue independently; the scheduler preserves original occurrence identity across faults; and a non-Home consumer runs the same generic kernel without household dependencies.

This does not require implementing every sensor category or hacking every old device first. Unknown or unsupported capabilities must remain visible limitations rather than fabricated controls.

## 19. Open questions and decision records

### 19.1 Decisions to ratify in normative specifications

| ADR proposal | Decision |
|---|---|
| A01 | WoT TD/TM is the description foundation; no competing universal device parser |
| A02 | Reuse Continuum exchange values; no duplicate authority or receipt store |
| A03 | Universal routines are an opt-in consumer-hosted WoTEx package |
| A04 | ExBooking is used directly; add original-occurrence API without altering booking defaults |
| A05 | ExMaude analyses declared properties; negative results and admission remain separate |
| A06 | One shared source/IR and independent correspondence evidence |
| A07 | No automatic physical repetition after uncertain handoff |
| A08 | Device, external and controller schedules have explicit owners |
| A09 | Data profiles select installed semantics; code delivery is a separate boundary |
| A10 | Matter controller, exposed bridge and Thread routing remain distinct |
| A11 | Native Mac and Linux implementations share public behaviour, not assumed OS identity |
| A12 | Independent non-Home conformance is required before calling the kernel universal |

These are proposed records within this research document, not newly accepted ADR files.

### 19.2 Remaining factual gaps

The exact Google bedroom speaker model, The Frame model/year/firmware, Hue remote generation, decorative lamp identities, Sonos firmware/system configuration and CMD-03 firmware remain necessary for final device-specific qualification. The screenshots do not settle those facts.

Native HomePod sensor ingestion, supported CMD-03 timer programming, the complete commercial/distribution requirements for a shipped Matter bridge, and any model-specific Google firmware modification require their own verified implementation evidence. They are not blockers for generic profiles or ordinary local routines.

Current upstream package documentation and Home's pinned dependencies differ. Each consuming change must select and test a coherent revision set rather than combine APIs observed at unrelated heads.

### 19.3 Status of this document

This commit adds research only. It does not add a runtime dependency, modify a specification catalogue, create active routines, change device timers, commission a Matter fabric, flash hardware, update firmware or run tests. Future work updates evidence and normative owners explicitly; prose does not promote itself to implementation.

## 20. Source register

Repository sources are pinned where inspected. Public implementation/vendor sources are references checked during the research chain, not blanket compatibility guarantees. Date-sensitive model entitlements and hardware firmware must be checked again when implemented.

### Repository sources

* **[R1] Home README and implementation baseline:** [README](https://github.com/wotex-project/wotex-home/blob/c73d7ac50d64cbae3fa3000184d47a136e70d3a2/README.md), [implementation plan](https://github.com/wotex-project/wotex-home/blob/c73d7ac50d64cbae3fa3000184d47a136e70d3a2/docs/plans/implementation.md), [local integration contract](https://github.com/wotex-project/wotex-home/blob/c73d7ac50d64cbae3fa3000184d47a136e70d3a2/docs/specs/WOH.03-local-integrations.md).
* **[R2] Home actual dependency pins:** [mix.exs](https://github.com/wotex-project/wotex-home/blob/c73d7ac50d64cbae3fa3000184d47a136e70d3a2/mix.exs).
* **[R3] WoTEx family and consumer ownership:** [README](https://github.com/wotex-project/wotex/blob/80c8b9188eef4f3414ddccc5fc913356bc50d7ae/README.md).
* **[R4] WoTEx package graph and public boundaries:** [package-graph.md](https://github.com/wotex-project/wotex/blob/80c8b9188eef4f3414ddccc5fc913356bc50d7ae/docs/architecture/package-graph.md).
* **[R5] Existing Continuum values and wire contract:** [README](https://github.com/wotex-project/wotex/blob/80c8b9188eef4f3414ddccc5fc913356bc50d7ae/packages/wotex-continuum/README.md).
* **[R6] Home scheduler target and current limits:** [local-scheduler-v1.md](https://github.com/wotex-project/wotex-home/blob/c73d7ac50d64cbae3fa3000184d47a136e70d3a2/docs/specs/local-scheduler-v1.md).
* **[R7] Existing capability, unit, scene and observation semantics:** [WOH.01](https://github.com/wotex-project/wotex-home/blob/c73d7ac50d64cbae3fa3000184d47a136e70d3a2/docs/specs/WOH.01-home-semantics.md).
* **[R8] Existing proof limits, source/IR correspondence and admission:** [WOH.07](https://github.com/wotex-project/wotex-home/blob/c73d7ac50d64cbae3fa3000184d47a136e70d3a2/docs/specs/WOH.07-formal-verification.md).
* **[R9] Existing inert profile format, custody, trust and selection:** [WOH.18](https://github.com/wotex-project/wotex-home/blob/c73d7ac50d64cbae3fa3000184d47a136e70d3a2/docs/specs/WOH.18-portable-profile-admission.md).
* **[R10] Existing Matter export proposals and ecosystem boundary:** [WOH.10](https://github.com/wotex-project/wotex-home/blob/c73d7ac50d64cbae3fa3000184d47a136e70d3a2/docs/specs/WOH.10-matter-bridge.md). Optional component ownership is indexed from the [specification index](https://github.com/wotex-project/wotex-home/blob/c73d7ac50d64cbae3fa3000184d47a136e70d3a2/docs/specs/WOH-index.md).
* **[R11] Multi-channel successor:** [device-profile-mappings-v2.md](https://github.com/wotex-project/wotex-home/blob/c73d7ac50d64cbae3fa3000184d47a136e70d3a2/docs/specs/device-profile-mappings-v2.md), referenced by WOH.01 and WOH.18; reconcile its complete runtime boundary in P03.
* **[R12] Upstream Matter implemented controller profile:** [README](https://github.com/wotex-project/wotex/blob/80c8b9188eef4f3414ddccc5fc913356bc50d7ae/packages/wotex-matter/README.md). The separate exposed-server role is identified in [R4].
* **[R13] ExBooking public responsibilities and non-goals:** [README](https://github.com/futhr/ex_booking/blob/212cffa61e32b596f7a19d5a830ff64f39e830e1/README.md).
* **[R14] ExBooking availability-window DST behaviour:** [schedule.ex](https://github.com/futhr/ex_booking/blob/212cffa61e32b596f7a19d5a830ff64f39e830e1/lib/ex_booking/schedule.ex).
* **[R15] ExBooking recurrence subset, gap policy and clipping:** [rrule.ex](https://github.com/futhr/ex_booking/blob/212cffa61e32b596f7a19d5a830ff64f39e830e1/lib/ex_booking/rrule.ex).
* **[R16] ExMaude public generic and IoT APIs:** [ex_maude.ex](https://github.com/futhr/ex_maude/blob/2c61558fc541fa1aacf7c81e40510cb49108528a/lib/ex_maude.ex), [iot.ex](https://github.com/futhr/ex_maude/blob/2c61558fc541fa1aacf7c81e40510cb49108528a/lib/ex_maude/iot.ex). Home's consumed pin and restricted integration are recorded in [R2] and [R8].
* **[R17] Upstream BLE backend and write semantics:** [README](https://github.com/wotex-project/wotex/blob/80c8b9188eef4f3414ddccc5fc913356bc50d7ae/packages/wotex-ble/README.md).

### Standards, vendor and implementation sources

* **[S1] W3C WoT Thing Description 1.1, including Thing Models:** [specification](https://www.w3.org/TR/wot-thing-description11/).
* **[S2] W3C WoT Architecture 1.1:** [specification](https://www.w3.org/TR/wot-architecture11/).
* **[S3] ETSI SAREF:** [core vocabulary](https://saref.etsi.org/core/).
* **[S4] IETF SenML:** [RFC 8428](https://www.rfc-editor.org/rfc/rfc8428).
* **[S5] OGC SensorThings API Part 1: Sensing 1.1:** [standard](https://docs.ogc.org/is/18-088/18-088.html).
* **[S6] IETF iCalendar recurrence semantics:** [RFC 5545](https://www.rfc-editor.org/rfc/rfc5545).
* **[S7] CloudEvents:** [project and specification links](https://cloudevents.io/).
* **[S8] W3C SCXML:** [state-machine specification](https://www.w3.org/TR/scxml/).
* **[S9] Home Assistant execution-mode reference:** [automation modes](https://www.home-assistant.io/docs/automation/modes/).
* **[S10] Temporal durable workflow reference:** [workflow execution](https://docs.temporal.io/workflow-execution).
* **[S11] Oban scheduler comparison:** [Cron plugin](https://hexdocs.pm/oban/Oban.Plugins.Cron.html).
* **[S12] LIFX official local protocol:** [LAN documentation](https://lan.developer.lifx.com/).
* **[S13] Hue official local API direction:** [new Hue API](https://developers.meethue.com/new-hue-api/), [developer updates including HTTPS-only guidance](https://developers.meethue.com/). Detailed account-gated API pages must be checked during implementation.
* **[S14] Shelly official Gen1 reference:** [API](https://shelly-api-docs.shelly.cloud/gen1/), including SHCB-1 RGBW bulb and SHMOS-02 Motion 2 sections.
* **[S15] SoCo local Sonos implementation reference:** [core API](https://soco.readthedocs.io/en/latest/api/soco.core.html).
* **[S16] Sonos official AirPlay compatibility:** [supported products](https://support.sonos.com/en-us/article/stream-airplay-audio-to-sonos).
* **[S17] Motionblinds Bluetooth integration behaviour:** [maintainer documentation](https://www.home-assistant.io/integrations/motionblinds_ble/).
* **[S18] Motionblinds BLE protocol implementation:** [repository](https://github.com/LennP/motionblindsble), [device command path](https://github.com/LennP/motionblindsble/blob/main/motionblindsble/device.py), [constants](https://github.com/LennP/motionblindsble/blob/main/motionblindsble/const.py).
* **[S19] Apple native BLE:** [CoreBluetooth](https://developer.apple.com/documentation/corebluetooth), [Bleak macOS backend identity notes](https://bleak.readthedocs.io/en/latest/backends/macos.html).
* **[S20] Apple HomePod control and sensor limitations:** [HomePod guide](https://support.apple.com/en-gb/guide/homepod/apd8085c1032/homepod).
* **[S21] Apple HomePod mini interfaces:** [technical specifications](https://www.apple.com/homepod-mini/specs/).
* **[S22] Google Cast implementation reference:** [PyChromecast](https://github.com/home-assistant-libs/pychromecast).
* **[S23] Google speaker replacement-board research:** [Onju original, deprecated](https://github.com/justLV/onju-voice), [Onju v2](https://github.com/justLV/onju-v2). Both hardware identity and actual implementation need independent qualification.
* **[S24] Samsung local WebSocket/Art implementation reference:** [samsung-tv-ws-api](https://github.com/xchwarze/samsung-tv-ws-api).
* **[S25] Nintendo official TV-power integration:** [TV settings](https://en-americas-support.nintendo.com/app/answers/detail/a_id/22331).
* **[S26] Motionblinds Matter bridge compatibility:** [CM-55 and supported motor documentation](https://www.home-assistant.io/integrations/motionblinds_matter/).
* **[S27] OpenAI official billing boundary:** [ChatGPT and API billing](https://help.openai.com/en/articles/9039756-managing-billing-settings-on-chatgpt-web-and-platform).
* **[S28] OpenAI official model availability reference:** [developer catalogue](https://developers.openai.com/), [Sol model example](https://developers.openai.com/api/docs/models/gpt-5.6-sol). Deployment must select an actually available model; this research fixes no pricing or entitlement.

---

**Resulting direction:** preserve the existing Home authority and evidence model; generalize its reusable semantics into an opt-in WoTEx routine kernel; use TD/TM and Continuum rather than duplicate them; reuse ExBooking directly for temporal/resource calculations and ExMaude for scoped behavioural analysis; and prove the design with both the actual household devices and an independent non-Home consumer.
