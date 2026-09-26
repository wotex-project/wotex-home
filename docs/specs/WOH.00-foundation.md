# WOH.00 — Local authority and product scope

Version: 0.2.0. Status: accepted target; implementation and physical evidence are not claimed.

## Purpose

Home is an operator-owned home controller, not a collection of cloud integrations or a demonstration that intentionally makes appliances misbehave. Its job is to keep local control predictable, prevent prohibited automation from becoming active, and explain incomplete outcomes honestly.

**H00-01 — Offline operation.** After local commissioning and installation of required artifacts, discovery, ordinary control, admitted automations, observations and recovery MUST work without WAN or public DNS. First installation, factory-reset commissioning, normal operation and firmware acquisition are separate qualification stages. A device requiring an account for initial provisioning is not silently described as fully vendor-independent; that limitation must be disclosed before admission or purchase.

**H00-02 — One authority.** One Home instance owns the actuator command path for a deployment. macOS is the first host. Nerves is a first-class appliance target using the same core, not a prerequisite for macOS. A second host starts read-only until an explicit authority transfer. No active-active actuator control, distributed Erlang exposure or CRDT merge of safety state is part of the baseline.

**H00-03 — Common command gate.** UI, CLI, schedules, rules, Matter requests, DistilBERT candidates and optional Refpath tools all pass the same authorization, capability, invariant and execution checks. Direct manual control may skip a model search; it may not skip safety guards. Device-specific vendor APIs are never exposed as an unrestricted escape hatch.

**H00-04 — Availability.** Already-admitted rules continue when their assumptions remain valid, even when optional inference or the verifier is unavailable. New revisions with unmet proof obligations remain inactive. An expired assumption suspends the affected rule/effect domain rather than turning off the entire home. A failed safety-sensitive transition does not default to an AI substitute.

**H00-05 — Honest guarantees.** Home distinguishes command intent, durable admission, dispatch, protocol acknowledgement and observed state. It does not promise exactly-once physical effects, universal protocol compatibility, instantaneous distributed scenes or certified life-safety control. Devices with unauthenticated protocols retain that trust limitation.

**H00-06 — Ownership.** WoTEx owns TD/TM values, generic interaction contracts and reusable protocols. Home owns device profiles, home semantics, state, rules and authority. ex_maude owns generic formal operations. DistilBERT is required in the demonstration profile but optional to ordinary operation; Refpath is optional everywhere. The native shell owns presentation and platform integration, never a second rule engine.

## Acceptance

H00-T1: start with WAN/public DNS blocked and all required artifacts preinstalled. H00-T2: stop inference and verification workers independently; check the availability policy. H00-T3: start a second controller; it cannot dispatch. H00-T4: run the same prohibited command through every input surface; each is rejected before device I/O. Hardware tests record exact devices and firmware, not merely successful unit tests.
