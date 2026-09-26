# Specification review — 26 September 2026

## Scope and source status

This review used direct repository inspection and the technical sources listed in [primary sources](../provenance/primary-sources.md). It does not claim to be an executed hardware trial or a recovered result from an asynchronous research job. The inspected Home baseline was `2eec0b7e36e27d23a324b049649eda632b5d4711`; WoTEx was `bb7f4c0074ddd2de2390d0d4337cb1efe680d5a3`; ex_maude was `ec7adfb4d59231e475dbbe735d0eb29b76c0d0fb`.

## Findings and decisions

| Earlier gap | Revised approach | Why / remaining obligation |
| --- | --- | --- |
| 'Prevent conflicts' without an execution/activation protocol | Immutable admission, effect arbitration, epoch checks and a bounded activation barrier | A proof can become stale before dispatch; queued bytes cannot be recalled by a DB commit |
| Verifier treated as a general safety gate | Exact proof obligations and separate restricted/composed profiles | Existing bounded safety search cannot supply a general positive proof |
| Runtime/model semantics assumed equal | Reject unsupported priority, unknown-state, timer and effect mappings | The inspected execution theory has two-valued absence, no priority arbiter and no-op invocation |
| Reconciliation could fight an override | Effect ownership, override leases, no-op suppression, hysteresis/dwell and circuit breakers | Static analysis alone cannot control unmodeled external writers |
| 'Durable' without crash boundaries | Single-writer snapshots/journal/outbox and explicit unknown effects | Device I/O cannot join a SQLite transaction |
| General distributed-home aspiration | One physical authority; read-only additional hosts and explicit transfer | CRDT merging does not resolve physical actuator authority or fence legacy devices |
| Frame app lifecycle copied too closely | Registered background Home service independent of windows | A frame can retain artwork without its host; live home automation cannot ignore host sleep/logout |
| Generic UDP wrapper underspecified | Explicit endpoint/owner/credit/overflow/truncation contract | UDP send acceptance is not delivery; OTP buffer behavior requires qualification |
| Zigbee radio equated with an open stack | NCP host architecture, firmware/API pins and separate licensing facts | Host programmability does not imply open source firmware or portable backup |
| Restore omitted security counters | Supported key/counter continuity and old-writer isolation | Rewinding network state or cloning identity is unsafe |
| Brand-level device support | Exact model/firmware/capability evidence | A third-party converter or pairing success does not qualify alarm reports |
| Shelly notifications grouped with HTTP/SSE | Generation-specific HTTP/RPC and explicit WS/MQTT event paths | HTTP RPC is not a notification channel and WebSocket is not SSE |
| Raw classifier scores called confidence | Trained labels, held-out calibration, OOD/ambiguity and deterministic slot resolution | Base weights do not know the desired home intents |
| Matter controller evidence reused for bridge | Separate native server/endpoint/fabric delivery plan | Testing a bridge peer is not hosting a bridge |
| Manufacturing feature wishlist | Measured resource budgets, versioned parts/radios and factory/recovery tests | Product schema validity is not RF, thermal or conformity evidence |

## Alternatives considered

A full event-sourced runtime adds replay/migration complexity without being required for one home; the selected hybrid retains a durable audit and recoverable current state. A multi-host consensus controller might be justified for another deployment class but cannot fence arbitrary old lamps by itself. A UDS data plane keeps native UI traffic local and bounded; XPC is reserved for native service/credential ownership where it provides a concrete benefit. No root daemon is required for the first per-user Mac profile.

For local interpretation, benchmark a compact grammar/statistical baseline against a trained DistilBERT profile. The latter remains required for the requested full demonstration; 'state of the art' does not justify silently replacing the user's chosen proof-of-concept component. No cloud LLM is needed to parse a small command vocabulary.

For Zigbee, one complete ZNP backend is a reasonable first candidate, with EZSP/ASH an alternative independent backend. This is not a shopping endorsement of all hardware using a chip family. The exact coordinator, firmware and detector combination still needs physical evidence.

## Remaining decisions

Exact detector fingerprint and coordinator procurement; Home IR/model implementation and the positive basis for restricted admission; precise supported Zigbee/Matter specification revisions; device-specific TLS/credential behavior; trained intent checkpoint and supported languages; Mac distribution identity/host permissions; Nerves target/native binary qualification; and manufacturing/conformity evidence. Each remains an explicit gate rather than an assumed solved dependency.
