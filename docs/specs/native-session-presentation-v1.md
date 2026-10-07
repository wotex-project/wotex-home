# Native session presentation v1

Version: 0.1.0. Accepted native presentation mechanism before implementation,
2026-10-07. WOH.08 owns this app session, joining the
[credential broker](native-credential-broker-v1.md) with the existing ordinary
Authority routes. It changes no role permission, Thing grant or dispatch gate.

The app has one explicit selected local session shared by its windows. The user
chooses one of the four fixed native roles and explicitly requests its session
from the authenticated broker. Registration and a status check select no role.
Do not automatically request a credential, display its bytes, copy it to the
clipboard, serialize it or put it into the legacy manual-import Keychain item.
Hold exactly one current native credential in memory with redacted descriptions
and reflection; closing the app discards it. A fresh explicit selection reconciles
the same original agent item/principal. Failed setup leaves the prior selection
unchanged and explains uncertainty without creating another operation or secret.

Keep native setup state/owner/epoch/role separate from background registration,
ordinary health, current permissions and hardware observations. Display roles in
plain language and state that device access needs a separate grant. Transfer
authority does not acquire ordinary read or control by being selected. No status
or count qualifies a device or enables physical dispatch.

The existing manual-import mode remains available for development and trusted
external custody. Selecting native custody supersedes it in memory only.
Explicitly ending a native session leaves no selected credential; it cannot
silently resume the saved manual item. The user can explicitly select manual
custody or import a new manual credential. Preserve that item's existing service,
account, non-syncing policy and unrelated client settings. Native selection/end
performs no SecItem operation. A successful explicit manual import selects that
mode; a failed import changes no current selection.

Use a bounded synchronized memory holder so background client work can capture
one original credential safely. Source UI tasks must not hold its lock during
IO. An already-created uncertain operation/review keeps its original credential,
identity and exact request; selecting another role cannot rewrite those inputs
or make a principal-private receipt public. New setup/mutation controls must
respect existing busy/uncertainty guards. This profile does not implement
persistent pending-operation custody, target grants, rule editing or transfer UI;
their separate contracts/evidence remain required.

Software evidence checks inert memory selection without opening Keychain,
native replacement/end/manual transitions, malformed credentials and secret
redaction. Actual unsigned setup must fail without changing current selection.
Compile the actual app and inspect the rendered setup panel. Never render a
real credential or invent signed/Keychain success. Actual signed role delivery,
fresh-account usability, accessibility and installed lifecycle remain their
own obligations.
