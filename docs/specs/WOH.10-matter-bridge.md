# WOH.10 — Optional Matter export and ecosystem boundaries

Version: 0.2.1. Status: accepted target. Matter server/bridge implementation remains an upstream prerequisite.

## Separate roles

**H10-01.** Consuming Matter devices and exporting a Matter bridge are different roles. The inspected WoTEx package has a native controller profile. Tests against an SDK bridge peer do not establish that WoTEx itself hosts a bridge. WMA.09 defines the separate target; no Home spec may report it as implemented merely because controller tests pass.

Home exports a reviewed subset of its Things. Matter endpoint identity, fabrics, commissioning and generic cluster machinery belong upstream. Home owns semantic conversion, effect authorization, load risk and source-of-truth policy. There is no dependency on an Apple/Google account for core local operation.

## Export admission

**H10-02.** Map only qualified Home capabilities into supported Matter Device Types and cluster revisions. Never fake a smoke sensor as a switch or an unsupported mode as a certified device type to satisfy a UI. Complex Home modes may remain direct-API operations until a legitimate ecosystem mapping exists. Native bulb capabilities are not inferred from the bridge's own device type.

The first pure `Matter.ExportShape.proposal/1` accepts only an exact ordinary Boolean Light power declaration with both read and write operations. It reports a shape-only proposal for the [tagged Matter 1.5.1 On/Off Light device type](https://github.com/project-chip/connectedhomeip/blob/v1.5.1.0/data_model/1.5.1/device_types/OnOffLight.xml), ID `0x0100`, revision 3. The proposal requires server-side Identify (`0x0003`), Groups (`0x0004`), On/Off (`0x0006`, including the required LT feature) and Scenes Management (`0x0062`). Extra Home capabilities are listed as omitted, never silently translated; SmokeDetector and altered or read-only power declarations have no proposal. This check is a declaration filter, not an endpoint, cluster implementation, profile qualification, admission decision or authorization. The upstream bridge must supply and independently verify the full device type conformance before any endpoint is exposed.

Endpoint IDs persist across restart, are not casually recycled after removal and remain bound to the same Home identity. Matter ACL/fabric identity is necessary but not sufficient Home authorization. Each inbound command maps to a restricted Home principal and goes through current guards. Uncertain physical completion is reflected honestly under the exact command semantics.

## Multiple controllers

**H10-03.** Matter multi-admin does not create multiple Home authorities. All accepted external requests pass the same arbiter. Home's own Matter controller must not rediscover and control its exported endpoints in a feedback loop. Preserve origin metadata and reject unsupported bridge-of-bridge cycles. Attribute reports are driven by admitted observations, not by optimistic UI state.

On subscription loss or missed reports, explicitly refresh state. Revoking a fabric removes its access without deleting Home's underlying devices. Do not report a commissioned bridge as a certified or production-approved accessory; commercial certification and ecosystem distribution are separate work.

## Siri and Google

These are optional voice/control surfaces. Structured ecosystem commands do not need DistilBERT. Their speech-recognition or account requirements are outside Home's offline guarantee. An old Google Home's controller capabilities require exact model/firmware qualification; no speculative offline voice promise is part of this design. Legacy cloud-to-cloud/Local Home SDK flows are not foundation dependencies.

## Acceptance

H10-T1: stable endpoints and restart/remove/re-add behavior with an independent controller. H10-T2: two fabrics issuing conflicting commands reach one Home arbiter. H10-T3: denied/safety commands remain denied. H10-T4: subscription gaps and unknown effects are not presented as successful actuation. H10-T5: self-discovery cannot loop back into the physical command path. H10-T6: Apple/Google outages do not affect the direct local API or admitted automations. Physical ecosystem tests and certification are reported separately.
