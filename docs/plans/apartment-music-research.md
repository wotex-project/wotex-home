# Apartment music research and source reconciliation

Version: 0.1.1. Reviewed: 2026-10-13. Status: inspected research.
No code, source fork, dependency selection, installation, hardware test or
physical support claim is established by this record.

## Requested outcome and inventory

The operator wants the same music throughout the apartment, from computer audio,
Spotify or retained media, using as much existing hardware as qualified routes
permit. Genuine surround is not required. A shared music startup buffer is
acceptable; synchronization and legacy support must be measured honestly.
The operator confirmed **WONDERBOOM 2** in this research conversation.

| Candidate | Known identity | Investigated route and unresolved facts |
| --- | --- | --- |
| Sonos PLAY:1 | Photo-reviewed model; firmware and S1/S2 configuration not recorded | Local control/HTTP audio first; cross-brand timing unresolved. Native group behind a separately enrolled AirPlay-capable coordinator is optional |
| HomePod mini | Operator-confirmed purchase; firmware not recorded | AirPlay output; current pairing/timing/installed permission and mixed-cohort measurement required |
| Nest Wifi Point | H2E; historical Cast snapshot 1.56.514310 | Native Cast group, compatible custom receiver or host Bluetooth; snapshot does not establish current firmware/API availability |
| Bedroom Google speaker | Historical Cast snapshot 3.78.540761; hardware model unknown | Identify exact model, then select Cast/receiver/Bluetooth route; no board compatibility inferred |
| WONDERBOOM 2 | Explicit operator confirmation; acquired around 2020; firmware unreported | Host Bluetooth audio, exact unit/OS/codec/route qualification; standby/reconnect and additional wireless delay |
| Samsung The Frame | Operator-identified TV; year/model/firmware unknown | Exact model's AirPlay or compatible TV receiver; no TV-browser capability assumed |

The earlier [universal research](universal-profiles-routines-research.md)
retains the lighting, cover, sensor, remote and entertainment inventory. This
record extends music delivery; it does not relabel those devices as Matter audio
receivers. Matter control/export and audio streaming remain separate mechanisms.

## Findings and limits

Apple documents process-tap capture on macOS 14.2+, with OS permission and
process-specific selectors. This provides an initial Spotify/computer audio
source without implementing Spotify account authentication or decoding in Rust.
It does not promise every protected application supplies capturable audio.
[Apple sample](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps).

