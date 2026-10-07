# Native ordinary API Core peer v1

Version: 0.1.0. Accepted mechanism, 2026-10-07. WOH.08 owns this extension to
[native custody](native-credential-broker-v1.md). The development/manual API
keeps its existing private path, same-user and application-credential boundary.
Native credentials additionally require the actual Core peer before any bearer
frame. A UID match or socket path alone cannot identify that Core.

The signed app can make a read-only broker request
`["wotex-home.native-credential-broker.v1","endpoint"]`. The response is exactly
`[format,"endpoint",deployment,owner,epoch,store_revision,audit_token_base64url]`,
with the same format, validated active controller scope and canonical unpadded
43-character base64url encoding of the kernel's 32-byte audit token. Existing
status/credential/recover encodings and nine-scalar/4,096-byte bounds stay intact.
This record is inert metadata when decoded; it is not a signing/Keychain seal.
Never log the token or serialize a live authentication seal.

Before attesting, the agent reads identity through its original anonymous Core
pipes. It connects, without sending any data, to the fixed private
`data_directory/ipc/home.sock`, repeats canonical physical root/ipc/socket
UID/mode/inode pins, obtains the kernel peer PID and audit token, and requires
that PID to equal its original live Process child. Repeat child, original pipe
identities/quietness, endpoint pins and kernel token before/after the read. PID
is used only to correlate the kernel peer with that already owned child; no
caller-supplied PID/path/token can choose or authorize a process. Repeat Core
scope before returning metadata. A replaced socket, another same-user process,
dead child, failed pipe or changed owner fails closed. This read provisions no
principal, reads no Keychain item and sends no ordinary credential or request.

For each native ordinary API exchange, retain an actual authenticated broker
connection after its endpoint reply until that API exchange ends. Its original
signed app/agent peer, private path pins and five-second deadline remain checked
before the ordinary frame and after the response. The existing agent reply/EOF
lifetime keeps that peer available for those checks. The API's original deadline
covers endpoint acquisition too; a nested broker call cannot renew it.

Compare the attested deployment/owner/epoch with the original native credential
creation reference and require watermark at least its creation revision. Before
writing any API bytes, compare the connected ordinary socket's actual kernel
audit token with the attested token. The bound stream/descriptor remains private
for that one exchange. Ordinary server EOF does not substitute a new peer or
permit a reconnect under the original exchange. Finish the retained broker
connection on every success/error path. Failure sends no credential frame and
never falls back to UID-only/manual peer checks for that native credential.

Every credential returned by the actual signed broker client, including
existing-only recovery, registers its required native request guard by SHA-256
with its immutable original reference. This does not select a session. Retain
at most 264 distinct guards for the app process; a conflicting reference or
capacity refuses delivery. Hold no credential bytes in the guard registry, and
release its short lock before any OS/IPC work. Ending/changing a session or
selecting manual custody cannot downgrade a previously registered native hash.
Inert memory-only native selection has no authenticated guard and therefore
cannot send a bearer frame. Explicitly supplied manual fixture credentials
remain the ordinary API's existing test/development seam.

Required evidence: independent endpoint records and malformed token/scope
refusal; actual native parent/child kernel correlation across restart and a
same-user replacement endpoint; no data sent during attestation; unsigned app
endpoint/refusal before broker frames; native guard missing/failing with zero
ordinary request bytes; original deadline and retained reply/EOF lifetime;
existing manual client parity; actual app/helper compilation. Fixtures may test
kernel tokens and private transport without claiming signed custody. Successful
signed native API delivery and installed account/lifecycle remain host evidence.
