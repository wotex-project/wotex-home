# WOH.00 — Local authority and product scope

Version: 0.2.3. Status: accepted target; implementation and physical evidence are not claimed.

## Purpose

Home is an operator-owned home controller, not a collection of cloud integrations or a demonstration that intentionally makes appliances misbehave. Its job is to keep local control predictable, prevent prohibited automation from becoming active, and explain incomplete outcomes honestly.

**H00-01 — Offline operation.** After local commissioning and installation of required artifacts, discovery, ordinary control, admitted automations, observations and recovery MUST work without WAN or public DNS. First installation, factory-reset commissioning, normal operation and firmware acquisition are separate qualification stages. A device requiring an account for initial provisioning is not silently described as fully vendor-independent; that limitation must be disclosed before admission or purchase.

**H00-02 — One authority.** One Home instance owns the actuator command path for a deployment. macOS is the first host. Nerves is a first-class appliance target using the same core, not a prerequisite for macOS. A second host starts read-only until an explicit authority transfer. No active-active actuator control, distributed Erlang exposure or CRDT merge of safety state is part of the baseline.

**H00-03 — Common command gate.** UI, CLI, schedules, rules, Matter requests, DistilBERT candidates and optional Refpath tools all pass the same authorization, capability, invariant and execution checks. Direct manual control may skip a model search; it may not skip safety guards. Device-specific vendor APIs are never exposed as an unrestricted escape hatch.

Every mutating entry point submits the same typed envelope. The gate derives the principal from an authenticated channel and checks current authority epoch, expected resource revision, exact enrolled target/capability, operation risk, required fact freshness, invariants and semantic value before a durable effect intent exists. The dispatcher repeats the checks that can become stale before handoff. A passing pure-data validation is neither admission nor permission to call a driver.

**H00-04 — Availability.** Already-admitted rules continue when their assumptions remain valid, even when optional inference or the verifier is unavailable. New revisions with unmet proof obligations remain inactive. An expired assumption suspends the affected rule/effect domain rather than turning off the entire home. A failed safety-sensitive transition does not default to an AI substitute.

**H00-05 — Honest guarantees.** Home distinguishes command intent, durable admission, dispatch, protocol acknowledgement and observed state. It does not promise exactly-once physical effects, universal protocol compatibility, instantaneous distributed scenes or certified life-safety control. Devices with unauthenticated protocols retain that trust limitation.

**H00-06 — Ownership.** WoTEx owns TD/TM values, generic interaction contracts and reusable protocols. Home owns device profiles, home semantics, state, rules and authority. ex_maude owns generic formal operations. DistilBERT is required in the demonstration profile but optional to ordinary operation; Refpath is optional everywhere. The native shell owns presentation and platform integration, never a second rule engine.

**H00-07 — One product application.** Home is one OTP application and one
authority boundary. Source namespaces separate domain values, application use
cases, infrastructure adapters and device profiles; they are not independently
versioned packages or alternate authorities. A new Mix package requires a
separate consumer-facing release contract and demonstrated independent reuse,
not only a convenient source-code partition.

Every external input surface calls the same application authority API. Unix
socket handlers, CLI parsing, Matter projection, intent interpretation and
future HTTP adapters decode or encode transport values only; they do not
coordinate Store calls, capture ownership or driver transitions themselves.
The application layer may invoke pure domain decisions and the single durable
writer, but it cannot weaken their validation or fabricate a physical outcome.

## Acceptance

H00-T1: start with WAN/public DNS blocked and all required artifacts preinstalled. H00-T2: stop inference and verification workers independently; check the availability policy. H00-T3: start a second controller; it cannot dispatch. H00-T4: run the same prohibited command through every input surface; each is rejected before device I/O. H00-T5: exercise the same application use case directly and through each enabled transport adapter; the durable result and policy decision are identical. Hardware tests record exact devices and firmware, not merely successful unit tests.

## Optional server, open device scope

**H00-08.** The product is a local device runtime, control center and admitted
scheduler. Standalone macOS provides all core functions supported by its actual
qualified bindings while its runtime is available. An optional
[shared Linux server](WOH.19-shared-server-host.md) supplies a different execution
location, uptime and attached resources; it can coexist with other applications
and does not require a dedicated Pi. The Nerves appliance image is an explicit
alternative. Moving an existing home preserves the one-owner transfer boundary.

Device scope is capability-based and extensible through
[portable mappings](device-profile-mappings-v2.md), rather than a permanent list
of four brands. Supported new models/channels should be data imports; new
protocols and privileged semantics have reviewed extension boundaries. No cloud
is required for normal operation after local provisioning; optional updates
and exceptional vendor commissioning limitations remain explicit. This is an
integration architecture, not a claim of universal physical compatibility.

H00-T6: the same supported core workflows work with no server, on a shared
server and on a dedicated appliance; missing host resources produce specific
capability limits. Closing a client never becomes implicit owner transfer.
