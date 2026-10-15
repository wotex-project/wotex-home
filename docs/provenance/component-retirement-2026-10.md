# Component retirement ownership software evidence

Executed 2026-10-15 on Apple Silicon macOS 27.0.1 with the repository's
Elixir 1.19.6/OTP 28.5.0.6 toolchain and locked test dependencies. This is a
focused optional-preview lifecycle repair, not production helper qualification.

The [owning retirement contract](../specs/component-retirement-v1.md) was
committed first in `5c2a382`. Implementation: `cb897ec`; acceptance additions:
`e4ef21e` (lost-Port and actual loader-exception cases); final release guard:
`3978c45`. The native Rust worker, WIT, IPC values, dependencies and sibling
sources are unchanged.

## Implemented and exercised

One independent original-Port owner now retains the aggregate VM slot through
loading, execution and retirement. Runner/caller loss and Runner replacement
cannot free it. Retirement requests use the existing native extra-byte monitor;
only the original native exit status or proof that no Port opened releases
capacity. Unexpected owner loss preserves a constant VM-local marker and a
replacement owner refuses new work. No numeric OS PID is signalled by this
implementation. PID absence is used only by the independent fixtures to check
cleanup, never as the owner's permission to reuse capacity.

`MIX_ENV=test WOTEX_HOME_GIT_DEPS=1 mise exec -- mix test test/wotex_home/component_retirement_test.exs test/wotex_home/component_runner_test.exs test/wotex_home/component_bundle_test.exs`
passed **17 tests, zero failures**, in 11.4 seconds on the final implementation:

- CR-T1: real scripted children observe the actual zero cancellation byte and
  deliberately stay alive until a test release marker. Repeated competing
  calls return capacity while launch count remains one after timeout, caller
  loss and malformed output. Actual Store health is unchanged during retirement.
- CR-T2: both orderly stop and untrappable Runner kill preserve the same live
  independent owner. A replacement cannot spawn a second child. After the
  original's actual exit, a new successful call works with a distinct launch.
  Another Runner in the same VM shares that aggregate ceiling.
- CR-T3: a disposable fresh BEAM kills the retirement owner while its original
  child is alive. The new owner remains fenced after eventual original exit;
  25 competing calls produce no second launch.
- CR-T4: an early valid response, native stdout EOF and a late valid response
  do not complete or release the running original. Another disposable BEAM
  forcibly closes its original Port, observes native stdin EOF and eventual
  child death, then still gets capacity refusal without exit-status evidence.
  Killing/restarting that owner preserves the persistent fence. Existing native
  crash, truncation, oversized/trailing output and environment isolation pass;
  actual statuses 124 and 152 map to their finite timeout/resource outcomes.
- CR-T5: an invalid retained bundle opens no native process. A trusted malformed
  internal loader configuration causes a real Task exception; only that unused
  slot is released. Fresh successful calls remain usable. Ordinary completion
  is delivered together with slot release, so immediate consecutive calls work.
  Foreign/nil monitor and loader messages cannot release the original slot;
  release itself refuses a still-owned native Port without exit evidence.

The first expanded run found a reply-ordering race: normal outcome was sent
before Runner cleared its busy state, briefly rejecting the next immediate
call. Final completion and slot release now use one message/transition. The
affected runs passed after the correction; cancellation still reports promptly
and retains busy state until retirement.

`mix format --check-formatted`, `mix compile --warnings-as-errors` and
`git diff --check` passed. `mix woh.spec.check` passed for 22 working contracts;
an isolated staged export passed all 21 committed contracts. All 33 staged
Markdown local targets exist; unrelated research remains excluded from commits.
The documentation-only agent's two header proposals
passed documentation-stripped AST/reference/formatting checks. Applying them to
the final implementation also preserved every non-documentation byte and exactly
one following blank line. Test modules retain `@moduledoc false` and one blank.

## Limits and cleanup

The four actual Wasmtime/component ABI tests were not rerun: their ignored
runner/fixture artifacts are absent. No Rust/WIT/ABI changed and no large native
build, full suite, Dialyzer, package/release/firmware build or benchmark ran.
Historical native results retain their original source scope. VM-local
retirement evidence does not establish whole-VM restart safety, hostile native
descendant containment, host-wide RSS limits, signed Mac/Nerves delivery,
production activation/recovery or physical mapping qualification. WOH.17 and
catalogue evidence remain partial/missing as applicable.

Fixtures wait for their actual original children, release delayed children even
on failure and remove private temporary roots. A synthetic eight-second watchdog
bounds fixture failure cleanup. Disposable child BEAMs reached successful exit.
No Docker image, heavyweight compiler cache or native build artifact was created.
