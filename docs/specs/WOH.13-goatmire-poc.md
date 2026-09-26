# WOH.13 Goatmire physical PoC

## Status

Accepted demonstration contract. This is an isolated test fixture around Home's prevention mechanisms, not normal Home behavior.

## Purpose

Demonstrate that Home prevents a problematic automation composition before activation, then show that an admitted safe composition controls real local hardware.

## Prevention demonstration

Construct a draft rule-set containing individually plausible rules whose composition would produce a prohibited cycle/conflict if admitted. The fixture is never activated.

    draft rules
      -> Home admission pipeline
      -> ex_maude
      -> conflict/counterexample
      -> REJECTED REVISION
      -> zero physical Actions

The active Home configuration remains unchanged. The audience sees prevention, not a deliberately malfunctioning home.

## Safe physical path

    local request / admitted rule
      -> deterministic Home policy
      -> WoTEx
      -> real LIFX/Hue light
      -> physical state re-observed

Local DistilBERT may optionally supply an input candidate for the presentation, but it cannot bypass admission/authorization and is not required for Home's correctness.

## Safety demonstration

Use a simulated smoke observation or manufacturer-qualified safe self-test state, never real smoke. Demonstrate that an ordinary automation unable to satisfy the active smoke safety invariant is blocked before physical execution.

## Presentation resilience

WAN is unnecessary. A deterministic simulator may replace hostile venue RF but must be labelled simulated.

The product lesson is that problematic compositions are prevented from becoming active; the demo merely makes that prevention visible.
