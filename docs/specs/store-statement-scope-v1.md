# Store-call SQLite statement reuse v1

Version: 0.1.0. Implemented software boundary, 2026-10-09.
WOH.14 owns single-writer execution and borrowed transaction boundaries.

The single Store opens one bounded statement scope for each synchronous
GenServer call, including recovery and retired reads. The scope belongs to
that process and exact SQLite connection. It retains at most 256 compiled SQL
statements until that call returns or unwinds. It never opens another database,
starts an owner process or exposes a resource to an adapter or device worker.
Startup, asynchronous worker-loss handling and other connections retain their
ordinary prepare/release behavior. Nested internal scopes for the same
connection borrow the outer scope; another connection has separate cleanup.

Only compiled SQL is reused. Each query still binds every supplied parameter
and executes against SQLite. It sees current rows, tentative writes, savepoint
restoration and rollback according to the original transaction. All authority
history, qualification, runtime-file, temporal and final commit checks remain
in place. Rows, clock readings, manifests, custody or authorization decisions
are never cached. This changes no schema, migration, journal, receipt identity,
transaction disposition or physical-dispatch setting.

A checked-out statement is absent from the reusable map while it executes.
A successful query resets it and overwrites all parameters with null before
returning it. Prior text or BLOB bindings cannot remain in an idle reusable
statement. A failed prepare, bind or execution cannot populate the scope; any
checked-out statement is finalized before the error or exception propagates.
Capacity exhaustion falls back to preparation and immediate finalization,
without skipping SQL or widening the bound. SQLite's locked prepare-v3 path
rechecks a changed schema when stepping; newly installed triggers still apply.

Cleanup removes the scope and explicitly finalizes every retained statement
before Store replies or terminates through its callback return. Exceptions,
throws and catchable exits unwind the same cleanup. No statement or connection
is retained by this helper across a reply, retry or restart. Abrupt VM/process
death still depends on the underlying NIF resource destruction and existing
host/storage qualification; these bounded tests do not establish power-loss
survival.

The optimization is independent of the [power routing budget](power-routing-budget-v1.md)
and [final execution guards](power-commit-v1.md). Runtime qualification binds
the changed Home code as usual. It supplies no new device authority, transport,
autonomous admission or installed-host qualification.

Thirteen actual SQLite/Store cases cover current-row reads, independent text,
BLOB, number and null bindings, connection/process isolation, nested scope
ownership, changed schema/triggers, savepoint and whole-transaction rollback,
bind/prepare failures, exception/throw/exit cleanup and capacity exhaustion.
The affected durable, recovery/retirement, final-guard, original-advancement,
temporal-owner and independent UDP runs passed 293 distinct cases. Formatting,
warnings-as-errors compilation, the indexed 19-contract and working 20-contract
catalogues, 32 changed-document local references and Git whitespace checks
passed. An initial recovery CLI case failed because the child Mix command
compiled changed test-environment source into its expected JSON output;
compiling that environment first and rerunning all 76 selected recovery cases
passed. No dependency changed.

A private OTP call-time trace against the preceding committed source prepared
6,552 statements before the default-window handoff. The reuse prototype
prepared 858 while still executing 6,552 queries and 56 complete runtime
inventories. Preparation time in those individual traces fell from 96,646 to
22,483 microseconds; profiled handoff samples were 3,077 and 2,793 ms. These are
single local samples, not a host latency qualification. The unprofiled candidate
reached the independent peer at 1,920 ms in the default ten-second window.
The exact one-second expiry case still refused before a set. A separate positive
moving one-second attempt failed with the original occurrence rejected as
expired; its independent peer timed out awaiting the absent set. The minimum
window remains unfinished. Production code widens no window or deadline.
