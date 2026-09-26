# WOH.15 — Headless API and controller authority

Version: 0.1.2. Status: accepted target. Named operations below are contract names, not existing Elixir exports.

## One semantic service

**H15-01.** Provide versioned operations for discovery sessions, candidate inspection, enrollment, capabilities, snapshots/history, command submission/status, draft validation/qualification/activation, automation suspension and maintenance. The Elixir API, CLI, native shell and network facade consume this boundary. No client opens the database or writes vendor packets directly.

A mutation envelope includes API version, operation ID, authority epoch, expected resource revision, exact targets, typed input and deadline. Identity/credentials come from the authenticated channel, not a caller-supplied role field. Authentication, capability validation, policy and guards precede durable admission. Return a typed rejection or receipt, not an unqualified boolean success.

The initial internal store boundary issues a random 32-byte credential during trusted local principal provisioning and persists only its SHA-256 digest, closed permissions and target grants. Enrollment persists a validated bounded Thing declaration. Request staging authenticates the credential and derives the Thing, permissions, revision and authority epoch inside one writer transaction. Revoked principals cannot submit or read receipts; revoked Things cannot stage new work. These in-process provisioning operations must not be published as unauthenticated API routes. No network or IPC facade and no physical command admission exist in this slice.

**H15-02.** Initial admission ceilings are 64 KiB per command, 1 MiB per paginated snapshot page, 100 items per page, 32 pending requests per session and a five-second ordinary request deadline. These are conservative design defaults, not measured device limits. Device, pairing and proof operations use explicit separate deadlines. Input is bounded before allocation; reject duplicate JSON members, excessive nesting and unknown operation fields. Future changes are versioned and tested at each boundary.

## Snapshots and streams

**H15-03.** A snapshot has an authority epoch and store watermark. Events carry monotonic service cursors, not device timestamps as cursors. Reconnection resumes a retained range or receives `resnapshot_required`; it never silently skips a gap. A revoked session cannot continue reading a formerly authorized stream. Each subscriber has bounded credit/queue state; slow consumers disconnect or receive an explicit gap. Command outcomes remain queryable independently of stream loss.

## Local and remote transports

The macOS baseline uses a private Unix domain socket as specified in WOH.08. An optional LAN HTTPS facade uses explicit local enrollment and credentials. A trusted local CA or pinned peer identity may be used; certificate verification is not disabled to simplify setup. Plain device protocols behind the controller do not justify plaintext administration.

**H15-04.** Matter, Refpath and future external tools submit structured requests under restricted principals. They cannot invoke raw code, choose model include paths, extract keys or call driver methods. Structured requests bypass only natural-language classification, never policy. HTTP/IPC or Matter acknowledgement cannot falsely announce completed physical effect.

## Transfer and restart

**H15-05.** At most one controller owns a deployment's mutating driver connections. Local process locks prevent a duplicate instance on the same host. A database epoch alone cannot fence a second computer talking to an unauthenticated bulb. Cross-host transfer must quiesce and revoke/isolate the old writer, stop its device channels, transfer current state and credentials through an explicit workflow, then enable the new writer. If isolation cannot be established, transfer remains blocked. Network-level fencing, where used, must be tested rather than assumed.

The authority epoch identifies this fenced controller ownership and changes only when ownership is explicitly transferred or recovered. Rule activation advances a separate active-rule generation under WOH.04. Operation IDs are scoped to a principal and authority epoch; a stale epoch is rejected even when the rule generation has not changed.

There is no automatic promotion during a network partition. A second Mac or Nerves gateway may inspect through authorized read APIs; it does not reconcile actuators independently. Legacy devices may also be changed by an external app or physical switch; Home reports and arbitrates those changes instead of asserting exclusive ownership it cannot enforce.

## Acceptance

H15-T1: all command entry points produce the same policy result. H15-T2: duplicate IDs, wrong epoch, revision races and revoked credentials. H15-T3: stream overflow/resume gap and read-only API tests. H15-T4: the UI exits while the admitted background host continues. H15-T5: attempted second-host takeover without fencing fails. H15-T6: no raw driver, database or key-export route is reachable through a public facade.
