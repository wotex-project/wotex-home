# Original schedule operations v1

Version: 0.1.1. Closed inert correspondence, 2026-10-08. WOH.04 owns temporal
admission and WOH.14 owns durable lifecycle. These bytes supply neither.

The canonical compact UTF-8 array starts with
`["wotex-home.schedule-operation.v1", kind, ...]`. Ordered fields are:

| Kind | Remaining fields |
| --- | --- |
| `review`, `admit` | authority epoch, operation ID, expected revision, complete schedule source document, complete rule document |
| `activate` | authority epoch, operation ID, expected revision, admission revision |
| `suspend` | authority epoch, operation ID, expected revision |

The outer array is at most 8192 bytes and seven scalar members; strings are at
most 4096 bytes. Objects, nested arrays, floats, negative or oversized integers,
expanded fields and noncanonical bytes refuse. Epoch is positive; expected
revision reserves headroom for its successor. Admission revision is positive
and no greater than expected revision. SHA-256 binds the entire original input,
including kind, epoch and revision, for a future authenticated durable operation.

Review/admission inputs contain the exact canonical
[schedule source](schedule-source-v1.md) and one complete canonical rule of at
most 2048 bytes. The source rule digest is SHA-256 of those exact rule-document
bytes, distinct from the compiler's domain-bound source commitment. Rule and
target identities must join. The effect is one absolute Boolean Light power
value, literal-true predicate, ordinary automation authority, block on unknown,
one-millisecond ownership, zero cooldown and causal budget one. The existing
explicit trigger syntax carries this inert effect body; it creates no explicit
admission artifact and cannot attach timers to the explicit admission profile.
Independent temporal proof and current declared Light semantics remain required.

Four focused tests cover independent Python canonical bytes/digests, complete
effect/source joins, altered author and revision commitments, effect changes
requiring a successor digest, unsupported grammar and bounded alternate-input
refusals. They establish codec correspondence, not durable admission, author
authorization, qualified time or execution.
