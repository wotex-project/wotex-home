# Private installed MQTT source

Version: 0.1.1. Updated: 2026-10-15. Status: accepted successor target.
Owner: WOH.03 H03-T7, WOH.08 lifecycle, WOH.16 private custody and WOH.18 H18-T11/T12.
Implementation: sealed publication, ordinary Host composition and terminal lifecycle implemented.
Evidence: [executed files, Host/Store, TLS and fresh-process checks](../provenance/private-mqtt-installation-2026-10.md).

## Observable result and ownership

Ordinary Host startup can create the implemented [native MQTT publisher](mqtt-observation-publisher-v1.md)
from explicit immutable local files. A configured private broker requires no
caller process, application environment callback or model-authored endpoint.
The existing [authoring configuration](private-profile-configuration-v1.md)
supplies installed bindings, accepted Home contracts and reader/authoring limits.
This contract adds one source's profile closure, explicit capture assertion,
channel policy and connection. It grants no profile trust, current target,
principal permission, physical qualification or dispatch. Store retains every
existing review, source-incarnation, sequence and freshness check.

Home owns this consumer installation. Public WPF Compiler/ReaderSelection and
MQTT JSONProjection retain generic interpretation; EMQTT retains MQTT mechanics.
The publisher opens only explicit local IPv4 TCP or verified TLS, owns actual
receipt clocks and never automatically reconnects. No new SQL schema is needed.

## Closed documents

**MI-01 — One source policy.** The only configuration filename is
mqtt-source-v1.json under the canonical private data root. The 1..524288-byte
UTF-8 JSON object has exactly format, profile, definitions, capture, source,
channels and connection. Format is wotex-home.mqtt-source@1. Decode rejects
duplicate names, non-JSON terms, invalid UTF-8 and unknown fields with finite
limits: depth 10, nodes 32768, collection members 256, string/key bytes 21848.
These wrapper limits do not widen any independently checked WPF input/report.

Profile and definitions are complete public WPF profile/definition maps, not
module names, paths, object handles or downloaded references. Capture is exactly
binding, capture_epoch, digest and fields, revalidated against the authoring
installation's selected binding. Build ReaderSelection with the actual current
producer and identical installed reader limits; compile the supplied profile,
definitions, installed bindings/contracts and capture using public Compiler.
Revalidate the resulting publisher configuration through MQTT.Configuration.
The selected binding must be installed, have the exact JSONProjection selector
schema and allow observeproperty. All configured channels must be included,
observable and have valid exact MQTT selectors. At most 32 channels/topics.

Source is exactly source_ref, stable_id, source_generation, method and trust.
Channels and their explicit consumers/policy obey ExternalSourceSelection:
ordered unique channel IDs/capability keys, installed consumer references, finite
freshness/risk policy and existing quantity checks. Trust is only
unauthenticated_local or synthetic_lab. Capture is the operator's supplied host
assertion, not a live device interview. TLS verifies a broker, not a sensor.
Publisher supplies a fresh random source_epoch on each incarnation; disk cannot
restore an old epoch or Store sequence cursor. Generation is explicit positive
signed-64 and is not automatically incremented or inferred.

Connection is exactly address, local_address, port, tls and authentication.
Addresses are four-element JSON integer arrays converted to literal IPv4 tuples;
both must be loopback/RFC1918/link-local, with local_address currently on a host
interface. Port is integer 1..65535. TLS is null or exactly server_name and
cacerts. Cacerts is 1..8 canonical padded standard-base64 DER certificates,
decoded lengths 1..16384 each and total at most 65536. Name is ASCII DNS 1..253
bytes with 1..63-byte labels. The native publisher validates certificates,
hostname/SNI and validity, disables session reuse/tickets and binds local_address.
No DNS address, proxy, wildcard subscription, URL/path or TLS override is accepted.
Authentication is exactly the JSON string "none" or "password". Password requires TLS and the fixed
credential file below; no username/password or arbitrary credential reference
is permitted in the configuration. None never reads a credential file.

**MI-02 — Separate credential custody.** mqtt-credential-v1.json is the only
credential filename, outside configuration, Store/profile backups and imports.
Its 1..8192-byte JSON object has exactly format, username and password_base64.
Format is wotex-home.mqtt-credential@1; username is UTF-8 1..128 bytes without
U+0000, password canonical standard-base64 decoding to binary 1..4096 bytes.
Decode at depth 2, nodes 8, collection 3, text 5464. No aliases/defaults or raw
password strings. Native MQTT credentials receive only the decoded pair.

Both files and installer sources use existing PrivateFile custody: canonical
absolute ancestors without symlinks, regular mode-0400 one-link leaf owned by
its mode-0700 parent. Descriptor/name/ancestor/inode/size/time witnesses and
exact bytes must agree. No file is executed. Fixed names have no environment,
scan, URL or socket/model installation route. Snapshots/status/errors never
inspect private bodies, usernames, stable identity, paths or endpoints. A
credential's raw hash is private correspondence only and is never printed.

## Startup, resources and failure

**MI-03 — Sealed startup basis.** With an explicit native profile_installation
option, including nil, preserve the existing native mode and ignore both MQTT
files. Otherwise load authoring and MQTT selections before acquiring Store,
profile namespace or API socket. Absent MQTT preserves existing behavior.
Present MQTT requires the selected private authoring file; missing authoring
refuses mqtt_profile_configuration_required. Invalid configuration or a missing/
unsafe password credential fails before those resources or any broker connection.
No fallback to authoring-only mode occurs on a bad present MQTT file.

