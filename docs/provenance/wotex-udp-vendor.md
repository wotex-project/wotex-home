# WoTEx UDP source snapshot

Home uses a committed source snapshot of the WoTEx UDP package because an
isolated offline build must not depend on a neighboring checkout or a live Git
fetch. The snapshot is from `wotex-project/wotex`, commit
`dde1837f03f88a847ba5a0ec4479711a5ff1cf96`, package tree
`f04cccc514ea7beed6b0a8020fd2bedd1e7cc547` at `packages/wotex-udp`.

`vendor/wotex_udp` contains the upstream `lib/` files, `mix.exs`, `README.md`,
`LICENSE` and `NOTICE` unchanged. It omits upstream tests, benchmarks and
contributor tooling; Home tests its own adapter and release integration. The
package declares Apache-2.0. Home pins the copied license and notice hashes in
its release checks and ships both files with the packaged application. This
records source and legal inputs, not a completed distribution review.

The selected package gives Home a passive, bounded socket owner with explicit
local binding, deadlines, queue limits and owner epochs. Home's adapter checks
its selected IPv4 prefix and LIFX endpoints before sending. The upstream
endpoint constructor currently represents only `.255` IPv4 broadcast addresses
and rejects unicast peers ending in `.255`; valid `/25` directed broadcast and
some `/23` unicast addresses therefore fail closed in Home. Those endpoint
cases must be fixed upstream and then requalified before Home claims the full
selected-prefix transport contract.

To update this snapshot, select a committed upstream revision, copy the same
source set, compare every copied file with that revision, update the provenance
and pinned legal hashes, then rerun the adapter, release and Nerves packaging
gates. A newer WoTEx checkout alone does not change Home's dependency.
