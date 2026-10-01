defmodule WotexHome.Lifx.DirectPowerLimits do
  @moduledoc """
  Compiled Home prevention defaults for the direct Boolean power profile.

  These bound durable handoff attempts, not physical dwell or all LAN packets.
  The complete runtime qualification digest binds both this data and its reader.
  Requests and device workers cannot supply overrides.
  """

  def attempts do
    %{
      profile: "lifx-direct-power-attempt-v1",
      window_ms: 60_000,
      max_handoffs: 32,
      min_gap_ms: 250
    }
  end
end
