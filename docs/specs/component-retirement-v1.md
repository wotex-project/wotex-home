# Component preview retirement ownership

Version: 0.1.1. Updated: 2026-10-15. Status: accepted implementation contract.
Owner: WOH.17 H17-03/H17-T3/T4. Implementation: VM-local lifecycle implemented.
Evidence: [executed original-Port and restart faults](../provenance/component-retirement-2026-10.md);
actual native ABI, whole-VM restart and production containment remain separate.

## Result and scope

The optional import-free preview keeps one aggregate native invocation slot
per BEAM VM, including loading, running and retiring work across all Runner
instances and Runner restarts. No queue or automatic retry exists. Invalid
inputs retain their existing errors; a valid competing preview returns
component_capacity without loading a bundle or spawning native work. This
changes resource ownership, not component meaning, qualified reports or Store.
Home remains one application. No sibling generic API or dependency changes.

## Owners and transitions

**CR-01 — Independent owner.** A lazily started, fixed locally registered
retirement owner is unlinked from Runner, its caller and the Host supervisor.
It monitors both Runner and original caller before acquiring work. Runner stop,
kill or replacement cannot terminate that owner or release its native slot.
It owns the original Port and validates every frame/status itself. Bundle
loading is a bounded worker; it cannot open a native Port. There is at most one
loading worker or one native invocation, with no successor while retiring.

**CR-02 — Original deadline and result.** Admission fixes one monotonic deadline
using the existing configured integer 50..5000 ms (default 5000). It includes
bundle loading, spawn, compile, execute, lifting and reply checking. Runner
retains an independent deadline so a delayed loader/spawn cannot extend the
caller-visible budget. No native request is sent after expiry. The public call
keeps its existing 6000 ms outer unavailable bound. A returned timeout/error
does not imply native retirement. Runner retains its busy slot after replying
until the independent owner confirms retirement; late outcomes cannot replace
the original result or settle another invocation.

**CR-03 — Cancellation without losing exit evidence.** After one complete
request, one extra zero byte on the original stdin requests retirement. The
existing native monitor treats any extra byte or EOF as immediate exit 125;
the independent five-second native watchdog remains mandatory. This byte is
not a second request, protocol ACK or successful result. Use nonblocking Port
writes. On caller/Runner loss, timeout or invalid response, discard response
state, request retirement once and keep the original Port. Do not close that
Port merely to free capacity, and never signal an OS PID from a numeric PID.
If writing cancellation fails, retain capacity while awaiting native exit.

An actual `{original_port, {:exit_status, status}}` establishes termination of
that original external process. EOF, Port EXIT, task DOWN, a parsed response,
Port.close success and elapsed time alone do not. Ignore EOF and normal Port
EXIT while waiting for status; a lost/abnormal Port without status fences the
slot. Native status 124 maps to component_timeout and 152 to resource_exhausted;
other unsuccessful statuses remain native_crash. Success requires the exact
bounded response plus normal exit before the original deadline. An earlier
error/timeout remains unchanged even if later output looks successful.

**CR-04 — Loss of retirement evidence.** Before any loading/spawn, the owner
sets one VM-local persistent busy marker. Clear it only after proving no native
Port was opened, or observing the original native exit status. If the owner
dies with that marker set, a replacement owner starts fenced and refuses all
previews with component_capacity. There is no administrative reset, PID probe,
timer-based release or retry that erases that uncertainty. Constant marker
storage contains no input, credentials, paths or guest data. Owner death while
idle may restart normally. An unexpected loader failure before Port creation
returns native_crash and releases the unused slot.

This is a VM-local software ceiling, including Runner/Host restart. Whole-VM
crash/restart, hostile native descendants, host-wide RSS and OS containment need
their actual host qualification; this contract does not turn the optional
development helper into a production component loader. The unchanged native
worker spawns watchdog/EOF threads, no guest processes. Default Host configuration
starts no preview worker. No durable Store schema, authority or dispatch changes.

## Acceptance and evidence

| Case | Required oracle and failure |
| --- | --- |
| CR-T1 | Scripted native child observes the actual cancellation byte, delays exit, and records launches. After caller loss, timeout and malformed output, repeated calls must return capacity and the launch count stay one until that original exits. Store reads remain available. |
| CR-T2 | Stop and kill Runner during native work, start replacement against the same owner, and prove the delayed original prevents a second launch. After actual exit, a fresh invocation works and no original result is reused. |
| CR-T3 | Separate disposable BEAM kills the retirement owner with a live original. Replacement owner remains fenced even after eventual child exit; no second launch or numeric PID signalling. The fixture itself must observe eventual child death before finishing. |
| CR-T4 | Valid response without child exit, EOF without exit and late valid response cannot release capacity or produce success. Existing truncated/oversized/trailing/status/environment cases retain bounded typed outcomes. |
| CR-T5 | Invalid bundle/input, pre-Port loader failure and ordinary successful exit release only unused/proven-retired slots. Existing installer, Authority isolation and actual native ABI vectors remain separate checks. |

Use bounded independent Python process fixtures for lifecycle faults; no new
Wasmtime build is required when native code/ABI are unchanged. Actual locked
native vectors run at their milestone when their artifacts exist. Record
commands, exact source commits, failures and exclusions before promoting
implementation/evidence. Eventual PID absence is a fixture cleanup check, not
the implementation's permission to reuse a slot. Erlang's
[Port contract](https://www.erlang.org/docs/28/apps/erts/erlang.html#open_port/2)
defines exit status and the unspecified EOF/status ordering.
