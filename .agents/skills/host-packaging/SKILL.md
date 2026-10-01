---
name: host-packaging
description: Build or verify OTP releases, native macOS bundles, or Nerves firmware when delivering artifacts or changing packaging, native dependencies, host lifecycle, or IPC. Select the affected host; excludes ordinary core edits that do not change a host or deliver an artifact.
---

# Host packaging

Input: the requested host/artifact, current committed source revision and
available locked dependency/toolchain cache. Output: the requested artifact or
focused host check, its actual validation results and explicit installed-host
or board requirements that remain untested.

## Match the artifact to its source

Read the applicable host guide before running its commands. Check the selected
toolchain and locked dependency source revisions, and whether the task changes
the native closure or runtime artifact binding. Assembly/inventory checks bind
to a clean current commit; an old artifact does not become current because a
later change only touched documentation or commit metadata.

For a requested fresh OTP release, the existing `bin/build.exs` can use a
selected prebuilt dependency environment. For example,
`elixir bin/build.exs --dependency-env test` explicitly selects that cache.
Use its printed release path for subsequent checks. The build validates
packaged Store/CLI/verifier behavior; real host socket startup/shutdown is a
separate `mix woh.release.smoke <release>/bin/wotex_home` check.

## macOS

Use the [macOS guide](../../../native/macos/README.md) for native builds and
choose the client fixtures matching the changed route. Independent peer
fixtures check framing/decoding; the live CLI parity check compares clients
against one private foreground Store. Neither substitutes for installed app
identity or background-service lifecycle evidence.

For a requested app artifact, run
`mix woh.macos.app.assemble <release>` against the verified current release.
Assembly checks native direct loads/deployment minima and emits the existing
app SPDX/inventory outputs. Inspect their results and the affected window when
layout changes. Registration eligibility is separate from controller health;
signing, notarization and fresh-account lifecycle need their own evidence.

## Nerves

Use the [Nerves guide](../../../native/nerves/README.md) and the selected
`MIX_TARGET`/`MIX_ENV` for host tests or firmware builds. For a requested Pi 4
image, follow the guide's pinned-dependency build and
`mix woh.nerves.image.check` command using the actual release and firmware
paths. Check the root filesystem, native architecture, network/admin surface
and writable data/upgrade layout rather than only the intermediate release.

Host probes and cross-build inspection do not establish boot, firmware-slot
validation, rollback, radio continuity or storage power-loss behavior. Board
checks follow the [appliance contract](../../../docs/specs/WOH.09-nerves-host.md)
and its existing lab procedure on the selected hardware. Report missing native
backends or unresolved firmware validation without inventing a successful pass.

## Delivery evidence

Use the applicable [release/recovery contract](../../../docs/specs/WOH.16-release-recovery.md)
for the delivery stage. Distinguish verified payload integrity and provenance
inputs from artifact authenticity, redistribution clearance and physical
qualification. Report exactly which source, cache, host checks and environment
were used; do not launch unrelated hosts or provision a real controller merely
to validate a packaging edit.
