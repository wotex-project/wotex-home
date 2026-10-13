# Specification template

This is an authoring scaffold, not an accepted product contract. Copy the body
below into the owning specification and replace every placeholder. Use a
`WOH.NN` identity for a catalogue contract; an owned successor instead names its
parent requirement and cases. Keep implementation order in `docs/plans/`,
host commands in `native/*/README.md` and physical procedures in `docs/labs/`.

A specification is self-contained when a reader can determine its behavior,
limits and acceptance without this chat or a research narrative. Links identify
the owners of shared contracts; summarize the exact inherited rule needed at
each boundary. An unresolved encoding or producer API is an explicit entry
condition, never an invitation to invent a convenient substitute.

```markdown
# {{contract_id}} — {{title}}

Version: {{semver}}. Updated: {{date}}.
Status: {{accepted target or draft}}.
Owner: {{mechanism and parent requirement for a successor}}.
Implementation: {{planned, partial or implemented subset}}.
Evidence: {{actual evidence and its limits, or missing}}.

## Purpose and scope

Describe the observable result and a concrete use case. Name what this contract
owns and which adjacent contracts own persistence, transport, host lifecycle or
physical qualification. State compatibility with the existing public subset.

## Terms and dependencies

Define each term that changes a decision. For every required producer, identify
the owning contract/API, the exact behavior consumed and its current status.
Separate a contract version, source/build digest, data identity and qualification.
State what remains unavailable if a producer or required artifact is absent.

## Inputs, outputs and limits

| Input | Type / unit / bound | Validation and source |
| --- | --- | --- |
| {{name}} | {{exact representation}} | {{caller or host owner; rejection}} |

Define output dispositions, deterministic ordering and identity. Distinguish
requested values, protocol reports, physical evidence and missing/unknown data.
Close the grammar: defaults, unknown fields, duplicates, precision, canonical
encoding and malformed native structs need explicit behavior. Put executable
schemas and vectors in the appropriate runtime/fixture paths.

## Requirements and transitions

**{{requirement_id}} — {{name}}.** State who MUST do what, when and against which
current basis. Define the observable success and refusal.

| State / event | Preconditions | Committed result | Refusal / uncertainty |
| --- | --- | --- | --- |
| {{transition}} | {{exact guard and owner}} | {{identity and records}} | {{typed outcome}} |

Define concurrency, revision/CAS checks and the atomic commit boundary where
applicable. For effects, name separate staging, admission, claim, handoff,
acknowledgement and settlement checks. For pure computation, state which
explicit inputs determine the result and which consumer decisions it cannot make.

## Failure, retry and recovery

Specify lost replies, duplicates, cancellation, timeout, restart, stale inputs,
changed generations, revoked authority and exhausted capacity where applicable.
Logical retry returns the original scoped result; uncertain handed-off effects
are not repeated. Define what is retained, invalidated or quarantined on upgrade,
rollback, backup restore and owner transfer. If no durable state exists, say so
and identify the consumer responsibility.

## Compatibility and implementation entry

List public behavior preserved and deliberate successor changes. State the
concrete schemas, API contracts, migration/backup invariants and independent
vectors required before implementation or admission. A target with unfinished
entry conditions must identify those conditions; prose is not evidence.

## Acceptance

| Case | Requirements | Setup and stimulus | Expected observation / falsifier | Evidence level |
| --- | --- | --- | --- | --- |
| {{case_id}} | {{requirement_ids}} | {{reproducible inputs or race}} | {{pass and concrete fail}} | {{pure / software / installed / physical}} |

Include normal behavior, malformed/boundary input and the failures that could
violate the mechanism. An oracle must compute the relevant expectation
independently of the implementation under test. An implementation-text search,
schema check or passing build does not establish runtime or physical behavior.

For executed evidence retain source/toolchain/build, input/profile/fixture,
environment, command, actual result and artifact location. Keep planned cases
and catalogue implementation/evidence axes separate.

## Sources and decisions

Link the owning contracts and primary sources supporting factual claims. Pin
inspected source revisions. Explain deliberate interpretations and limitations.
Research informs this contract; it does not override its requirements.
```
