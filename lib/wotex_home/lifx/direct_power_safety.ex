defmodule WotexHome.Lifx.DirectPowerSafety do
  @moduledoc """
  Static guard scope for the one qualified integrated LIFX Light power profile.

  This admits no sensor-dependent invariant or external load. A caller must
  separately establish reviewed identity, current qualification, authority and
  reported-state freshness. This decision alone never authorizes transport.

  `decision/1` returns `:unknown` for every declaration outside the exact
  integrated Light power subset. Call it again at the durable command gate;
  it does not infer safety from a discovery packet or vendor feature bit.
  """

  alias WotexHome.Semantics.{Capability, Thing}

  @spec decision(Thing.t()) :: :allow | :unknown
  def decision(
        %Thing{role: "Light", capabilities: %{"power" => %Capability{} = power} = caps} = thing
      ) do
    if map_size(caps) == 1 and power.thing_id == thing.id and power.role == "Light" and
         power.profile_ref == thing.profile_ref and power.value_kind == "boolean" and
         power.unit == "none" and power.operations == ["read", "write"] and
         power.risk_class == "ordinary" and power.constraints == %{} and
         power.extensions == %{} do
      :allow
    else
      :unknown
    end
  end

  def decision(_thing), do: :unknown
end
