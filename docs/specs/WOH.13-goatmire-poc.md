# WOH.13 Goatmire physical PoC

## Status

Accepted demonstration contract.

The PoC demonstrates the Goatmire qualification loop using real local home hardware.

## Clean path

```text
natural-language command
 -> local DistilBERT IntentCandidate
 -> deterministic ProposedTransition
 -> ex_maude qualification
 -> authorized WoT interaction
 -> real LIFX/Hue light changes
 -> physical state re-observed
```

## The loop nobody invented

Use individually reasonable rules that compose into an undesirable cycle, for example:
- night mode wants a hallway light off;
- motion at night wants it on;
- a restore rule returns it to night desired state.

No rule contains an explicit infinite loop. ex_maude must expose the conflict/reachable bad composition or the bounded verification must remain unverified; the physical action is blocked according to policy. The demo shows the witness rather than claiming AI intuition found the problem.

## Safety example

Use a simulated smoke event or qualified safe self-test state. Never generate real smoke for the stage demo.

A safety invariant can require evacuation lighting to remain on while smoke safety mode is active, demonstrating that ordinary night automation cannot override safety.

## Presentation resilience

The demo is local: WAN is unnecessary. A deterministic fixture/simulator fallback may reproduce the same semantic inputs if venue RF is hostile, but it must be visibly identified as simulated evidence rather than real hardware.

DistilBERT and ex_maude are meaningful components, not decoration: inference proposes; formal/deterministic qualification governs; WoTEx executes.
