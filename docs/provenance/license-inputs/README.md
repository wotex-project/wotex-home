# Pinned release license inputs

These are unmodified license texts for components in the current development
release. The component inventory checks their hashes and maps versioned inputs
only to the listed application versions. A dependency or toolchain update needs
a fresh source check and mapping.

| Runtime source | Exact source file | Local SHA-256 | Mapped components |
| --- | --- | --- | --- |
| Erlang/OTP `OTP-28.5.0.6` | [LICENSE.txt](https://github.com/erlang/otp/blob/OTP-28.5.0.6/LICENSE.txt) | `809fa1ed21450f59827d1e9aec720bbc4b687434fa22283c6cb5dd82a47ab9c0` | OTP applications and ERTS listed in `mix woh.release.components` |
| Elixir `v1.19.6` | [LICENSE](https://github.com/elixir-lang/elixir/blob/v1.19.6/LICENSE) | `a6cba85bc92e0cff7a450b1d873c0eaa2e9fc96bf472df0247a26bec77bf3ff9` | Elixir, IEx and Logger listed in `mix woh.release.components` |
| Maude `Maude3.5.1` | [COPYING](https://github.com/maude-lang/Maude/blob/Maude3.5.1/COPYING) | `32b1062f7da84967e7019d01ab805935caa7ab7321a7ced0e30ebe75e5df1670` | `maude-bundled` executable and standard library payload |
| Apache 2.0 canonical text | [LICENSE-2.0.txt](https://www.apache.org/licenses/LICENSE-2.0.txt) | `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30` | `db_connection` 2.10.2 and `rustler_precompiled` 0.9.0 with separately pinned package notices/metadata |

The Elixir file also matches the local `mise` installation byte for byte. This
inventory records source inputs. It makes no component or file-level license
conclusion, and it does not cover the native app, release wrapper, other missing
dependencies or the WoTEx Home project's own licensing decision.

The Maude file is the GPL version 2 text from its exact upstream tag. The
inventory also records the vendored third-party notice. Those inputs do not
establish the provenance of the bundled executable, a corresponding-source
offer or compliance with redistribution obligations. Maude remains under
release review even when its license input status is `present`.
The current macOS development release copies this license text and the vendored
third-party notice alongside its Maude payload; the release inventory covers
both files. The Nerves image has no Maude executable and does not rely on this
macOS release step.

The locked Hex packages `db_connection` 2.10.2 and `rustler_precompiled` 0.9.0
contain an Apache-2.0 notice and copyright in their README, with the same
license identifier in `hex_metadata.config` and their tagged upstream `mix.exs`.
Neither tagged source tree nor installed Hex package includes a standalone
license file. The inventory pins the exact README and metadata bytes and this
canonical Apache text, and the macOS release copies the text into each package's
`priv/LICENSE`. Their input status is `present` only when all those files match.
This does not determine license applicability to every file or complete the
release review; SPDX conclusions remain `NOASSERTION`.

The [vendored WoTEx UDP snapshot](../wotex-udp-vendor.md) carries its own
Apache-2.0 `LICENSE` and `NOTICE`. Both are pinned source inputs, copied into
the macOS and Nerves development releases, and checked in their respective
packaging gates. Their presence does not decide Home's project license or close
the full distribution review.
