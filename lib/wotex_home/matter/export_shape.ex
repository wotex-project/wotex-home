defmodule WotexHome.Matter.ExportShape do
  @moduledoc """
  Advisory Home-to-Matter On/Off Light shape for a future bridge server.

  This checks only a Home declaration. It allocates no endpoint, proves no
  qualification, issues no command and cannot enable an upstream Matter server.
  The required server clusters are from the tagged Matter 1.5.1 On/Off Light
  device type. A future adapter must check every cluster and its conformance,
  then apply Home's current authority and effect guards.

  `proposal/1` derives the possible On/Off Light shape from a declaration.
  `command_proposal/5` and `report_proposal/4` translate only the narrow
  supported values for review. They do not stand up a Matter bridge or make a
  network request.
  """

  alias WotexHome.Durable.Registry
  alias WotexHome.Mutation
  alias WotexHome.Semantics.{Capability, Observation, Thing, Value}

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

  @doc "Build an unadmitted Home mutation for an absolute On/Off command only."
  @spec command_proposal(Thing.t(), non_neg_integer(), String.t(), non_neg_integer(),
          non_neg_integer()) :: {:ok, map()} | {:error, atom()}
  def command_proposal(thing, command_id, operation_id, authority_epoch, expected_revision)
      when command_id in [0x00, 0x01] do
    with {:ok, %{thing_id: target_id}} <- proposal(thing),
         {:ok, mutation} <-
           Mutation.new(%{
             "api_version" => 1,
             "operation_id" => operation_id,
             "authority_epoch" => authority_epoch,
             "expected_revision" => expected_revision,
             "target_id" => target_id,
             "capability_key" => "power",
             "value" => %{"type" => "boolean", "value" => command_id == 0x01}
           }) do
      {:ok, %{scope: :unadmitted, mutation: mutation}}
    else
      _ -> {:error, :unsupported_matter_command}
    end
  end

  def command_proposal(_thing, _command_id, _operation_id, _authority_epoch, _expected_revision),
    do: {:error, :unsupported_matter_command}

  @doc "Project a current Home report to an advisory OnOff value, preserving unknown."
  @spec report_proposal(Thing.t(), Observation.t() | nil, String.t(), non_neg_integer()) ::
          {:ok, map()} | :unknown
  def report_proposal(%Thing{} = thing, %Observation{} = observation, boot_epoch, now_ms) do
    with {:ok, _shape} <- proposal(thing),
         {:ok, power} <- Thing.capability(thing, "power"),
         true <- Observation.valid?(observation, power),
         {:ok, %Value{kind: :boolean, data: value}} <-
           Observation.current_value(observation, power, boot_epoch, now_ms) do
      {:ok, %{scope: :shape_only, on_off: value}}
    else
      _ -> :unknown
    end
  end

  def report_proposal(_thing, _observation, _boot_epoch, _now_ms), do: :unknown
end
