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
unicast peers ending in `.255`. Home does not patch or bypass that owner. For
LIFX discovery it translates every selected-prefix broadcast role to the
standards-defined on-link limited broadcast `255.255.255.255`, which the pinned
constructor represents. This covers `/8` through `/30` discovery without
changing LIFX framing or socket ownership. A `.255` address can still be a
valid unicast host in a wider prefix such as `/23`; Home classifies it from the
prefix. It then uses the dependency's explicit broadcast-enabled endpoint only
as a compatibility send-policy tag while preserving the exact destination IP
and Home route intent as unicast. The owner passes that unchanged address and
port to the OS. This is safe only after Home has rejected the selected
prefix's network and directed-broadcast roles; it is not a last-octet shortcut.
[RFC 1812 section 5.3.5](https://www.rfc-editor.org/rfc/rfc1812#section-5.3.5)
states that broadcast classification depends on the destination network
prefix, which is the information Home has and the pinned endpoint constructor
lacks. Pure matrices cover the compatibility route for every supported wider
prefix `/8` through `/23`.

Home does not rely on the package's configurable defaults. Its inert adapter
configuration fixes a 1,024-byte datagram ceiling, 2,048-byte receive-buffer
request, one-datagram batch limit, one pending call, 1,024 queued send bytes,
ten-second maximum deadline, hop limit one, broadcast enabled and multicast
disabled. The package reads 1,025 bytes for that configuration and rejects an
oversized datagram after consuming it, avoiding silent acceptance of a
truncated LIFX packet; OTP's `socket:recvfrom/4` otherwise truncates when its
buffer is too small. The Home capability map and socket-free tests pin these
assumptions alongside the dependency commit. Package loopback tests separately
cover OS behavior, owner loss, stale handles, overload, expired queued sends
and port reuse. Home reduces the structured package error to its stable kind
atom at the adapter boundary, so raw payloads, endpoints and OS terms do not
cross into protocol sessions.

The upstream Apache-2.0 `LICENSE` and `NOTICE` have byte-identical,
hash-checked copies in [`license-inputs/`](license-inputs/README.md) for the
macOS and Nerves releases. Their presence records legal inputs; it does not
complete distribution review. Updating the Git ref requires source review,
new hashes and the adapter, release and Nerves packaging gates.
