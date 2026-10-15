# Native MQTT observation publisher

Version: 0.1.0. Updated: 2026-10-15. Status: accepted successor target.
Owner: WOH.03 H03-T7; WOH.18 H18-T11/T12; WOH.16 source/runtime custody.
Implementation: planned. Evidence: missing.

## Result and boundaries

One explicitly started WotexHome.MQTT.Publisher owns one configured source and
one MQTT 3.1.1 TCP/TLS connection. It publishes a checked source and decoded
reports to existing SourceOwner/ReportOwner, and admits their original IDs through
Authority.accept_external_report. Only Store authenticates the retained selection
author, checks trust/policy/source/current target and commits observations.
The worker gets an Authority handle, never an SQLite connection or bearer.
Loading libraries or starting Publisher opens no connection or selects a target.
There is no socket/model route for configuration, raw packets or receive clocks.

The [cohort](mqtt-producer-cohort-v1.md) owns exact JSON/projection APIs.
[Source selection](external-source-selection-v1.md) owns checked identity and
consumer policy; [report custody](external-report-custody-v1.md) owns receipt
incarnation, original bytes, leases and retirement; [observations](external-observations-v1.md)
own durable original/sequence/freshness checks. No unit conversion, semantic
catalogue, generic interpreter, selector walker or MQTT wire client is copied
into Home. WoTEx JSONProjection and EMQTT provide those generic mechanics.

## Closed native configuration

**MP-01.** start_link/1 takes exactly a native ordinary map with keys reader,
projection, source, channels and connection. Optional GenServer registration is
not supported. Reader is a current checked ReaderSelection; projection is a
public WPF Projection revalidated through Projection.to_map under the identical
reader limits/capture epoch/digest/binding. Its selected binding must be explicitly
installed with JSONProjection.selector_schema, and allow observeproperty. Each
configured channel must name an included observable channel plan, retain its
exact selector and pass JSONProjection.validate_selector. At most 32 channels.
The source/channel policy otherwise follows ExternalSourceSelection.new/3.
Its complete-input wrapper allows the source contract's single extra depth level;
the independently revalidated reader and decoded reports keep their own limits.

Source has exactly source_ref, stable_id, source_generation, method and trust;
the publisher supplies a new random lower-hex32 source_epoch for its incarnation.
Generation is explicit positive signed-64. A new incarnation is not an automatic
successor of a retained source selection. No method/trust is inferred from topic,
TLS, URI or payload. TLS authenticates the configured broker, not an individual
sensor; authenticated_device and bridge_attested assertions are not accepted by
this first generic publisher. Explicit trust is unauthenticated_local or synthetic_lab.
Reader capture is separately supplied host evidence; no device model is guessed.

Connection is exactly address (literal IPv4 tuple), local_address (literal IPv4
tuple currently on the host), port (1..65535), tls and credentials. Both addresses
must be loopback, RFC1918 private or IPv4 link-local; no hostname resolution,
proxy, discovery, cloud endpoint, URL credential or route selected by a profile.
The local address is explicitly bound to the TCP socket. Every publication
rechecks that local address remains present. Topics are exact unique sorted
Topic Names from included selectors, at most 32; no wildcard subscriptions.

Tls is nil for unencrypted operator-local transport, or exactly server_name
(ASCII DNS name 1..253 bytes) and cacerts (1..8 explicit DER CA certificates,
1..16384 bytes each, aggregate at most 65536). Verify the peer and DNS hostname,
SNI and certificate validity using OTP TLS, with no redirect or downgrade. Raw
TCP permits no credential. Credentials is a trusted zero-arity provider returning
:none or {:password, username, password}; username is UTF-8 1..128 bytes and
password binary 1..4096 bytes. Resolve it only during the one explicit attach,
keep it out of Publisher state/status/logs and never send it before TLS peer
verification. Provider code is trusted native code, not a profile callback.
An independent five-second setup watchdog bounds even a blocked provider/client.
TLS's OS validity clock does not establish a qualified Home scheduling clock.

EMQTT is exact Hex 1.16.1. Compile with BUILD_WITHOUT_QUIC=1 in every environment;
its hard quicer 0.2.15 resolver requirement is compile/app/runtime-disabled.
Only TCP/TLS is supplied. MQTT clean session is true, reconnect false, v4
(3.1.1), keepalive 30 seconds, connect and acknowledgement timeouts three seconds,
inflight bound one, subscriptions request QoS 1. Require every SUBACK grant to
be 0 or 1 and reject nonzero session-present. The local parser packet ceiling is
70000 bytes; decoded payload ceiling remains 65536. No Will, persistence,
restored Session, outbound device PUBLISH or automatic retry/reconnect is enabled.
QoS acknowledgements establish protocol handling only, not durable admission.

