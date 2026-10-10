# Native paired session v1

Version: 0.1.2. Owner: WOH.08 H08-09/H08-T9, WOH.15 H15-07/H15-T8. Status: production selected factory implemented; pure correspondence/private CAS and actual unsigned refusal pass; original-purpose factory and closed consumer implemented separately; installed signed success and shared capture/UI integration pending.

This composes [public associations](native-controller-associations-v1.md),
[actual signed app custody](native-paired-keychain-v1.md),
[authenticated current scope](controller-session-scope-v1.md) and
[bounded exchange guards](native-controller-exchange-guards-v1.md).
It adds no API route, Store schema, permission or physical qualification.

## Selected factory

Only a production factory that obtains actual signed protected-app access,
reads the exact existing SecItem and performs the actual pinned TLS scope
exchange can construct a selected paired session. Its constructor is private;
there is no decoded-scope, raw-key, injected successful backend, directory or
asserted-success initializer. Public metadata and pure scope correspondence
never create a session seal. Construction and use disclose no bearer through
description, debug, reflection, serialization or logs.

The caller retains a full original association snapshot with a remote selection
present in its records. Validate the record's complete codec. Obtain the actual
app access seal before sensitive account work, then verify the original account
snapshot before reading that association's existing Keychain item. Missing,
unsafe, replaced or changed selection/custody refuses; do not create an absent
account directory, import an item, repair a file or select a local fallback.
An unsigned process refuses before account inspection, SecItem or networking.

The existing-only snapshot check uses the fixed production account directory
and the original descriptor/full-content/inode CAS under its nonblocking lock.
It performs a no-op publication, preserving file bytes and revision. A separate
directory-taking foreground fixture can check metadata CAS but cannot construct
a signed session. Endpoint or label editing, changing any row, and changing
selection invalidate the complete original snapshot, including edits away and
back. Merely retaining the same immutable association ID is insufficient.

Custody acquisition runs off the socket/deadline executor with a five-second
absolute continuous deadline captured at entry. A private synchronized material
slot discards cancellation, expiry and late platform completion; late work
cannot publish a credential or continue the factory. Original signed access
is reused, never refreshed to extend its lease. Session lifetime is bounded
by that same continuous deadline and original signed access. A later explicit
operation requires a new factory acquisition; cached sessions cannot renew.
The domain adapter receives that same absolute owner deadline. Its request
and completion owners bound blocked clock production and SDK work before I/O
as well as each exchange and final typed delivery; none gets a fresh budget.

## Scope and exchanges

The actual typed `controller_scope` request uses the retained pinned peer,
exact existing credential and an explicit trusted certificate-clock producer.
No zero-uncertainty system-clock default or remote clock field substitutes for
that producer. Require exact deployment, owner, epoch and paired principal;
the observed revision is at least the original association creation revision.
Current permissions and targets must be subsets of the original approved
access. Widened or mismatching scope refuses. Expose only this authenticated
projection for presentation; historical approved access cannot enable controls.
Every later server operation retains its independent current authorization.

At opening, immediately before sending, after validated response and after
typed decoding, the bounded executor repeats actual original app/seal custody
and complete account snapshot CAS, before and after credential verification.
All checks use the original continuous deadline. A failed check after possible
send remains `outcome_unknown`; retain any operation original rather than
retrying, clearing it or publishing success. Cancellation and late completion
cannot deliver a scope, session or typed result. No bearer can reach UDS or
the local target broker from this operation-local remote transport.

Only explicit calls construct or use a session. Loading the document, app
startup, menu opening, selection and window lifecycle perform no Keychain,
TLS, discovery, receipt lookup or mutation. An unavailable remote remains
selected and unavailable. Shared window/menu models and paired original
capture/recovery are separate successors. The [original-purpose factory](native-paired-recovery-v1.md) now shares actual
signed acquisition and bounded exchange machinery while fixing one journal
entry/action and both snapshots. Its consumer exposes no generic mutation and
preserves the original lease across exact cancellation publication. It chooses
the journal association irrespective of UI selection; this selected factory
cannot substitute for that purpose or clear a paired pending row.

## Required evidence

Check real private-file no-op, full-content/inode CAS, unsafe/missing custody,
selection and metadata changes, cross-process replacement/restart and lock
capacity. Independent literal scope vectors cover exact identity, revision
floor, narrower current grants, substituted authority/principal and widened
permissions/targets. These pure comparisons establish no signed session.

The actual production factory in an unsigned process must refuse before
account inspection, SecItem, clock production or networking, without an
injected successful platform backend. Check pre-cancelled selection and the
unchanged local, TLS, guard, Keychain policy and pending refusals. Signed
positive construction, locked/denied items, stale installed custody, fresh
account restart and macOS 15 interoperability require the actual installed
signed app/profile and host. Compilation or synthetic scope/transport results
cannot establish those gates. Physical dispatch remains default-disabled.

## Development evidence

`mix woh.native.paired.session.smoke` compiles the actual selected factory,
Keychain, file and typed transport sources with Swift 6 warnings as errors.
Five independently authored scope projections pass; twenty substituted,
widened, unordered, duplicate or stale scopes and one corrupt association
refuse. These comparisons cannot create a session. Actual production factory
calls refuse the unsigned process with the closed signed-custody denial before
the fixed account snapshot check, SecItem, certificate-clock producer or a
listening loopback socket. Local/missing selection and pre-cancellation also
refuse. No injected successful platform backend or credential/session seal is
used, and the operator's account files/Keychain are untouched.

Four owner-deadline checks cover held SDK work, held clock production,
cancellation and an already-expired entry. Held work is released only after
its owner has returned; no late guard opening or result is delivered. They
use explicit raw-key foreground transport fixtures, never the production
signed session constructor. The full domain task retains seventeen original
and sixteen guard cases, with thirty-two actual Authority/UDS/TLS comparisons
now exercising the optional completion owner. Full app typechecking, original
Keychain policy and local paired-journal recovery refusal also pass.

The association smoke repeats existing-only no-op checks over real private
files, stale content/inode custody, missing/unsafe directory and lock capacity.
A separate process changes selection away and back; a metadata edit and return
also restore the same record content. Both still invalidate the full original
snapshot. Twenty competing publication races and fresh-process reload/checks
pass. The factory's bounded executor is the existing guard mechanism with
independent held/cancelled/expired real peers and late-completion refusal.
The original-purpose smoke also compiles this shared factory and verifies actual
unsigned refusal with either local or another remote selected. Its real-owner
transport checks establish adapter behavior, not successful signed acquisition.
These are development Swift 6.4/macOS 27 checks targeting macOS 15. They do not
prove successful installed signing/SecItem/session construction, installed
late credential completion, macOS 15 TLS or a physical effect. Shared models,
paired original capture/recovery composition and an owning trusted host-clock producer
remain successors; there is no default clock producer in this factory.
