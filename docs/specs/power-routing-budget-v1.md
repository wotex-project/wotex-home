# Bounded private power routing v1

Version: 0.1.0. Implemented software boundary, 2026-10-09.
WOH.03 owns transport/report meaning and WOH.14 owns guarded execution.

The private explicit and scheduled power paths share the selected-interface
capture owner. Their closed `home-lifx-power-routing-v1` policy allows 200 ms
for fresh broadcast discovery and, for held work, 200 ms for one correlated
`GetColor`. The owner budget is 500 ms and the caller timeout is 1,000 ms.
Callers cannot widen these values. Time waiting in the owner mailbox consumes
the original budget; insufficient time refuses before a packet or source
sequence reservation. Discovery must leave the complete read budget, and a
returned route must still precede the original deadline. Ordinary authenticated
refresh retains its separate two-second discovery and read windows while also
carrying its original owner deadline through the exchange.

Discovery still requires exactly one in-scope endpoint for the enrolled stable
identity. Collision, wrong identity, wrong correlation and late replies cannot
produce a command route. Held work reserves distinct report/readback producer
sequences; queued recovery discovers only routing and preserves its sealed
report and producer continuity. A route contains private transport/correlation
data, never temporal authority. Store-owned scope, report publication, queue,
claim and committed handoff guards remain required. A failed transport callback
must return within its requested deadline; post-return checks cannot unblock
a stuck callback. The complete Home runtime digest binds the policy, so changed
software requires a new exact qualification decision before physical dispatch.

Runtime artifact verification now keeps a bounded process-local memo of parsed
BEAM code checksums. Each pass still loads and validates current application
metadata, refuses old code, reads and SHA-256 hashes every complete retained
file and compares the current loaded checksum. Only a parsed checksum whose
complete-byte digest matches may be reused. The memo retains at most 2,048
module entries, no file bytes, manifest or authorization. The existing v2
digest convention is unchanged. This reduces repeated parsing without creating
a persistent qualification cache or live-upgrade barrier.

Eight actual local-UDP routing cases passed, using an independent raw-byte peer
in a separate VM. They cover held and queued success, unrelated correlation,
late discovery/read, wrong identity, two endpoint claims for one identity and
mailbox delay before any packet. Warm-artifact cases separately reject changed
disk bytes, changed loaded code, old code and missing files. No physical peer
or installed clock is qualified by these cases.

Two actual Authority/SQLite/UDP cases use the original temporal owner and
qualified software clock. A clock advancing throughout the default 10-second
window reaches committed handoff and independent observed readback; one run
observed the set at 2,045 ms after owner start. A second case advances to the
exact half-open end of a one-second window during report capture and refuses
without a set, source grant, reservation or handoff. Original occurrence
identity and snapshot integrity are checked in both cases.

The minimum one-second window is still not usable by this complete flow. Earlier
moving one- and two-second attempts expired before a set; they do not provide
positive latency evidence. Repeated complete runtime and transaction guards
still consume substantial time after routing. Authorized before-due preparation
or a more efficient guarded composition, followed by actual minimum-window and
race evidence, remains required. No window is widened by production code, and
the successful default-window case does not discharge that obligation.

Fresh-source validation passed 160 cases across artifact/routing, direct-power
and causal-history, scheduled capture/delivery/owner, moving-clock and read
regressions. Real local sockets remained enabled. Formatting, warnings-as-errors
compilation, the indexed 19-contract catalogue and working 20-contract catalogue,
35 indexed local references and Git whitespace checks passed. An indexed-check
invocation initially used an incorrect module name; the corrected check passed.
The prior one- and two-second positive attempts failed and remain counterevidence
to minimum-window usability. Native packaging for this revision is separate.
