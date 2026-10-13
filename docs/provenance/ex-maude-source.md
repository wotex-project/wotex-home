# ExMaude dependency source

Home selects the released [ExMaude 0.5.0 Hex archive](https://hex.pm/packages/ex_maude/0.5.0)
with the exact `== 0.5.0` requirement. `mix.lock` binds the registry checksums
and its transitive dependency graph. CI and ordinary builds use that archive.
`WOTEX_HOME_PATH_DEPS=1` explicitly selects neighboring development checkouts;
`WOTEX_HOME_GIT_DEPS=1` overrides that development setting for older build
commands. A path checkout is not release evidence.

The [0.5.0 changelog](https://github.com/futhr/ex_maude/blob/v0.5.0/CHANGELOG.md)
adds absolute search deadlines, cancellation and complete path decoding, and
fixes executable identity and caller-loss retirement. Home consumes the public
`ExMaude.IoT.detect_conflicts_with_receipt/2` API, owns no pool, and retains its
narrow negative conflict screen. No finding stays inconclusive. New general
search capabilities do not expand Home's model or authorize a rule.

The Hex archive contains the MIT library and bundled model source, but no
Maude interpreter. The macOS development release separately stages the existing
Maude 3.5.1 arm64 asset through `mix woh.maude.payload.stage ZIP`. This task
checks the archive digest and all fourteen file digests, rejects linked or
oversized files and an existing destination, then stages the platform executable
name expected by ExMaude. Release smoke verifies the same exact payload.
The isolated offline release fetches ExMaude from the locked Hex cache and
copies only this separately verified payload; it never copies a sibling library
or treats a Git checkout as the Hex archive. Linux arm64 and Nerves continue to
remove unsupported interpreter payloads and fail closed when verification is
unavailable. Linux x86-64 CI installs its interpreter separately for integration
checks; it does not establish arm64 release support.

The archive's MIT license and third-party notice remain byte-identical to the
copies in [license-inputs](license-inputs/README.md). RustlerPrecompiled 0.10.0
requires refreshed notice/metadata hashes. Interpreter installation, native
closure, license review and physical qualification remain separate obligations.
