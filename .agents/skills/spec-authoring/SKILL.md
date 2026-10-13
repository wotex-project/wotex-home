---
name: spec-authoring
description: Write or review Home product contracts and owned successor specifications, or promote research into bounded requirements and an implementation plan. Use when behavior, ownership, compatibility or acceptance obligations need definition; exclude routine prose corrections.
---

# Author Home specifications

Input: requested behavior, relevant research and current producer/consumer
contracts. Output: self-contained owning specifications, a dependency-ordered
plan and accurate catalogue status. Implementation is a separate stage when
the user requests it.

Read the repository contract, README and
[catalogue](../../../docs/specs/catalogue.yaml). Locate the existing semantic
owner before introducing a contract. Use the
[specification template](../../../docs/specs/spec-template.md) for new contracts
and as a gap checklist for substantial revisions, without reformatting unrelated
specifications.

## Reconcile research with the actual baseline

Read referenced research branches through their Git objects without merging
old product files over current work. Trace the relevant public code, tests and
dependency pins. Separate a proposal, accepted target, implemented subset and
executed evidence. A newer sibling HEAD is not the consumed dependency.

For cross-repository work, read each repository's instructions and write generic
producer contracts there. Home owns its consumption policy and integration
gates. Put dependency order and deliverables in the plan; do not make a missing
producer an unexplained blocker or create its substitute inside Home.

## Make the contract independently usable

Define observable behavior, exact inputs/units/bounds/defaults, output ordering,
identity, errors and state transitions. Name who supplies each fact, clock,
credential or artifact and who can commit it. Describe the inherited rule at
the boundary, then link its owner; phrases such as “existing guards” alone are
insufficient. Examples must identify whether they are accepted input or proposals.

Cover relevant duplicate/lost-reply, stale-basis, cancellation, restart,
capacity, revocation, replacement and recovery behavior. Preserve separate
review, admission, handoff, ACK and report outcomes. Name unfinished executable
schemas, producer APIs or proof profiles as concrete entry conditions. Do not
invent dependency pins, schema migrations or physical evidence.

Map stable requirement IDs to reproducible acceptance cases, including
refusals and an independent oracle. State the evidence level and what would
falsify the requirement. Models and fixtures do not qualify hardware.

## Review and validate

Walk a normal case and one relevant adverse trace using only the proposed spec
and its named dependencies. Resolve missing defaults, hidden assumptions,
contradictory transitions, circular ownership and duplicated semantic definitions.
Update parent links, catalogue versions/cases and the plan together; keep
implementation and evidence statuses unchanged unless actual work justifies it.

Use the matching durable, integration or host workflow when reviewing those
mechanisms. Run the catalogue check, reference/metadata checks and Git whitespace
check appropriate to documentation. Report actual results and remaining entry
conditions. When implementation is authorized, finish this review before code,
then update only the evidence established by the implemented slice.
