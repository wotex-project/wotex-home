# ADR 0008 — Match the proof to the admitted semantics

Status: accepted target decision, 2026-09-26.

Use ex_maude for the exact questions its selected model implements. The present bounded IoT APIs are useful counterexample finders but do not provide a general positive safety result. Empty findings and legacy unverified returns are not interchangeable with admission.

Home's priority, unknown-state, timer and effect semantics must be represented faithfully or rejected at compilation. Provide a separately justified restricted-rule admission profile and keep unsupported composed proof obligations inactive. Runtime guards remain necessary after admission because the physical environment and capability evidence can change.

The presentation demonstrates rejected drafts without physical effects. It does not put the home into a known bad state to make a verifier look useful.
