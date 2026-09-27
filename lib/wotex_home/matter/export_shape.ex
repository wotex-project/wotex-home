defmodule WotexHome.Matter.ExportShape do
  @moduledoc """
  Advisory Home-to-Matter On/Off Light shape for a future bridge server.

  This checks only a Home declaration. It allocates no endpoint, proves no
  qualification, issues no command and cannot enable an upstream Matter server.
  The required server clusters are from the tagged Matter 1.5.1 On/Off Light
  device type. A future adapter must check every cluster and its conformance,
  then apply Home's current authority and effect guards.
  """

  alias WotexHome.Durable.Registry
  alias WotexHome.Semantics.{Capability, Thing}

  @required_server_clusters [0x0003, 0x0004, 0x0006, 0x0062]

  @spec proposal(Thing.t()) :: {:ok, map()} | {:error, atom()}
  def proposal(%Thing{} = thing) do
    with {:ok, _document} <- Registry.encode_thing(thing),
         true <- thing.role == "Light",
         {:ok, %Capability{} = power} <- Thing.capability(thing, "power"),
         true <- power.value_kind == "boolean" and power.unit == "none" and
                   power.risk_class == "ordinary" and
                   Enum.sort(power.operations) == ["read", "write"] and
                   power.constraints == %{} and power.extensions == %{} do
      {:ok,
       %{
         scope: :shape_only,
         thing_id: thing.id,
         home_capability: "power",
         omitted_home_capabilities:
           thing.capabilities |> Map.keys() |> Enum.reject(&(&1 == "power")) |> Enum.sort(),
         matter_data_model: "1.5.1",
         device_type_id: 0x0100,
         device_type_revision: 3,
         on_off_cluster_id: 0x0006,
         required_server_clusters: @required_server_clusters,
         required_on_off_features: ["LT"]
       }}
    else
      _ -> {:error, :unsupported_export_shape}
    end
  end

  def proposal(_thing), do: {:error, :unsupported_export_shape}
end
