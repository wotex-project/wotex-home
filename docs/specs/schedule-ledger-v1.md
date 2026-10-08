# Retained temporal admission content v1

Version: 0.1.2. Schema-24 review/admission history and authenticated adapters, 2026-10-08. WOH.04 owns
the separate temporal profile; WOH.14 owns this transaction; WOH.16 owns
archive compatibility. Autonomous activation, clock ownership and occurrence
execution remain work following this inactive content ledger.

The single Store owns `schedule_admissions`. Ordered columns are principal ID,
authority epoch, operation ID, kind (`review` or `admit`), expected Store revision,
exact canonical operation document, complete admission artifact, artifact SHA-256
and publication revision. The primary key is original principal/epoch/operation;
publication revision uniquely references its authority journal. `schedule_reviewed`
and `schedule_admitted` events bind the exact original scoped identity in both
directions. Review returns `reviewed`; admission returns `admitted`. Neither
sets an active pointer, advances rule generation, creates held intent nor
registers a timer. Explicit invocation cannot consume temporal artifacts.

New content requires current authenticated rule-review, rule-management and
ordinary-control permissions, the exact target grant, usable declaration and
profile bytes, current epoch and revision CAS. The declared source author must
equal the authenticated stable principal; its resource revision must equal the
declaration's actual resource revision, independently of global enrollment
revision. Complete declaration, portable selection and invariant pins are captured
inside that transaction and passed to the independently bound
[temporal artifact](schedule-admission-v1.md). Calendar bytes are trusted
host-owned inputs to this internal Store seam; there is no public caller-byte
timezone route. Countdown retention refuses until actual qualified clock
ownership can establish its original boot/generation. Qualified time and physical
qualification are not manufactured by retaining an interval/calendar definition.

The [Authority, framed API and CLI](schedule-api-v1.md) now expose this
inactive content workflow. New calendar operations load the exact pinned bytes
from bounded host-owned timezone custody. Existing exact operations are resolved
before any replacement timezone read or review-capacity reservation. The host
timezone query returns calendar choices without establishing clock confidence.

New history is bounded to 1024 rows and 8,388,608 combined UTF-8 bytes of original
operation and artifact documents. Capacity is checked before journal publication.
No history is silently truncated or compacted. Capacity refusal retains all
original receipts and does not advance the Store. Existing exact retries still
return their immutable original receipt at capacity, during maintenance or after
target-grant loss; changed input or kind conflicts. Principal-private exact
lookup requires a current authenticated review permission, performs no new
review, needs no current target grant or timezone and changes no revision.
Source retirement permits this original read but rejects new content.

Historical validation checks canonical input/artifact/digest correspondence,
original author and complete source/effect joins, resource/invariant/profile
revisions preceding publication, current revision/epoch ceilings, principal
existence and exact journal correspondence. Every ordinary Store transaction
validates the retained history before and after its mutation. Damage rolls back
the mutation and disables writing. Current admission separately repeats original
author permissions/grants, authority epoch, complete declaration/profile/invariant
and runtime. Returning a current artifact still grants no activation or effect.

Schema 23 migrates transactionally to an empty ledger without changing existing
principal, epoch, revision, generation, rule pointer or receipts. Unexplained
temporal journals fail the new validator and roll back the actual DDL and version.
Retired sources are refused before migration. Encrypted archive verification
uses exact schema-specific table sets for versions 4–24, validates all retained
content and keeps restoration quarantined. Owner-transfer retention includes
this table and normalizes an empty table for supported older source schemas;
transfer preserves original rows while retiring their author authority.

Fourteen focused actual-Store cases cover review/admission and exact retry,
principal-private missing/recovery lookup, altered original input and kind,
author/revision/resource refusal, unavailable countdown clock, complete calendar
bytes, maintenance, injected multi-row rollback, restart/quarantine, live/startup/
encrypted-archive damage and ordinary-write guards, schema migration/rollback,
the actual 1024-row ceiling and the aggregate byte ceiling reached earlier with
a bounded synthetic timezone. A separate actual owner-transfer case retains
nonempty temporal history and rejects current use by its old author. These are
software integrity and interruption cases, not installed clock, storage power-loss,
signed-host or physical qualification.
