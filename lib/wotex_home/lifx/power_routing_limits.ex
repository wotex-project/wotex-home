defmodule WotexHome.Lifx.PowerRoutingLimits do
  @moduledoc "Closed Home power-routing budgets. Bound by the complete runtime artifact; not a device response-time guarantee or caller option."

  def policy do
    %{
      profile: "home-lifx-power-routing-v1",
      discovery_ms: 200,
      read_ms: 200,
      owner_budget_ms: 500,
      caller_timeout_ms: 1_000
    }
  end
end
