import Config

config :logger, backends: [RingLogger]
config :shoehorn, init: [:nerves_runtime]

# The Nerves data partition is the only writable Home state location. Home
# refuses startup if this path cannot be created with private permissions.
config :wotex_home, data_dir: "/data/wotex-home"

# Wired LAN only. DHCP is local broadcast and starts without WAN or DNS.
# The connectivity checker must not use VintageNet's public-host defaults.
# The only configured probe is loopback; Home does not use its internet status
# as an admission condition. This avoids VintageNet's public-host fallback.
# This image has no network administration listener or SSH dependency.
config :vintage_net,
  config: [{"eth0", %{type: VintageNetEthernet, ipv4: %{method: :dhcp}}}],
  internet_host_list: [{{127, 0, 0, 1}, 1}],
  persistence: VintageNet.Persistence.Null

# Deliberately no Nerves.Runtime.StartupGuard or automatic firmware validation.
# An unvalidated image must be checked on the real board before being marked
# good; Store availability alone is insufficient for production admission.
