# ADR 0010 — Portable data before executable helpers

Status: accepted target decision, 2026-10-03. External profile admission is
planned; the existing component runner remains an optional development preview.

Deliver immutable device-profile data independently of Home when it selects
already reviewed host semantics. Reuse the existing Home rule source/compiler
and Store admission lifecycle for portable automation definitions. Keep WIT as
the binary interface for optional executable helpers, under ADR 0009; do not
require a Wasm engine for ordinary local control or data-only profiles.

The first profile format selects an exact reported LIFX fingerprint and the
existing narrow direct-power binding. Home derives capabilities, risk, units,
freshness limits and protocol operations from its closed binding catalogue.
The author cannot supply endpoints, permissions, qualification claims, packet
templates, expressions or module names. Adding an unknown binding or semantic
capability requires a reviewed host release. TD/TM interpretation remains owned
by WoTEx; this format selects a Home binding rather than inventing a second TD
language. Wider declarative mappings need their own correspondence argument.

One Authority sequences import, review, qualification and selection. One Store
owns durable artifact identities, target selections, generations, trust-policy
decisions and revocation. Filesystem staging has no active pointer. A digest or
publisher signature proves neither device identity nor physical meaning. Any
profile change requires a new current review and qualification; existing grants
cannot expand to new operations without a separate authorized grant decision.
Imported rules are reviewed and activated separately from a profile package.

Use explicit local digest approvals for the first admission policy. Automatic
publisher discovery, a registry and TUF-based distribution are later features,
not runtime dependencies. Keep update-metadata freshness separate from a
retained local approval: an offline Home cannot learn an unseen revocation, but
an observed revocation must fence affected work. Never ignore expired metadata
to admit an update. Rollback selects retained bytes through a new authorized
generation and never restores old credentials, freshness or spent effect roots.

Keep the implemented import-free WIT preview as feasibility evidence. Promote
an executable helper only for a named mapping that data plus an existing binding
cannot express, with a demonstrated benefit over a reviewed host binding release.
Before production, close native retirement/capacity, allocation containment,
publisher/custody and actual host qualification. A new driver world or WASI
import is a separate decision; the preview does not justify a generic plugin
application host, runtime Elixir code loading or a common physical-effect router.

This reconciles both research directions: independent delivery improves Home
without adding an execution engine to every profile, while WIT supplies a
language-independent option where computation is actually needed. Keep the
existing complete Home/UDP qualification digest until narrower dependencies
are independently justified. See [WOH.18](../specs/WOH.18-portable-profile-admission.md),
the [consolidated research](../plans/extension-consolidation.md) and the
[build plan](../plans/portable-profile-admission.md).
