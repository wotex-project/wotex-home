# Linux arm64 native library inputs

The [native profile](../../native/linux/native-libraries-arm64.json) records
the exact six Debian binary packages used by Linux arm64 release assembly.
Its original and post-`patchelf` SHA-256 values are measured bytes, not hashes
of a package name or a source declaration. The tool also checks binary package
architecture, source package/version, Debian 13, build-host glibc
`2.41-12+deb13u4`, `patchelf 0.18.0` and GNU `readelf` 2.44 before assembly.

| Provider | Binary package version | Source package version |
| --- | --- | --- |
| `libgcc_s.so.1` | `libgcc-s1` `14.2.0-19` | `gcc-14` `14.2.0-19` |
| `libstdc++.so.6` | `libstdc++6` `14.2.0-19` | `gcc-14` `14.2.0-19` |
| `libtinfo.so.6` | `libtinfo6` `6.5+20250216-2` | `ncurses` `6.5+20250216-2` |
| `libcrypto.so.3` | `libssl3t64` `3.5.7-1~deb13u3` | `openssl` `3.5.7-1~deb13u3` |
| `libz.so.1` | `zlib1g` `1:1.3.dfsg+really1.3.1-1+b1` | `zlib` `1:1.3.dfsg+really1.3.1-1` |
| `libzstd.so.1` | `libzstd1` `1.5.7+dfsg-1` | `libzstd` `1.5.7+dfsg-1` |

The unmodified [legal input copies](license-inputs/linux-arm64/) come from
`/usr/share/doc/<binary-package>/copyright` and `/usr/share/common-licenses`
in the selected Debian builder. The profile records a digest for each copy.
Generic `GPL` and `LGPL` aliases are retained as regular byte copies, alongside
the versioned texts. Git attributes preserve exact legal-input bytes, including
trailing whitespace in the two GCC copyright records. Package copyright records can describe broader source
contents than the individual library being shipped; their presence is an
input for review and does not assign a license to every payload byte.

The observed build cohort used the arm64 Erlang image at digest
`sha256:f4cb7409ab8b3e3d792bffae7ec9108686d9fb88510ef75872e5aa874c6c72bc`
and OTP `28.5.0.6`. The Elixir `v1.19.6` OTP-28 archive SHA-256 was
`d69db87541e1e5f4fa3f803353c01a30d4ef0e236c6bf53128b2bbed8b0b9b7e`.
Package/tool queries and source hashes constrain the actual provider cohort
even when a builder tag is reused. A changed package or tool refuses; a future
update needs fresh byte/input review and tests rather than a relaxed guard.
The Docker build environment is not a dependency on the deployed controller.

Assembly copies regular provider bytes into `native/linux-libraries/lib`,
sets each provider RUNPATH to `$ORIGIN`, and checks the pinned transformed
bytes. Other ELF files receive their own path to that directory. OpenSSL's
original ambient search path is replaced. The manifest records original and
packaged digests and the direct-load result. The six packages have separate
component/SPDX groups with exact Debian versions; copyright and common-license
copies are covered by the payload inventory. Source legal hashes are rechecked
by component report creation and verification.

This records observed binary/package provenance and retained legal inputs.
It does not establish artifact authenticity, source-to-binary correspondence,
complete corresponding source or offers, redistribution clearance, dynamic
`dlopen` coverage, installed service qualification or hardware qualification.
All SPDX license conclusions remain `NOASSERTION`, and license review remains
`unresolved`. See the [host procedure](../../native/linux/README.md) and
[release contract](../specs/WOH.16-release-recovery.md).
