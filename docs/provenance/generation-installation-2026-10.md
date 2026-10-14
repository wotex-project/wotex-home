# Trusted generation installation software evidence

Recorded: 2026-10-15. Contract:
[trusted generation installation](../specs/generation-installation-v1.md).
Runtime: 1b0efcb460f0c473812243583de6778cc1e696cd on local main.
The owning contract and independent file/policy vectors preceded runtime in
4047eb3. No dependency or schema changed.

## Implemented and executed scope

Host validates the exact native policy/provider set or the fixed private policy
selection before acquiring resources. It rechecks the selected file/absence
before children and passes the original checked lists to Store. Store child
restart retains that selection without disk reload or attempt replay. Explicit
nil/native selection suppresses the file; private policy plus checked adapter
capabilities supports the existing pipeline through actual Host.

GenerationConfiguration decodes bounded closed policy data, pins present-file
seals and existing-root absence witnesses, and publishes exact immutable bytes
without replacement. The installer loads paths without starting Home and emits
only delivery digest and aggregate counts. File-only startup has no adapter,
permits inert preparation and refuses a provider attempt. A trusted native
capability remains an explicit live local PID, not an external-model identity or
confinement proof. No concrete model adapter was added.

Frozen test/fixtures/profiles/generation-installation.json raw SHA-256:
f5a336a07440330c6e2d304e035b33f3bc4c916c308c4159356f357d00aeb958.
Independent Python field allocation produced both file documents/raw digests and
recomputed provider/policy ordered-array hashes from the existing independent
quantity vectors, without Home or BEAM invocation. Those hashes match the
earlier preparation vectors. Actual Host calls match the separately frozen
generation-attempt provider document for both temperature and research families.

Checks used mise Elixir 1.19.6 / OTP 28.5.0.6 on macOS and current Store schema 37.
Root mix.lock SHA-256 remains
3372ef86b264343efeedea270b3a8d0548650898043aa0e360daba46c7aaf184;
Nerves lock remains
259fb7f414899924e12897dcb9c04ceff817c9e82d03f6254f82049a3a1b3663.
Consumed core/Runtime/Profiles remains
ba8ea373244ce57987f47a731b8eca3ccae9b45f. No sibling API change was needed.

## Executed checks

The final affected run passed **49 tests, zero failures, 39.5 seconds**:

```
mise exec -- mix test test/wotex_home/generation_installation_test.exs \
  test/wotex_home/private_profile_configuration_test.exs \
  test/wotex_home/host_test.exs \
  test/wotex_home/host_profile_installation_test.exs \
  test/wotex_home/installed_profile_runtime_test.exs \
  test/wotex_home/generation_operator_codec_test.exs
```

The new suite contributes sixteen pure/filesystem/Host/process/fresh-OTP cases.
No socket-free exclusion was used. Formatting, warnings-as-errors compilation,
catalogue checking (22 workspace contracts matched), full HTML ExDoc with
warnings-as-errors and Git whitespace checks passed. Host guides document exact
publication, private/native selection, disabled defaults and remaining adapter
obligations. No Swift, firmware, release or installed signed artifact was built.

Raw synthetic logs: /tmp/home-generation-installation-final.log and
/tmp/home-generation-installation-docs.log. Earlier fixture failures exposed a
mistyped client API and writes to an immutable fixture without changing its mode.
The initial Host regression run found two direct-init fixtures using nonprivate
roots and changed error precedence for a nonprivate directory. Fixtures now use
0700 roots; a read-only preflight preserves invalid_host_directory before
configuration selection. The final run covers these corrected cases.

## Acceptance correspondence

GI-T1 checks both independently frozen document/policy/provider identities,
native checked/nil/private modes, malformed native capabilities and exact keys,
policy duplicates/order, float/bool/offset, invalid UTF-8/duplicate/deep JSON,
32-policy boundary, exactly 1048576 bytes plus overflow and node excess.

GI-T2 checks actual immutable publication/retry/conflict and safe metadata,
snapshot same-size modification/removal/replacement, absence appearance and root
replacement, mode/symlink/hardlink/ancestor refusal, file/directory sync failure,
competing publication and failed cleanup after a foreign replacement. Foreign
bytes remain intact. Host child construction rejects changed selected inputs or
a dead native capability before database/socket/profile resources.

GI-T3 checks invalid native installation before even a new root is acquired,
invalid present policy before Store/custody/socket, explicit nil/native suppression,
and actual default file-only Host metadata/preparation with no possible handoff.
All paths preserve default-disabled dispatch.

GI-T4 uses actual named Host, SQLite, profile custody and private Unix socket for
both families. Imported independently authored source/fixture objects retain
their exact first revisions; guarded preparation/start observes one scripted
provider call with the exact frozen document/output ceiling. Inert candidate
assessment remains source_review not_assessed and fixture_status not_supplied.
Original prepare/start replay produces no second call.

GI-T5 changes disk policy while a running attempt is pending, kills Store and
observes the new child using the original installed policy. The old attempt is
unknown, not running/resumed. A complete default Host restart then selects the
now-empty file while preserving authenticated existing originals/status/retry.
Adapter death separately changes provider_present to false without stopping Host
or ordinary Store reads. Its dead capability refuses reconstruction; no substitute
PID is selected. An unrelated later Store restart with that dead pinned capability
can refuse startup, as required by the explicit installation contract.

GI-T6 runs a fresh Mix installer with deliberately invalid Home startup policy
and proves it creates no Home database. Fresh ordinary Application startup selects
valid file policy with one policy/no adapter/dispatch false; invalid present data
refuses before database/custody/socket and prints no configuration canary.

## Remaining delivery and qualification

Scripted provider processes contact no external model. Concrete local/remote
model adapters, authenticated bounded transport and enforced model confinement,
native generation UI/pending custody, paired/signed delivery and aggregate attempt
pool boundaries remain successor work. File/native policy remains outside Store
and profile backups; restore creates no provider or export authority. No Linux
systemd, board startup, storage power-loss, physical or fresh hosted full-suite
qualification is claimed. All commits remain local on main; nothing was pushed.
