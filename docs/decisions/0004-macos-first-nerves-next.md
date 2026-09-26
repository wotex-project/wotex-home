# ADR 0004: macOS first, Nerves next

Status: Accepted.

The physical PoC runs on macOS + Elixir/OTP. Nerves later packages the same core as an appliance. Host-specific code is kept behind explicit ports so embedded deployment does not distort the development architecture.