## Installation and transitions

**MP-02.** Constructor returns an idle temporary child; child_spec restart is
temporary. source/1 returns its checked source selection for trusted native
composition. status/1 returns only phase, received/accepted/refused counters,
pending frame count and uncertain original metadata. No payload, stable identity,
endpoint, credential, capture or typed projection is exposed in status.

attach/4 takes Publisher, Authority, current SourceOwner and ReportOwner PIDs.
Require a live Store reference and live owners. Revalidate configuration, publish
the exact source from this Publisher PID, fetch this report owner's clock epoch,
then open the connection and subscribe. Monitor/link the actual connection and
both owners. Setup failure terminates the publisher and its connection; their
monitored custody retires. Repeated attach refuses without a second connection
or new epoch. Existing Host.profile_installation accepts this live Publisher
as before; actual immutable installed MQTT configuration and native UI delivery
are separate successors, not supplied by an authoring file.

| State | Event | Result |
| --- | --- | --- |
| idle | first valid attach | checked source, one connection/subscription, running |
| running | bounded actual delivery | reports buffered; original-ID admission queued |
| running | admission worker result | counters updated; next queued frame runs |
| running | admission timeout/death | same frame originals become uncertain; stop admitting new frames |
| uncertain | explicit reconcile/1 | retry only those identical original epoch/IDs, with unchanged report times |
| any | owner/connection loss, malformed transport metadata, capacity failure or stop | terminal; close connection, kill owned work and retire custody |

No terminal state reconnects or restores transient sources/reports. A replacement
needs a new Publisher, source/report custody incarnations and explicit current
Store target reselection. Historical original receipts remain Store-owned.

## Delivery clocks, counters and bounded work

**MP-03.** The EMQTT publish callback is the precise application-delivery receive
boundary: before handing to Publisher it records System.monotonic_time(:microsecond)
and increments its own unsigned-64 receipt ordinal from 1. This is host receipt
order, not a device-provided sequence, MQTT Packet Identifier or measured sample
age. It defines the original newly constructed report sequence; it never replaces
null sequence in an already supplied report. Source_time is always null. The
original receipt instant/epoch are carried unchanged through queueing and SQL.
At maximum ordinal, retire before wrapping. An explicit new source incarnation
starts a separate ordinal namespace and cannot reset an old Store cursor.

Use an atomic four-credit gate before sending callback messages; no more than
four raw delivery messages may wait. Callback sends only its bounded payload,
validated packet metadata, original clock and ordinal under a private reference.
The Publisher accepts frames only from its actual configured client PID/reference;
ordinary native callers cannot submit report bodies. Invalid/oversized transport
metadata, unexpected topic or exhausted credit terminates that connection.
Early setup frames retain their callback times; dead-client frames refuse.
These are engineering bounds, not a measured whole-process memory guarantee.

Decode/project every configured channel on the matching exact topic through
public JSONProjection. A missing selected field becomes quality unknown with
reason missing_value and C02 null; a bounded malformed/unrepresentable JSON
payload becomes quality invalid, reason invalid_payload and C02 null. Valid
projected values remain untouched, quality usable, with no sensor-specific branch.
The WPF interpreter and Home consumer decide sentinels/domains/units later.
For multiple topics, only matching channel plans produce reports. All reports
from one frame retain the same actual ordinal and receive time.

Continuity is retained when retain=true; otherwise replayed when dup=true;
otherwise baseline. Never claim continuous or infer a source timestamp/device
age from MQTT/QoS. Each actual new nonretained delivery can be a baseline receipt;
retained/duplicate delivery never becomes a fresh observation merely through
republication. Source trust remains explicit. Synthetic_lab stays ineligible for
fresh production preview under existing Store rules.

Report ID is an opaque bounded Home ID generated once per frame/channel from
publisher incarnation, ordinal and channel index. Reports use the current source
SHA, exact profile/binding/capture coordinates and all thirteen WPF fields.
ReportOwner retains unchanged bounds, including its canonical report depth/bytes;
a projection acceptable to the generic decoder can still exceed Home custody
bounds and must refuse. No larger limit or partial report is substituted.

