# Private installed authoring configuration

Version: 0.1.0. Updated: 2026-10-14. Status: accepted successor target.
Owner: WOH.08 host lifecycle, WOH.16 local configuration/recovery and WOH.18 H18-08/09/H18-T13/T16/T17.
Implementation: planned. Evidence: missing.

## Result and ownership

The ordinary packaged Host can load explicitly supplied authoring bindings,
accepted Home contract references and limits from one immutable private file
beneath its selected data directory. Native mapping/import/manual assessment
and source-attribution review can then use the existing authenticated routes
without application-env or caller-PID configuration. The file supplies no
capture, live reader, publisher, source/report, permission, qualification or
dispatch authority. Complete review still requires separately supplied current
capture and refuses authoring_capture_unavailable when it is absent.

This extends [installed runtime](installed-profile-runtime-v1.md) with an
authoring-only native mode and private delivery. Existing trusted five-key
reader/capture/live-publisher startup remains unchanged. Store alone owns SQL,
host locks, authorization, revisions and originals. WoTEx still validates
bindings/grammar; Home computes actual locked producer inventories. Existing
immutable [private custody](../../lib/wotex_home/recovery/private_file.ex)
supplies descriptor/ancestor checks, nonreplacement, synchronization and seals.

## Exact file and inputs

The sole filename is profile-authoring-v1.json under the canonical data root.
There is no path/environment option, directory scan, URL, template fallback,
schema fetch or public socket/paired installation route. WOTEX_HOME_DATA_DIR
and the existing trusted data_dir setting select only the ordinary Host root.
An absent file preserves unavailable authoring and the existing disabled defaults.

The file is exactly an object with format, installed and authoring_limits.
Format is wotex-home.profile-authoring-installation@1. Installed is exactly
bindings, contracts and home_contracts. Bindings are the explicit supported WPF
registration bodies; contracts/Home contracts are their existing closed sorted
reference arrays. No caller producer assertion is accepted. Authoring_limits
is exactly reader, max_bundle_bytes, max_diagnostics, max_report_bytes and
max_check_steps. Reader is exactly max_bytes, max_depth, max_nodes, max_channels,
max_definitions, max_bindings, max_dependencies and max_numeric_digits.

All limits are positive integers without boolean/float aliases and within the
existing AuthoringContract ceilings: reader bytes 262144, depth 8, nodes 4096,
channels/definitions/bindings/dependencies 32, numeric digits 64; bundle bytes
262144, diagnostics 64, report bytes 24576, check steps 1000000. No missing field
or malformed value receives a default. Runtime producer identity is recomputed
from the pinned loaded applications and generic AuthoringContract.export/2
reconstructs the complete basis. Unknown keys/native structs, wrong formats,
duplicate decoded JSON names, invalid UTF-8 and invalid references/bindings refuse.

The file is 1..262144 bytes; decode using the bounded producer JSON API at depth
8, 4096 value/container nodes, 1024 collection members and 4096 string bytes.
It has mode 0400, one hard link and regular type; its UID equals the private
0700 root's UID. Canonical ancestors and leaf may not be symlinks. Preserve raw
bytes and their SHA256 as delivery identity; producer reconstruction owns the
native configuration interpretation. File/directory descriptor/name/inode/size/
time and ancestor witnesses must remain stable. Aliases accepted by the existing
Host root canonicalizer resolve to that same private canonical namespace.

## Requirements and transitions

**PC-01 — Authoring-only native mode.** Add exactly mode=:authoring, installed
and authoring_limits as a trusted native profile_installation variant. Construct
the existing authoring contract with actual runtime identity; return nil reader,
capture and publisher. Start no ExternalProfiles subtree and pass nil source/
report owner names to Store. This enables inert owned import, contract export,
manual assessment and source review only. The legacy exact five-key variant
still requires its explicit capture and live publisher and retains all restart/
publisher-loss behavior. No runtime record or schema migration is added.

**PC-02 — One sealed startup selection.** When profile_installation is explicitly
present in Host options, including nil, use that trusted native input and never
read/fallback to the file. Otherwise load the fixed file once before any new
Store/socket/profile namespace or data-root acquisition. Validate syntax, native
configuration and producer availability before resources. Carry a private sealed
selection into Host.init; do not reread different bytes as a new configuration.
Recheck the exact file seal and raw SHA after reconstruction immediately before
starting children. Removal, replacement, same-size content change, links or mode/
ancestor drift refuses profile_configuration_changed. An initially absent file
must still be absent at this boundary; appearance refuses rather than silently
activating it. No partial configuration, fallback or automatic repair occurs.

**PC-03 — Immutable local publication.** A trusted foreground installer takes
an explicit private 0400 input file and existing canonical private data root.
Validate source and runtime reconstruction before writing the fixed destination.
Publish those exact bytes with existing exclusive/nonreplacing synchronized
private custody. Repeating identical existing bytes returns the same safe digest/
count metadata; different existing bytes return profile_configuration_exists,
preserving the original. Unsafe/unreadable source/destination refuses
profile_configuration_unavailable. A publication creates no Store, credential,
revision, background service or dispatch. Its Mix entry prints only digest/count
metadata, with no contents, identities, capture, credential or private path.

**PC-04 — Runtime, restart and recovery.** A running Host retains its selected
pure configuration. Store/custody child restart does not read changed disk policy.
A later full Host startup, including supervisor restart, makes a new sealed
selection. New complete basis identities invalidate old prepared decisions;
historical original lookups retain their meaning. Foreground publication may
prepare the next startup but never hot-reloads the running Host. Existing-file
replacement/removal and activation sequencing remain explicit host-owner work.
Snapshot/installer diagnostics exclude source configuration and private identities.
Known authoring_capture_unavailable is a definitive no-review refusal and follows
existing native original cleanup; it must not present a successful complete review.

The file is local trusted host policy, outside profile imports and encrypted
Store/quarantine archives. Restoring a database cannot manufacture this file or
current capture/source/qualification. Native and firmware/runtime entry points
using ordinary Host startup inherit the same loader; no synthetic default is
shipped. Physical dispatch remains default-disabled and file contents cannot
change it. Source/protocol installation remains a separate live trusted boundary.

## Acceptance and evidence

| Case | Requirements | Stimulus and independent observation | Level |
| --- | --- | --- | --- |
| PC-T1 | PC-01/02 | Both independent families decode/reconstruct; absent and explicit nil/native modes stay compatible; unknown/duplicate/float/bool/format/binding/limit/size/depth/node inputs refuse before Store/socket acquisition | Software |
| PC-T2 | PC-02/03 | Actual private files: mode/link/symlink/ancestor, removal/replacement and same-size changes refuse; exclusive publication/repeat/different-byte conflict, sync failure and race preserve original/foreign bytes | Filesystem |
| PC-T3 | PC-01/04 | Actual default Host loads file, exports contract, imports/assesses and source-reviews; capture remains absent, complete review refuses, reader/source/report unavailable and dispatch disabled; child restart retains basis/history | Store/socket |
| PC-T4 | PC-02/04 | Fresh ordinary Application/native-parent startup uses only data-root selection; bad present file stops before Store/socket; restart/load changed basis and historical originals are distinct; diagnostics leak no file contents | Fresh OTP process |

Record actual source/toolchain, fixture bytes/digests, commands and results.
Software startup/filesystem cases do not establish signed installation, systemd/
board lifecycle, storage power-loss, publisher/device or physical qualification.
Catalogue parents keep broader partial/missing axes until their full gates pass.
