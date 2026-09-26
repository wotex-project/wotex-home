import Config

config :ex_maude,
  pool_size: 2,
  pool_max_overflow: 0,
  # Disable PTY wrapper in test - avoids "openpty: Device not configured" errors
  use_pty: false

# Reduce log noise in tests
config :logger, level: :warning
