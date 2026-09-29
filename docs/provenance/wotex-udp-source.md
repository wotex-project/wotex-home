# WoTEx UDP dependency source

Home pins [`wotex-project/wotex` commit `dde1837f03f88a847ba5a0ec4479711a5ff1cf96`](https://github.com/wotex-project/wotex/tree/dde1837f03f88a847ba5a0ec4479711a5ff1cf96)
and checks out only `packages/wotex-udp` with Mix's `:sparse` Git option. Its
package tree at that revision is `f04cccc514ea7beed6b0a8020fd2bedd1e7cc547`.
A neighboring `../wotex/packages/wotex-udp` Mix project is used for local
development. `WOTEX_HOME_GIT_DEPS=1` forces the pinned Git source; CI uses this
setting. A local override is useful for joint development but cannot establish
release provenance for the pinned revision.

The selected package supplies a passive, bounded socket owner with explicit
local binding, deadlines, queue limits and owner epochs. Home's adapter checks
its selected IPv4 prefix and LIFX endpoints before sending. The pinned endpoint
constructor represents only `.255` IPv4 broadcast addresses and rejects
unicast peers ending in `.255`. Valid `/25` directed broadcast and some `/23`
unicast addresses therefore fail closed. Those cases need an upstream fix and
requalification before Home claims the full selected-prefix contract.

The upstream Apache-2.0 `LICENSE` and `NOTICE` have byte-identical,
hash-checked copies in [`license-inputs/`](license-inputs/README.md) for the
macOS and Nerves releases. Their presence records legal inputs; it does not
complete distribution review. Updating the Git ref requires source review,
new hashes and the adapter, release and Nerves packaging gates.