Retain exact source and credential seals/raw hashes, not decoded credentials,
through startup. Recheck the original configuration and credential witnesses
after producer reconstruction immediately before starting children. Initially
absent MQTT must still be absent, with stable private-root ancestor witnesses.
Changed/removal/replacement/mode/link/ancestor drift refuses the typed changed
outcome. The credential provider captures only its sealed private reference,
rechecks the identical selected bytes and decodes only during explicit attach.
Never retain decoded username/password in Host/installation/composition state.
The publisher's five-second setup watchdog bounds provider/backend stalls.
When the entire data root is initially absent, the existing Host creation and
canonicalization checks create its private namespace; require MQTT absence again
at that boundary before children. There were no source/credential bytes to select.

**MI-04 — Owned transient composition.** Store starts with the reconstructed
reader/authoring/capture and the normal source/report owner names. After Store
and profile custody start, one temporary Host child owns a publisher, source
owner, report owner and attachment. Publish source custody before connecting.
Start the API only after attachment succeeds. Any partial startup failure kills
every newly created child and makes Host startup fail with a fixed atom; no
orphan client/worker or retry loop. Physical dispatch stays default-disabled.

| Event | Result |
| --- | --- |
| no MQTT file | existing authoring/native Host behavior |
| valid files and successful attach | one connection, empty durable current-target authority |
| broker/setup refusal | fail Host startup, retire partial transient children |
| publisher/client/source/report/Store loss | terminal composition, retire all transient children; no reconnect |
| Store child restart | retained pure configuration/history, MQTT stays unavailable in this Host incarnation |
| full explicit Host startup | newly seal current files and create new source/custody epochs; current target must be reviewed/reselected |

The temporary composition is not recreated by an in-place Store restart.
Child restarts cannot read changed disk policy, reconstruct the old publisher
or reuse a source epoch. Full Host startup, including a containing supervisor's
new Host incarnation, selects a new sealed basis. A running connection keeps its
already accepted credentials; file edits do not hot-reload or renew authority.
Stop the owning Host before changing intended files. Backups/quarantined Store
restores cannot create installation files or current MQTT authority.

**MI-05 — Foreground immutable publication.** Configuration and credential
installers take an existing canonical private root and explicit private source.
Validate/recheck the source, publish exact bytes with PrivateFile's exclusive
nonreplacement/synchronization, and return identical success on an exact retry.
Different destination bytes refuse; no overwrite, chmod repair, root creation,
Store, socket or broker connection. Config installation reconstructs against the
installed authoring file, validates its chosen credential if required, and returns
only config SHA256/channel count. Credential installation returns only installed
true, never username/password/hash. Separate publication is intentional: install
credentials and authoring first, MQTT config last, then start Host. There is no
false atomic multi-file activation claim or running-service mutation route.

Public fixed errors are invalid_mqtt_configuration, mqtt_configuration_unavailable,
mqtt_configuration_changed, mqtt_configuration_exists,
mqtt_profile_configuration_required, invalid_mqtt_credential,
mqtt_credential_unavailable, mqtt_credential_changed and mqtt_credential_exists.
Inherited unavailable-producer/limit errors may retain their owning fixed atoms.
Composition catches foreign exceptions/reasons as mqtt_installation_unavailable.
All public process calls and setup remain finite. Diagnostics print no raw input
or foreign failure term. Configuration publication is not a durable Store receipt.

## Compatibility and acceptance

Existing profile-authoring-v1.json grammar stays authoring-only; its native
five-key live-publisher mode and explicit nil override remain unchanged. The
new file is opt-in. Existing authoring/generation, local API, archive and default
disabled dispatch behavior must retain focused regression evidence. Native
operator file selection/presentation and signed credential brokerage remain
WOH.08 delivery work; this contract supplies the ordinary shared/native Host
runtime and private foreground provisioning path, not installed signing evidence.

Before code, freeze independent malformed/absent/lifecycle expectations. Use
literal MQTT broker frames and actual public producer APIs/SQLite for acceptance.

| Case | Requirements | Stimulus and falsifier | Level |
| --- | --- | --- | --- |
| MI-T1 | 01/02 | Current explicit registration, profile/capture, ordered channels, local endpoint and none/password files reconstruct; duplicate/unknown/noncanonical base64/invalid UTF-8/limits/wildcard/nonlocal/raw-TCP credential input refuse. No fallback or widened reader bound. | Pure/filesystem |
| MI-T2 | 02/03/05 | Real private publication/retry/conflict, mode/link/symlink/ancestor and same-size content/identity drift, absence appearance/root replacement and sync failure. Changed body/seal cannot become the original startup basis or leak in inspect/errors/output. | Filesystem |
| MI-T3 | 03/04 | Ordinary Host started from private files, actual broker connection/source/report custody, current authoring/capture, actual Store selection/admission and default dispatch false. No caller publisher/env callback, implicit grant or target. | Host/Store/socket |
| MI-T4 | 03/04 | Bad present files and missing authoring/credentials fail before Store/socket; partial broker failure leaves no orphan; every owner loss/Store restart stays terminal; full Host restart creates distinct source epochs. Explicit native nil skips bad files. | Process/socket |
| MI-T5 | 02/05 | Verified controlled TLS resolves only the sealed credential during attach; changed credential before use refuses, wrong peer receives no MQTT CONNECT, installer stdout contains no username/password/hash. | TLS/process |

Full-suite, Dialyzer, release/firmware and installed signing/physical checks are
milestone gates. A synthetic private broker does not qualify a sensor, sample
age, device authentication, autonomous edges or physical control.
