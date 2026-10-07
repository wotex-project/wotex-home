# Native core channel v1

Version: 0.1.0. Accepted host mechanism before implementation, 2026-10-07.
WOH.08 owns the native parent and OTP lifetime. This channel carries only the
[trusted native setup records](native-setup-authority-v1.md); it is not the
ordinary socket or an installed-client authentication substitute.

The native agent starts one bundled OTP release with the fixed invocation
`eval WotexHome.NativeSetup.CoreHost.main()`. Two anonymous pipes become that
child's standard input/output. Standard error remains the bounded diagnostic
sink. No secret, verifier, operation body or arbitrary eval expression is a
process argument or environment value. The existing absolute private data
directory selects the Store; the separately explicit selected interface may
enable read-only capture. Physical dispatch remains default-disabled. Neither
the app nor another client obtains these inherited pipe endpoints.

The entry point refuses an already running Home application in that VM, directs
the actual Logger default handler to standard error before starting Home and
starts the normal locked Host/application. It pins the actual Authority Store
PID for the channel's entire lifetime and monitors it. A named replacement
Store is not substituted. It never opens SQLite itself. If startup, Logger
ownership or the original Store is unavailable, refuse the channel and stop
only the application started by this entry point.

Every record is four-byte unsigned big-endian length followed by exactly the
canonical JSON body. Require length 1–4,096 before reading/allocating that body.
The request is only `identity` or `ensure`; all replies use the owning setup
codec. One idle read may wait for the first byte while monitoring the Store.
From that first byte, one original five-second monotonic deadline covers the
remaining header, body, decoding, Authority call and reply. Dripped bytes never
extend it. At most one read/decision worker and one request are owned at a time;
there is no queued request pool. Kill/reap a timed-out worker and close the
channel. The original Store may still commit an enqueued ensure, so decision
timeout is `outcome_unknown` and must be reconciled with the same Keychain item.
It never licenses a new secret or another principal ID.

EOF, incomplete/oversized/malformed/unknown record, original Store death,
deadline or failed reply ends this channel. An invalid complete request may
receive one bounded error record before closure. The entry point then stops
its own Home application, releases Store/socket ownership and exits; it cannot
silently keep an unowned controller running. An ensure policy rejection may
be returned normally and leaves the same private session available. The core
checks the original Store before and after each operation. A reply ending
after its deadline is unavailable. This bounds channel ownership; it does not
promise preemption of a blocked OS write. The native pipe owner must use
nonblocking bounded writes/reads and terminate/reap an unavailable child.

The codec adds only this closed, canonical error record:

```
["wotex-home.native-setup-authority.v1","error",reason]
```

`reason` is one of `invalid_native_setup_record`, `native_owner_changed`,
`native_custody_conflict`, `native_setup_unavailable`, `outcome_unknown`,
`frame_timeout`, `core_owner_lost` or `channel_closed`. Arbitrary SQLite,
exception, request, verifier and credential text is never a wire reason or log.

The signed agent/broker is still responsible for validating its sealed bundled
release before launch, original signed socket peer before frames/custody and
each later sensitive boundary, finite native connection/worker capacity and
actual private Keychain custody. A trusted foreground harness can invoke this
core entry for software checks; it is not an unsigned installed broker bypass.
The ordinary socket retains same-user plus bearer authorization and exposes
none of these trusted provisioning methods.

Software evidence must use independent canonical pipe frames and real child
stdin/stdout, reject oversized and slowly dripped frames without provisioning,
reconcile a committed ensure after a new child starts, keep unknown scope
bounded and show Store/socket lock release after channel failure. Also test
original Store death with an idle read and a named replacement. Installed
signed app/agent, protected bundle/pipe ownership, service shutdown/restart and
locked/denied Keychain qualification remain separate obligations.
