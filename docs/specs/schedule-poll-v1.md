# Prepared occurrence calculation outside the writer v1

Version: 0.1.2. Implemented schema-27 Authority/Store polling boundary, 2026-10-09.
WOH.04 owns temporal admission, WOH.14 the transaction and WOH.16 recovery.

The separate [durable countdown lifecycle](schedule-countdown-lifecycle-v1.md)
adds original-boot/generation continuous-clock consumption and missed expiry.
It retains the current artifact scope and introduces no autonomous runner.

The trusted Authority `consider_schedule` use case calculates one bounded
[consideration](schedule-occurrences-v1.md) outside the SQLite writer. It first
obtains the Store's current activation, complete admitted artifact, cursor,
qualified private clock snapshot and exact installed timezone. The caller
supplies no source, author, credential, coordinate or clock. Preparation observes
sticky authority-basis withdrawal before returning a snapshot.

Active preparation shares one complete Home/UDP
[guard inventory](runtime-guard-inventory-v1.md) only during its transaction.
Fresh complete opening/closing comparisons surround the current checks; the
closing comparison precedes savepoint release and creation of the caller-bound
slot. A changed or unavailable runtime retains the exact generation's withdrawal
after restoration and returns no preparation. Barrier failure rolls back and
disables the writer. A lifecycle-head/generation query chooses this inventory
strategy but authorizes nothing: every writer guard still runs. Inactive
polling returns only negative status without requiring a runtime inventory,
creating a reference or retaining an inventory across calls.

The Store retains one preparation in memory, identified by an opaque BEAM
reference and bound to the calculating process. It monitors that process and
uses its own monotonic receipt clock for a five-second maximum lifetime measured
from the original snapshot, including validation time.
Another preparation returns `schedule_poll_busy` until consumption, cancellation,
caller death or expiry frees the slot. Only the original process can consume or
cancel its reference. Wrong-caller attempts do not steal or discard it. Authority
cancels in an `after` clause; process death also clears it without a database
transition. A new preparation clears an expired slot. No preparation survives
Store restart, retirement/transfer or archive restoration as current authority.

The calculated record grants no authority. Commit consumes the reference once
and uses the Store-retained basis, rather than any basis returned by the caller.
It checks the exact closed record, original activation/cursor and canonical
correspondence, including equality with the Store's original clock document.
A forged qualified clock, coordinate, missed range or watermark therefore
cannot replace the private input. Calculation correspondence is checked again
inside the writer; original calculation and recurrence selection happen in the
Authority process outside the transaction.

The transaction repeats current activation/artifact, author/target/basis,
considered-through cursor, clock scope/confidence, nondecreasing Store monotonic
time and installed timezone before publication. A competing consumption or
changed activation refuses the stale preparation. Existing occurrence/cursor
CAS, held-intent and causal provenance publication is shared with the existing
direct trusted Store poll. The owned clock and exact current activation/artifact
are repeated after publication. A separately typed final guard repeats current
basis/clock, the held effect's temporal window and preparation lifetime after
history validation, immediately before the enclosing commit. A confirmed epoch
or generation fence permits the existing withdrawal barrier to commit without
granting the old preparation current authority. Newly discovered sticky
withdrawal therefore commits even when it invalidates the preparation. SQL or integrity
failure rolls back the complete occurrence, request, root, journal and cursor.

An empty calculation changes no revision or history. A failed, expired or
cancelled preparation cannot be reused; a later fresh preparation reads the
current cursor. Lost replies and caller/Store restart cannot rewind consumption
or create a second held request. The prepared basis contains no SQLite handle
or bearer. There is no schema change, clock upload, public polling facade,
autonomous timer, physical command or broader admission proof in this boundary.
[Store-owned advancement](schedule-advance-v1.md) separately queues or
terminalizes retained unsent work. Composed runtime proof, native countdown creation,
cursor-preserving compaction and installed-clock qualification remain work.

Software cases cover actual private-clock Authority polling, empty polling,
one-use and wrong-caller refusal, competing consumption, caller death,
cancellation, expiry and renewal of the bounded slot, forged clock/cursor data,
current-author loss, clock loss, publication rollback and old-reference refusal
after actual Store restart. Controlled clocks at the actual borrowed SQLite
transaction's final guard independently exercise preparation expiry, a closed
late window and loss of clock confidence after publication. Selected-profile
byte loss at prepared commit retains the withdrawal barrier; immediately
restoring the exact bytes does not resume the schedule. Snapshot integrity and
original receipts are checked. These cases establish software correspondence,
not installed clock/host sleep, physical actuation or target-storage power loss.

On 2026-10-08 the locked full Mix suite passed 1148 tests with zero failures;
four opt-in component cases were skipped. Real socket and foreground-host cases
ran. The earlier affected transition run passed 160 tests; after final-guard
integration, its six targeted publication/profile cases also passed.
Warnings-as-errors compilation, formatting, all 20 workspace and 19 staged
contract metadata checks, changed-document references and Git whitespace
validation passed. The existing support-file load-filter warning remains
unrelated to this mechanism.

On 2026-10-09, the active-preparation inventory change passed 121 distinct
affected occurrence, profile archive, temporal admission/lifecycle, clock-owner,
delivery and owner cases. Four opening/closing runtime-loss and SQL-fault cases
check no reusable snapshot or occurrence, exact withdrawal, original revision
rollback, stopped-writer classification and complete snapshot integrity.
Inactive status still needs no runtime proof and creates no slot while files
are missing. One-use ownership, wrong-caller, expiry, cursor substitution,
cancel/death/restart and commit-side guards remain covered by the existing
actual Store suites. These are software checks, not autonomous admission or
installed clock/device evidence.
