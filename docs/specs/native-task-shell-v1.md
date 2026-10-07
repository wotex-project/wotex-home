# Native task shell v1

Version: 0.1.1. Implemented task composition with bounded software evidence,
2026-10-08. WOH.08 owns the adaptive
profiles and accessibility obligations. This shell consumes existing shared
authority/session models and creates no controller or permission model.

The window opens on Setup without requesting a credential or contacting the
local API. Its tasks are Things (select an enrolled Thing, inspect evidence and
request an authorized change), Rules (compose and separately confirm an explicit
decision), Activity (inspect and reconcile original outcomes), and Setup (enable
the local host, explicitly select custody, choose a device network, review a
profile/enrollment and separately grant access). Setup explains that closing the
window leaves an enabled background host running. Registration eligibility and
actual authenticated health are displayed separately.

Use available content width: compact below 600 points, medium 600–839, expanded
at least 840. Compact/medium task navigation is inline; expanded is adjacent.
Use one stable content identity across layout changes so draft, selection,
confirmation and native text focus survive a width transition. Task choices do
not change credential or controller. Keep original recovery and availability
visible in every task. No layout path hides denied authority, stale/unknown/lab
quality, uncertainty or original reconciliation. Only enrolled Things are cards.
Supporting setup and evidence use ordinary sections or disclosures.

Panels retain their original mutation guards, captured inputs and private
pending journal. Session/network changes respect current busy and
unresolved-operation guards; changed session clears scoped inspection. Host
start/stop stays available when no API work is in flight, so a retained original
can be recovered after a stopped host. These controls discard no pending record.
Read-only Thing inspection repeats scope before and after its read. Explicit
device refresh uses the existing bounded host read, never a timer or write.
Client monotonic expiry can only shorten Store freshness. Sleep/wake invalidates
the view and fences an already-running read from publishing an old presentation.

The four exact edge widths share the same fixtures. Required software evidence
includes layout fit, continuity of draft/selection/confirmation and native text
focus, semantic keyboard controls/accessibility labels and enlarged text. Actual
OS contrast/motion/transparency settings, VoiceOver navigation and installed
host/device completion remain their own measured acceptance. Rendering cannot
establish a device result, signed custody or hardware qualification.

`HomeTaskShell` uses one `AnyLayout` content identity and window-local task
selection; the app injects its existing shared session, health, profile,
access, explicit-rule and pending models. Command-1 through Command-4 select
tasks. Setup/session and network controls wrap when their row cannot fit.
Changing navigation never selects another credential or discards an original.

`mix woh.native.task.shell.smoke` mounts real native windows at 599, 600, 839
and 840 points, then reverses the transition. Native text-field identity and
its first-responder field editor, draft, selection and confirmation remain
unchanged. Eight mounted renders cover ordinary and enlarged text, with an
additional contrast shader for readability inspection. That shader does not
exercise the OS Increase Contrast setting. The shell uses a solid background
and no layout animations or material effects. Semantic controls and labels
compile; actual keyboard/VoiceOver operation and OS accessibility preferences
still need installed-host acceptance.

The complete Swift app compiles with warnings as errors. Existing session
operations and portable-profile workflows pass 34 and 16 private-Store cases;
the new Thing panel passes ten. App inventory/SPDX checks pass. These fixtures
establish software composition, not signed installed custody or device effects.
