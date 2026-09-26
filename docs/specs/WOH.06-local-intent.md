# WOH.06 Local intent inference

## Status

Accepted target contract.

A local DistilBERT sequence classifier provides a small natural-language intent surface. It is not a chatbot and not an authority.

Inference yields an immutable candidate containing intent, confidence, slots, model digest, input digest and source.

An IntentCandidate is untrusted evidence. A deterministic planner maps an accepted candidate to a structured ProposedTransition. Confidence thresholds, allowed intents and slot validation are deterministic policy. No cloud inference fallback occurs silently.

Safety events are never reclassified through DistilBERT. Structured Matter/Home commands are already structured requests and MUST NOT be passed through the natural-language classifier.

The initial vocabulary SHOULD remain intentionally small: lights on/off, brighter/dimmer, warm/cool, reading mode, night mode, leave/arrive home and similar bounded intents.

The preferred Elixir implementation path is Nx/Bumblebee DistilBERT sequence classification, with model/tokenizer revisions pinned. macOS is the first performance target; Nerves requires separate memory/latency/thermal qualification.