Sendspin specifies a shared audio timeline, four-timestamp clock exchanges,
offset/drift estimation, codec/buffer negotiation and explicit source/player
roles. This is a suitable generic foundation to extend. Rust main is
client-oriented; live GitHub API inspection confirmed server PR #87 open and
unmerged. Its proposed PCM/single-format server defers external-output bridging
and per-client conversion. The October spec has newer security/timing obligations;
proposed server behavior must be audited against the selected exact revision.
[Spec](https://github.com/Sendspin/spec/tree/ee8aad9660fc57345e726a888486f47f66a41f97),
[proposal](https://github.com/Sendspin/sendspin-rs/pull/87).

The inspected AirPlay helper offers modern transport/timing machinery, but its
documented credential input uses `--auth` and its pairing examples print material.
Our adapter contract therefore requires a generic private-FD/IPC credential and
pairing-result extension before production adoption. That interface is proposed,
not a claimed existing feature. [Helper source](https://github.com/music-assistant/airplay-cli/tree/0974a3175913a8f19b47ccdd5ccb6fdf9f2f704a).

Apple documents a monotonic native uptime clock and its nanosecond equivalent.
The host contract explicitly selects that coordinate on macOS; Rust/BEAM
process-local clock origins are not assumed interchangeable. Hardware/remote
mapping and acoustic evidence remain separate. [Apple clock documentation](https://developer.apple.com/documentation/kernel/1462446-mach_absolute_time).

Music Assistant documents AirPlay/Sendspin protocol linking and native Sonos
grouping behind an AirPlay-capable Sonos member. This does not give PLAY:1
native AirPlay. AirConnect can bridge its playback interface, but the author
explains that the HTTP-pull final leg cannot carry precise playback scheduling.
Software playability and mixed-room alignment are separate conclusions.
[Grouping](https://www.music-assistant.io/faq/groups/),
[Sonos](https://www.music-assistant.io/player-support/sonos/),
[AirConnect](https://github.com/philippe44/AirConnect/tree/5fdb61e20de59bac5dbda9f6e2ed56ce549ccabd).

Google documents Nest Wifi Point multiroom playback. Some GC4A 2.0 firmwares
lack Web Audio scheduling needed by the current Sendspin receiver. That refuses
this receiver path, not every possible ordinary-Cast/Bluetooth adapter. Airfoil
documents mixed AirPlay/Cast/Bluetooth delay compensation, while acknowledging
that variable endpoint latency can prevent stable sync. Treat it as a behavioral
comparison target, not proof of a specific household cohort.
[Google compatibility](https://support.google.com/googlehome/answer/10012636?hl=en),
[maintainer explanation](https://github.com/music-assistant/support/issues/5297),
[Airfoil timing](https://www.rogueamoeba.com/support/knowledgebase/?product=Airfoil+for+Mac&showArticle=Airfoil-AudioLatency).

Logitech documents WONDERBOOM 2 Bluetooth playback, last-source reconnect when
powered on and automatic shutdown after 15 minutes of inactivity. Double Up
is a native compatible-speaker feature; our mixed group is hosted above Bluetooth.
No remote wake, Wi-Fi/Matter/AirPlay endpoint or audio-over-USB behavior is
inferred from its charging port.
[Vendor guide](https://support.logi.com/hc/en-us/articles/18546036101143-Getting-Started-WONDERBOOM-2).

The Linux Bluetooth bridge demonstrates ordinary audio outputs represented as
network players. The native Sendspin player includes a macOS AUHAL backend and
hardware-time/latency instrumentation; its README also declares pairing/encryption
and clock-convergence gaps in its selected SDK. It is an implementation reference,
not a production-ready dependency. MassDroid documents microphone-based acoustic
calibration for Bluetooth tails. OS buffer/clock telemetry does not necessarily
measure the final wireless/acoustic delay.
[Bluetooth bridge](https://github.com/trudenboy/sendspin-bt-bridge/tree/9d55b3f0c089920c91c8448764e7ce610a65352d),
[native player](https://github.com/chrisuthe/sendspin-player/tree/54fb3648dd60090e9fdb293b8905505d7604dc3c),
[calibration](https://github.com/sfortis/massdroid_native/tree/8601a8e2b427249c1c96d926bb9698e21aa05c1c).

## Inspected source revisions

These are research snapshots retrieved through read-only GitHub API inspection,
not dependency pins or selected binaries. Read the exact relevant source/tests
and reconcile current protocol semantics again at implementation entry.

| Repository | Revision |
| --- | --- |
| Sendspin/spec | ee8aad9660fc57345e726a888486f47f66a41f97 |
| Sendspin/sendspin-rs | 0cae6bbf5e794f87dfbc986dac2e812fefded12c |
| Sendspin/time-filter | 39dd3f4a7c37bcd63d8e2ee3885bf4d76fcaa61a |
| music-assistant/server | 9f059d09742b1de2aebc7469be27fbcd2a8b26d5 |
| music-assistant/airplay-cli | 0974a3175913a8f19b47ccdd5ccb6fdf9f2f704a |
| trudenboy/sendspin-bt-bridge | 9d55b3f0c089920c91c8448764e7ce610a65352d |
| chrisuthe/sendspin-player | 54fb3648dd60090e9fdb293b8905505d7604dc3c |
| sfortis/massdroid_native | 8601a8e2b427249c1c96d926bb9698e21aa05c1c |
| philippe44/AirConnect | 5fdb61e20de59bac5dbda9f6e2ed56ce549ccabd |

Primary-source documentation establishes opportunities and limits, not installed
or physical evidence. Upstream performance targets and screenshots are not tests
we ran. A fork/contribution is feasible subject to reviewed source/API/notice
compatibility; no remote repository state was created during this research.

## Accepted decisions

Use a portable Rust engine plus thin native host adapters; keep ordinary music
independent of routines/AI/Matter. Start with decoded local/application audio and
specific host outputs, then AirPlay, Cast and legacy speaker cohorts. Support
explicit clocked/calibrated/best_effort/unavailable classifications. Default to
calibrated-or-better and disclose exclusions; a weaker group policy is explicit.
No implicit firmware modification, hub purchase or vendor-API invention is needed
to evaluate the first routes. Unsupported cohorts have a reasoned final refusal.

[WOH.21](../specs/WOH.21-apartment-music.md) and the separately selected component MAU.01–04
own playback requirements; prospective WoTEx WST.01–02 own lower-level stream
protocol joins. External device definitions remain in consumer/publisher collections. The [delivery plan](apartment-music-delivery.md)
owns build order; [the lab procedure](../labs/audio-synchronization.md) owns
actual output measurement. This memo cannot override those contracts.
