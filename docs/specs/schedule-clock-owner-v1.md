# Private temporal clock ownership v1

Version: 0.1.1. Implemented host custody and actual Store binding, 2026-10-08.
WOH.04 owns temporal confidence; WOH.08/WOH.09/WOH.19 own actual host clock
qualification. This slice installs no source by default, offers no public clock
upload and creates no schedule activation, occurrence, intent or physical write.

The clock owner is a host-owned OTP process without SQLite or an operator
bearer. Its trusted constructor identifies one actual Store and an independent
foreground approval PID. The Store supplies its current deployment, owner,
authority epoch, random Store boot epoch, clock generation, monotonic origin
and full compiled Home runtime digest under
`wotex-home.schedule-clock-runtime.v1`. Read-only bootstrap validates active
controller history and retained schedule content. Quarantined, retired,
unwritable or unavailable Stores provide no temporal binding. Construction
cannot accept a caller-created scope or independently chosen clock origin.

A private 0400 policy file uses the existing sealed private-file reader. Its
[temporal source policy](schedule-clock-source-v1.md) must match the actual
runtime. The private request root is a canonical nonsymlink directory, mode
0700, sealed to device/inode/owner/mode, with fewer than 64 existing children.
The owner creates one new private directory and immutable request file containing
its original random 32-byte nonce and complete Store/source/policy scope.
It never restores confidence from existing request files or deletes them to
make room. Policy, request and accepted response preserve independent descriptor,
path, content and ancestor seals. Root and file custody are repeated around
runtime checking; identical bytes at a replacement inode do not regain trust.

Only the original approval PID may inspect the request or submit its signed
response. A wrong request digest conflicts without renewing the challenge.
Invalid signature, scope, timing, private publication or custody consumes that
challenge permanently. Exact accepted retries return its original state and
retain start, receipt, bounds and expiry. The signature binds an explicitly
trusted local source policy; synthetic test policies do not qualify a real host.
Installing the policy and signer trust, RTC/setup accuracy, monotonic behavior,
sleep/correction detection and oscillator bounds require the actual host procedure.

The owner checks both its latest wall/monotonic deltas and cumulative deltas
from the original anchor. OS wall values are used only to withdraw continuity;
they never establish trusted UTC. The policy's permitted undetected discontinuity
is conservatively included in both UTC endpoints, alongside signed-source error
and ceiling-rounded drift. A changed runtime, root, file, rollback, correction,
response deadline or total age permanently expires that process's confidence.
Returning an OS setting or file to its original value cannot reactivate it.
Periodic checks are bounded to one owner check per second; every sample request
repeats the complete current checks, independently of that timer.

The original Store alone may obtain the owner's binding or sample. Attaching
requires an accepted source and exact original Store/runtime/boot/origin/
generation correspondence; an installed source cannot be silently replaced.
The Store advances the returned original sample again at its own current
monotonic time after the owner reply. Source failure clears that owner and
advances the boot-local clock generation once. No source means an explicit
unqualified sample with null UTC/qualification and discontinuous monotonic state.
Trusted host wake/correction withdrawal clears the owner and advances generation;
reinstallation needs a new original challenge. Generation exhaustion blocks
temporal binding while leaving ordinary manual storage available.

These seams are trusted host operations, absent from the public local API.
They change no authority revision, active rule generation or durable receipt.
The durable active-schedule and execution layers must still bind this generation
and repeat time guards at reservation, queue, claim and handoff. Clock ownership
alone cannot enable countdown admission or timers. Expiry currently requires a
fresh host source/challenge; continuous qualified RTC renewal and foreground
installation delivery remain host integration work.

Accepted source custody survives the independent foreground approval caller's
exit until its original age deadline. An unapproved challenge loses approval
on caller exit. Actual Store death stops the owner; a new Store boot gets a new
boot epoch and challenge. Existing private files remain historical evidence,
never restart authority. A source bound to another Store cannot attach even if
it presents plausible synthetic identities. Owner status redacts private state.

Sixteen actual-file/Store/process cases cover default unqualified time, immutable
accepted sample/retry, caller restrictions, invalid response consumption, policy/
request/response and whole-directory replacement, runtime restoration, wall
correction, rollback, cumulative small corrections, explicit wake withdrawal,
strict age/response deadlines, continued unrelated manual storage, foreground
exit, actual Store death/restart, wrong-Store and replacement attachment and
unsafe/missing policy construction. They establish software custody and lifecycle,
not actual clock, signed-host, storage interruption or physical qualification.
