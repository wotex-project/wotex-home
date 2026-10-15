# Shared native certificate clock composition evidence

Executed 2026-10-15 on Apple Silicon macOS 27.0.1 with Elixir 1.19.6 /
OTP 28.5.0.6 and Swift 6.4, targeting macOS 15 with warnings rejected.
The [clock contract](../specs/native-certificate-clock-v1.md) and
[driver contract](../specs/native-controller-driver-v1.md) were refined before
this composition in `f76ecb5` and `ac9cc0a`. Implementation is `54b3ce2`, following
the [bounded source owner](native-certificate-clock-owner-2026-10.md).
This is NC-T4 software evidence; it does not qualify an installed issuer or Mac.

## Implemented composition

The process-wide application owns one passive production clock model/owner and
binds that actual producer to its default controller driver. The shared Setup
section is available for either local or paired selection, with explicit Begin,
absolute signed-answer path/import and withdrawal. The smaller driver retains
its nil producer default. The presentation-only action seam has no production
owner and cannot supply a clock, even when its status says qualified.

Begin and Import require loaded safe journal metadata and no shared busy work.
They preserve a retained original; ordinary session changes remain blocked by
that original. This distinction is necessary: requiring original resolution
before clock renewal would deadlock paired recovery after clock expiry. Setup
does not change the credential, selected controller, journal or original.
Withdrawal remains possible during other work and cannot free a retiring worker.

The model fixes action nonce, input path, request digest and presentation
generation before awaiting work. Input/selection changes during an action,
withdrawal and the shared host-availability handler cancel and revoke it.
Late action results and stale positive status polling cannot restore its
presentation. Idle input/selection changes preserve an accepted app-scoped
source. Polling reads metadata only, at one-second intervals after explicit work;
it neither acquires a clock nor starts source-file/signing/network work.

Accepted/withdrawn source transitions invalidate scoped presentation without
clearing pending originals or replacing selection. Selected, workspace/original
and power-receipt paths refuse unavailable clock metadata; a true availability
bit still requires actual current source/signing validation. There is no local
credential or UDS fallback. All five clock source/owner/panel files are included
in the explicit app assembly closure.

## Executed acceptance

`mix woh.native.certificate.clock.panel.smoke` compiled all **85 non-main
production Swift sources** and passed controlled action/status cases plus the
actual shared app's unsigned Begin refusal. The controlled fixture checks:

- Passive construction, shared work guards, duplicate Begin/Import suppression
  and the inability of a qualified presentation fixture to supply a clock.
- Absolute path and 4096-byte/NUL rules, rejection of relative/URL text, literal
  spaces and exact original import path/request digest across a held operation.
- Input, selection and withdrawal invalidation while Begin is held; late
  positive action and polled status refusal; no replacement Begin while busy.
- Idle accepted-source preservation across input/selection changes, revocation
  despite disabled work, simulated retirement fencing and polled withdrawal.
- The actual application's unloaded journal and held Health reader blocking
  Begin; a loaded empty private journal allowing work through the real unsigned
  gate; shared busy/session states during that action.
- A public paired-power fixture retained in an actual private journal. Clock
  setup is admitted through the unsigned gate while ordinary session changes
  remain blocked. The exact journal snapshot and original survive, and the
  original file CAS still passes. Unsafe journal mode then requires reload and
  blocks another Begin without removing the retained original.

Positive action/status values are controlled presentation metadata, not signed
production confidence. The real owner still refuses unsigned self before account
clock custody. The fixture uses a private pending-metadata directory, reads no
Keychain credential or Home Store, and sends no issuer or device request.

The shared panel was mounted and rendered at **380 and 780 points** with bounded
fitting height. Both PNGs were visually inspected: the narrow panel stacks all
three actions and wraps the long public request path; the wide panel keeps the
actions on one row. The renders use fixture labels and remaining age, not a
measurement of actual UTC. They cover the shared panel rather than an installed
full Setup session. Both reviewed previews were then removed.

Focused regressions passed:

- `mix woh.native.controller.session.smoke`: actual private Store Home/Thing
  reads, original local recovery, metadata CAS and remote no-fallback. New checks
  preserve remote selection with unavailable clock metadata, refuse Home/receipt
  reads and call neither the supplied producer nor local credential capture.
- `mix woh.native.quick.bar.smoke`: fifteen private-Store menu workflows.
- Full Swift 6/macOS 15 warnings-as-errors typecheck of the **86-source explicit
  app assembly closure**, including the real app entry point. The extracted main
  command contains every production source once, with no missing/extra source.
- `mix format --check-formatted`, `mix compile --warnings-as-errors`,
  `mix woh.spec.check` and `git diff --check`.

The catalogue checker passed 22 working contracts and all 21 contracts exported
from the staged index. All 380 committed Markdown local references resolved. Only
the owning catalogue versions were staged; unrelated research remains separate.
The staged export was removed after checking.

The first panel run incorrectly expected Begin before loading pending metadata;
the app's guard correctly blocked it. The fixture was corrected to load private
metadata, and gained explicit unloaded/unsafe cases. Review also found the
retained-original renewal deadlock; its contract was corrected before changing
the guard, then the exact original-preservation case passed. An initial ad hoc
typecheck extraction included the helper's source list as well as the app's;
the corrected command isolates the actual main assembly closure. No product
guard was relaxed to obtain a signing success.

## Limits and cleanup

Successful installed signing/Keychain/source ownership, actual current-source
sampling contention, owner timer behavior across real sleep/reboot, qualified
issuer UTC/elapsed accuracy and macOS 15 TLS/lifecycle remain their actual host
obligations. Calling the shared availability handler and controlling UI status
cannot establish those results. No full application suite, Dialyzer, release,
firmware or physical campaign was run. Dependency pins, sibling revisions,
schema and default-disabled physical dispatch remain unchanged.

Every final command handle terminated. Each fixture/typecheck removed its
private compiler/cache/executable/file root; the documentation agent's scratch
was removed after a verified header-only patch. Twelve reviewed panel/menu/
selection PNGs totaling 1,237,828 bytes were removed, leaving `_build/native`
empty. No Docker resources were created or changed. The filesystem inventory
showed about 26 GiB free; existing small locked dependency caches, unrelated
research and other projects' Docker data were preserved.
