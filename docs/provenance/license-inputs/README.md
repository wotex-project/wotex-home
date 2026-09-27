# Pinned release license inputs

These are unmodified license-file inputs for the exact runtime versions used by
the current development release. The component inventory checks their hashes
and maps them only to the listed application versions. A new toolchain version
needs a fresh source check and mapping.

| Runtime source | Exact source file | Local SHA-256 | Mapped components |
| --- | --- | --- | --- |
| Erlang/OTP `OTP-28.5.0.6` | [LICENSE.txt](https://github.com/erlang/otp/blob/OTP-28.5.0.6/LICENSE.txt) | `809fa1ed21450f59827d1e9aec720bbc4b687434fa22283c6cb5dd82a47ab9c0` | OTP applications and ERTS listed in `bin/release_components.py` |
| Elixir `v1.19.6` | [LICENSE](https://github.com/elixir-lang/elixir/blob/v1.19.6/LICENSE) | `a6cba85bc92e0cff7a450b1d873c0eaa2e9fc96bf472df0247a26bec77bf3ff9` | Elixir, IEx and Logger listed in `bin/release_components.py` |
| Maude `Maude3.5.1` | [COPYING](https://github.com/maude-lang/Maude/blob/Maude3.5.1/COPYING) | `32b1062f7da84967e7019d01ab805935caa7ab7321a7ced0e30ebe75e5df1670` | `maude-bundled` executable and standard library payload |

The Elixir file also matches the local `mise` installation byte for byte. This
inventory records source inputs. It makes no component or file-level license
conclusion, and it does not cover the native app, release wrapper, other missing
dependencies or the WoTEx Home project's own licensing decision.

The Maude file is the GPL version 2 text from its exact upstream tag. The
inventory also records the vendored third-party notice. Those inputs do not
establish the provenance of the bundled executable, a corresponding-source
offer or compliance with redistribution obligations. Maude remains under
release review even when its license input status is `present`.

The locked Hex packages `db_connection` 2.10.2 and `rustler_precompiled` 0.9.0
contain an Apache-2.0 notice and copyright in their README, with the same
license identifier in `hex_metadata.config`. Neither package includes a
separate license text in the installed Hex source. The inventory pins the exact
README and metadata bytes and labels these components `notice_only`, leaving
the full license-input and review work open.
