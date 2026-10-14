defmodule WotexHome.Lifx.PowerRoutingLimits do
  @moduledoc """
  Defines the fixed Home budget for qualified LIFX power routing.

  `policy/0` returns millisecond budgets for discovery, fresh reads, owner work
  and the caller deadline. The closed policy is bound by the complete runtime
  artifact rather than exposed as an unreviewed request option.

  A budget bounds Home's work and refusal behavior. It is not a device response
  time guarantee, a freshness certificate or permission to dispatch.
  """

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
