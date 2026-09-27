import Config

config :logger, backends: [RingLogger]
config :shoehorn, init: [:nerves_runtime]

# The Nerves data partition is the only writable Home state location. Home
# refuses startup if this path cannot be created with private permissions.
config :wotex_home, data_dir: "/data/wotex-home"

# Deliberately no Nerves.Runtime.StartupGuard or automatic firmware validation.
# An unvalidated image must be checked on the real board before being marked
# good; Store availability alone is insufficient for production admission.
