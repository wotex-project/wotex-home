# October 2026 dependency review

Registry and changelog review on 2026-10-13 covers Home's root and Nerves
lockfiles, released owned libraries used by these projects, and the CI failures
at their actual hosted revisions. Locks bind resolved artifacts; sibling HEADs
and passing historical runs do not establish the upgraded tree's behavior.

| Selected change | Source and consumption decision |
| --- | --- |
| ExMaude 0.5.0, exact Hex requirement | [Release changelog](https://github.com/futhr/ex_maude/blob/v0.5.0/CHANGELOG.md): absolute search deadlines, path decoding, cancellation, executable identity and caller-loss cleanup. Home retains the receipt conflict API and inconclusive no-finding result. The interpreter is separately staged; see [source record](ex-maude-source.md). |
| Exqlite 0.42.0 | [Changelog](https://github.com/elixir-sqlite/exqlite/blob/v0.42.0/CHANGELOG.md): 0.41 adds a DBConnection authorizer option; 0.42 fixes statement finalization while a connection is in its busy handler. Home retains its single low-level Store connection and transaction ownership; it does not add another DBConnection owner. |
| Bumblebee 0.8.0, Axon 0.9.0, Nx/EXLA 1.0.0 | [Bumblebee](https://github.com/elixir-nx/bumblebee/blob/v0.8.0/CHANGELOG.md), [Nx](https://github.com/elixir-nx/nx/blob/v1.0.0/nx/CHANGELOG.md), [EXLA](https://github.com/elixir-nx/nx/blob/v1.0.0/exla/CHANGELOG.md): upgrade the development training stack together. Nx removes token hooks, old sigils and reflect; the existing trainer uses none of those APIs. Development inference/training does not authorize control. Transitive image, signal, safetensors and complex packages follow the resolved Nx 1.0 graph. |
| RustlerPrecompiled 0.10.0 | [Changelog](https://github.com/philss/rustler_precompiled/blob/v0.10.0/CHANGELOG.md): supports OTP 29 NIF 2.18 and fixes destructive replacement of an existing loaded library. Refresh exact README and Hex metadata hashes in the release license inventory; the canonical Apache text is unchanged. |
| Pi system 2.1.2 | [System changelog](https://github.com/nerves-project/nerves_system_rpi4/blob/v2.1.2/CHANGELOG.md): incorporates the 2.1 system's OTP 29, GCC 15, kernel and Buildroot changes plus security fixes. Nerves host compilation retains Elixir 1.19.6 and selects OTP 29.0.4. Old image, native-closure, driver and board receipts do not transfer to the new system. |
| BeamNotify 1.1.2 and UBootEnv 1.0.3 | [BeamNotify](https://github.com/nerves-networking/beam_notify/blob/v1.1.2/CHANGELOG.md) fixes parallel compilation and uses safe binary decoding; [UBootEnv](https://github.com/nerves-project/uboot_env/blob/v1.0.3/CHANGELOG.md) rejects invalid environment keys/values. Neither change validates firmware or changes Home's default-disabled dispatch. |

All root locked Hex packages resolve to the registry's current stable releases.
The Nerves graph retains MuonTrap 1.8 because VintageNet 0.13.13 excludes 2.x,
and the system-selected Buildroot and toolchain packages must remain compatible
with that exact Pi system. Do not override these constraints merely to match
an unrelated newest package version.

Hex has no published `wotex_udp` package at the review date. Retain its exact
Git pin and existing generic datagram API. ExBooking 0.2.3 is released, but Home
has no runtime dependency on it yet; its new occurrence enumeration remains an
unreleased producer addition and cannot be claimed through that release.

The latest Home Actions run failed compiling the nested weak Swift capture in
`ControllerGuardCheck`. Explicit property/method access fixes that compiler
error; local native fixtures establish their own narrower evidence. Updated CI
provisions standalone interpreter inputs because the selected ExMaude archive
contains no interpreter. Hosted CI requires the user's manual push and run.
