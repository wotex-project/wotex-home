# Runtime license inputs

These are unmodified license-file inputs for the exact runtime versions used by
the current development release. The component inventory checks their hashes
and maps them only to the listed application versions. A new toolchain version
needs a fresh source check and mapping.

| Runtime source | Exact source file | Local SHA-256 | Mapped components |
| --- | --- | --- | --- |
| Erlang/OTP `OTP-28.5.0.6` | [LICENSE.txt](https://github.com/erlang/otp/blob/OTP-28.5.0.6/LICENSE.txt) | `809fa1ed21450f59827d1e9aec720bbc4b687434fa22283c6cb5dd82a47ab9c0` | OTP applications and ERTS listed in `bin/release_components.py` |
| Elixir `v1.19.6` | [LICENSE](https://github.com/elixir-lang/elixir/blob/v1.19.6/LICENSE) | `a6cba85bc92e0cff7a450b1d873c0eaa2e9fc96bf472df0247a26bec77bf3ff9` | Elixir, IEx and Logger listed in `bin/release_components.py` |

The Elixir file also matches the local `mise` installation byte for byte. This
inventory records source inputs. It makes no component or file-level license
conclusion, and it does not cover the native app, release wrapper, other missing
dependencies or the WoTEx Home project's own licensing decision.