**MP-04.** Buffer at most four frame-original batches including one active batch,
and at most 32 report originals per frame. ReportOwner's 128-active/4 MiB/body
and 1024-incarnation-original quotas remain authoritative. Capacity is inclusive;
no eviction, original reuse or clock renewal. One owned worker admits each batch
through Authority; channels commit independently, not as an atomic multi-channel
physical sample. An independent five-second worker watchdog kills blocked work.
Its monitor records uncertainty; no exception/Store-private term is exposed.

Reconcile retries the same original IDs only. Store performs original lookup
before current bytes/source/sequence guards; a committed retry returns its
historical receipt without fresh time. A pending original still obeys its original
expiry/current guards. A definite refusal is not republished with another ID/time.
New packets while uncertain are not admitted; no queued old frame is assigned a
later receive instant. Killing a caller/worker cannot undo a committed original.
The publisher retains no durable second journal or SQLite writer.

## Privacy and errors

**MP-05.** Publisher format_status redacts state, messages and reasons. Catch
foreign provider/client/worker failures as fixed atoms; never log raw packets,
selectors, credentials, stable identities or foreign reason terms. Before client
startup install one stateless Home logger primary filter for EMQTT diagnostics:
match EMQTT MFA events, gen_statem termination reports naming emqtt, and proc_lib
crash reports whose initial call names emqtt. Drop those diagnostics, preserve
unrelated logs and refuse an existing conflicting filter identity. The filter
holds no payload/PID/credential registry. EMQTT 1.16.1's ordinary build lacks a
redacting format_status; its generic crash state cannot enter ordinary logs.

Native configuration/attachment failures use invalid_mqtt_publisher,
invalid_mqtt_connection, mqtt_owner_unavailable, mqtt_already_attached,
mqtt_connection_unavailable or mqtt_logging_unavailable; public calls sanitize
lost/dead process replies as mqtt_publisher_unavailable. Reconcile without an
uncertain original refuses mqtt_not_uncertain. Per-original definite Store refusal
is counted, not converted to success. Internal termination reasons are fixed;
status contains no raw foreign refusal/exception. All API calls have finite bounds.

## Entry and acceptance

Before code freeze this state/input contract and independent receipt/report
traces: ordinary, retained, duplicate, missing value, malformed JSON, same original
reconcile, owner loss and uint64 exhaustion. Expected clock/sequence/continuity
rules are independent of production projection or Store encoding.

| Case | Requirements | Stimulus and falsifier | Level |
| --- | --- | --- | --- |
| MP-T1 | 01–04 | Real controlled broker sends independent MQTT frames through actual EMQTT to source/report custody and current Store selection. Multi-channel exact values, original times/counters and authenticated preview correspond. A synthesized clock, rounded number, implicit target/grant or continuous claim fails. | Local TCP/software |
| MP-T2 | 01/03 | Wrong/unavailable address, malformed native config/selector, unsubscribed topic, malformed/oversized payload and wire packet, credit/frame/body limits and ordinal exhaustion. Leak, unbounded queue, wrap or fallback fails. | Boundary/socket |
| MP-T3 | 02–04 | Retained/dup, missing/invalid field, delayed admission, lost reply/reconcile, client/source/report/Store owner loss and source replacement. Renewed freshness, changed original or resumed terminal publisher fails. | Process/Store |
| MP-T4 | 01/05 | Verified controlled TLS, wrong CA/hostname and plaintext credentials; credential provider hang; actual EMQTT normal and crash diagnostics with secret canaries plus an unrelated log. Early credentials, leak, silently changed logger filter or orphan socket/worker fails. | TLS/process |

Full suite, Dialyzer, complete release/native firmware and installed/physical
qualification are milestone checks. This software path does not qualify a sensor,
broker fleet, source sample age, autonomous reported edges or physical dispatch.

## Sources

- [OASIS MQTT 3.1.1 (2014-10-29)](https://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html): Session, SUBACK, DUP/retained and QoS interpretation.
- [EMQTT 1.16.1](https://github.com/emqx/emqtt/tree/1.16.1): source-inspected callback delivery, parser size, timeout units, ownership and logging behavior; no patched dependency source.
- The exact consumed WoTEx Runtime/MQTT contracts and Home source/report/observation owners above define their existing unchanged seams.
