# Authenticated controller identity read v1

Version: 0.1.0. Accepted mechanism, 2026-10-07. WOH.15 owns this
transport-independent read. WOH.08 uses it to bind client recovery to the
controller that originally accepted a request.

`Authority.controller_identity` authenticates an existing 32-byte application
credential through the single Store. Every registered active principal may read
its own identity context, including a zero-target diagnostic, maintenance or
transfer principal. This read grants no other permission or target and never
provisions or reconciles a principal. Revoked, unknown and malformed credentials
fail through the ordinary authentication boundary.

The result has exactly five fields: `deployment_id`, `owner_id`,
`authority_epoch`, `store_revision` and `principal_id`. Deployment and owner are
the existing 64-character lowercase hexadecimal controller identities. Epoch is
a positive signed 64-bit integer, revision is a nonnegative signed 64-bit
integer, and principal is the authenticated stored Home ID. Return the current
Store watermark, not a principal's original creation revision. Omit credential
bytes/verifiers, grants, permissions, driver endpoints, host paths and retained
transfer documents.

The Store repeats its complete controller head/history gate and accepts only an
active owner. Source retirement, recovery quarantine and corrupt ownership
history refuse this ordinary read. An active controller in maintenance may be
identified; the result makes no claim about writability, qualification, physical
isolation or dispatch. This use case opens no SQLite connection, creates no
transaction, journal event or revision and changes no durable schema.

The private framed API accepts exactly `api_version: 1`,
`operation: "controller_identity"` and `credential` (the existing canonical
43-character base64url encoding). A successful response has exactly
`api_version: 1`, `outcome: "ok"` and `controller_identity` with the five fields
above. Use existing bounded framing, peer checks, read deadline and closed
error envelope. Extra fields, caller-supplied identity/role and trusted native
setup requests are refused. No ordinary route exposes
`native_setup_identity` or `ensure_native_principal`.

Clients compare deployment, owner, epoch and principal under the captured
original credential before recovering or retrying a retained operation.
Revision is a read watermark rather than stable controller identity. This read
does not make a retained request valid, renew a review, establish current grants
or replace each mutation's Store guards. A mismatch or failed authentication
must preserve the unresolved original; it cannot select another principal,
rewrite the request or generate a replacement operation ID.

Required evidence: actual Store/Authority and framed parity, zero-target and
separate-role access, revoked/unknown/malformed credential refusal, closed
request fields, absence of trusted setup routes, unchanged revision and journal,
persistent identity across restart and distinct identity on an independent
Store. Source retirement must refuse the read. These are software checks, not
installed credential custody or physical qualification.
