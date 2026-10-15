# Private MQTT installation validation

Recorded: 2026-10-15. Implementation: Home main
`1e7253ac8f4c6191375a01753527ab2ddef8e2fb`.
Owner: [private MQTT installation contract](../specs/private-mqtt-installation-v1.md).

## Delivered behavior

Ordinary Host startup selects the existing authoring file and optional fixed
mqtt-source-v1.json. The source file contains explicit operator profile closure,
capture assertion, source/channel policies and one local connection. Password
mode independently seals mqtt-credential-v1.json; source/status/installer output
contains no secret. Native constructors still override private files, including
an explicit nil installation.

Both installers publish validated exact mode-0400 bytes without replacement,
sync using PrivateFile, and refuse changed existing policy. Source publication
reconstructs against the actual current authoring registration and requires the
password file when selected. Snapshots retain exact seals and raw hashes;
source startup checks rebuild the complete prepared configuration, including its
resolver, and compare it with the selected snapshot. A forged in-memory endpoint
cannot replace the selected file. Credential references retain only seal/hash,
not the decoded username/password; resolution rechecks the same bytes at attach.

After Store/private custody, one temporary child creates and attaches the
publisher and both source/report owners. It starts before the API. Partial
startup failure kills its owned processes. Every owner loss is terminal; the
temporary composition is removed when Store restarts. New Store/current native
authority remains available, while MQTT stays unavailable in that Host
incarnation. A new full Host startup creates a different source epoch and does
not reuse retained target freshness.

The source and credential files stay outside Store/profile archives. No new
SQL schema, dependency, owned-repository change, device command or visibility
change is part of this delivery. Capture in a private file is an operator host
assertion, not a live interview or device authentication. Default physical
dispatch remains false.

## Executed checks

Root checks used Elixir 1.19.6 / OTP 28.5.0.6, MIX_ENV=test and
WOTEX_HOME_GIT_DEPS=1, with the unchanged locked cohort.

- 59 tests passed across private_mqtt_installation_test.exs,
  private_profile_configuration_test.exs, host_profile_installation_test.exs,
  generation_installation_test.exs, recovery_private_file_test.exs and
  host_test.exs. This covers the new private source and existing authoring,
  generator/native-publisher modes, actual Store/custody restart, private-file
  framing/publication and Host startup/locking behavior.
- 42 tests passed across the new installation and existing MQTT publisher
  suites after extracting their shared actual reviewed-target setup into the
  test fixture. The real EMQTT callbacks, TLS, exact values, original admission,
  queue/counter limits and lost-reply behavior retain their existing evidence.
- After complete native-snapshot reconstruction checking and a fresh process
  case were added, all 13 installation tests passed. The final 14-case run also
  directly checks renamed/replaced empty-root absence and failed source-file
  synchronization. They exercise actual
  private files and sockets, not source-text assertions. The fresh ordinary
  Application starts with only WOTEX_HOME_DATA_DIR, creates actual MQTT/custody
  and Store owners, keeps dispatch false and closes the connection on stop.
  No caller publisher PID or application-env adapter is supplied.
- Actual file-provisioned Host imports/inspects/approves/selects a target through
  Store and admits a literal broker report. Its exact raw 250 normalizes to
  integer 25000 through the public profile/consumer unit path. A full Host
  replacement changes source epoch; an authenticated report preview transitions
  from fresh to unknown instead of reusing old freshness.
- Real verified TLS resolves the separately sealed credential and delivers its
  synthetic username/password only inside MQTT CONNECT. A changed credential
  fails its old reference/snapshot. Missing password custody fails before SQLite;
  invalid present configuration fails before SQLite/socket. Explicit native nil
  skips malformed private source files. Source/config/status/crash-output canaries
  are absent from diagnostics; the credential installer prints only installed=true.
- Exact publication/retry/conflict, bad mode/hard-link/symlink, witnessed
  absence appearance, same-size source/credential changes, forged prepared
  endpoint, synchronization refusal and partial broker SUBACK failure were
  exercised. Shared PrivateFile regression cases supply the broader existing
  descriptor/ancestor/publication race evidence. No new unsafe fallback is used.

These counts overlap and do not describe a full suite. Root format,
warnings-as-errors compilation and Git whitespace checks passed. Nerves host
compilation passed warnings-as-errors on its declared OTP 29.0.4 / Elixir 1.19.6
toolchain after the final behavior change; this was host compilation, not an
image build or board boot. The docs-only agent's five header changes passed
isolated AST equivalence, references, formatting and blank-line checks.
Metadata checks pass for 22 working-tree contracts and 21 staged contracts;
547 staged local Markdown references resolve. These checks preserve the separate
uncommitted audio/WST research contracts and do not promote their implementation
or evidence status.

## Remaining delivery obligations

Native setup presentation and signed OS credential brokerage remain WOH.08
work. The foreground provisioner requires explicit valid private input files;
there is no synthetic installed default or socket/model installation route.
Full suite, Dialyzer, current release/firmware assembly, signed installation,
storage power-loss and physical source/control qualification remain milestone
checks. Filesystem/controlled-broker tests establish no broker-fleet or actual
sensor/sample-age/physical evidence. The prior dependency graph and its
[recorded advisory/fetch limitations](mqtt-observation-publisher-2026-10.md)
remain unchanged.
