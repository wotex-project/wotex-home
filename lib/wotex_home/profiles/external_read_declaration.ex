defmodule WotexHome.Profiles.ExternalReadDeclaration do
  @moduledoc """
  Derives an inert read declaration from an exact channel and Home consumer policy.

  `new/5` joins the checked envelope, included supported channel, explicit
  consumer contract, household target policy and reader limits. It checks the
  channel's read operation and semantic/unit/schema correspondence, returning
  read-only capability metadata with the exact declaration digest.
  `to_map/5` rebuilds the original and compares the supplied current basis.

  No report is observed by this constructor. The declaration establishes no
  current enrollment, trust, grant, freshness or physical qualification; existing
  executable capabilities remain separate. `WotexHome.Durable.Store` must check
  the selected target and current source before accepting reported values.
  """

  alias WotexHome.Id
  alias WotexHome.Profiles.{EnvelopeCodec, ExternalEnvelope, ExternalValue}
  @enforce_keys [:inputs, :data, :sha256]
  defstruct @enforce_keys
  @type t :: %__MODULE__{inputs: map(), data: map(), sha256: String.t()}

  @doc "Derives one read-only declaration without observing a report or accepting a target."
  @spec new(term(), term(), term(), term(), term()) :: {:ok, t()} | {:error, atom()}
  def new(envelope, contract, policy, channel, limits) do
    with :ok <- policy(policy, channel),
         {:ok, summary} <- ExternalEnvelope.to_map(envelope, limits),
         {:ok, consumer_sha} <- ExternalValue.consumer_identity(contract, limits),
         true <-
           Enum.any?(
             summary["home_contracts"],
             &(&1["channel_id"] == channel and &1["contract_ref"] == contract["reference"])
           ),
         {:ok, projection} <-
           producer(Wotex.Profiles.Projection, :to_map, [envelope.projection, limits]),
         plan when is_map(plan) <-
           Enum.find(projection["channel_plans"], &(&1["channel_id"] == channel)),
         true <-
           plan["disposition"] == "supported" and plan["semantic"] == contract["semantic_ref"],
         true <-
           Enum.any?(plan["operations"], &(&1 in ~w(readproperty observeproperty subscribeevent))),
         :ok <- correspondence(contract, plan["definition"], limits),
         unit =
           if(contract["value_kind"] == "external",
             do: plan["definition"]["unit"],
             else: contract["unit"]
           ),
         data =
           Map.merge(policy, %{
             "format" => "wotex-home.external-read-declaration@1",
             "channel_id" => channel,
             "operations" => ["read"],
             "semantic_ref" => contract["semantic_ref"],
             "contract_ref" => contract["reference"],
             "contract_sha256" => consumer_sha,
             "value_kind" => contract["value_kind"],
             "unit" => unit,
             "constraints" => contract["constraints"],
             "value_schema" => plan["definition"]["value_schema"]
           })
           |> Map.merge(
             Map.take(summary, ~w(envelope_sha256 projection_sha256 consumption_sha256 producer))
           ),
         {:ok, bytes} <-
           producer(Wotex.JSON, :encode, [
             data,
             [
               max_bytes: min(65536, limits["max_bytes"]),
               max_depth: 8,
               max_nodes: 4096,
               max_collection_size: 256,
               max_string_bytes: 4096
             ]
           ]) do
      {:ok,
       %__MODULE__{
         inputs: %{
           "envelope" => envelope,
           "contract" => contract,
           "policy" => policy,
           "channel_id" => channel,
           "reader_limits" => limits
         },
         data: data,
         sha256:
           Base.encode16(
             :crypto.hash(:sha256, "wotex-home.external-read-declaration@1\n" <> bytes),
             case: :lower
           )
       }}
    else
      false -> unsupported()
      nil -> unsupported()
      error -> error
    end
  end

  @doc "Reconstructs every original field and checks the explicit current declaration basis."
  @spec to_map(term(), term(), term(), term(), term()) :: {:ok, map()} | {:error, atom()}
  def to_map(%__MODULE__{} = value, envelope, contract, policy, limits)
      when map_size(value) == 4 do
    with true <-
           EnvelopeCodec.keys?(
             value.inputs,
             ~w(channel_id contract envelope policy reader_limits)
           ),
         {:ok, rebuilt} <- rebuild(value.inputs),
         true <- rebuilt == value,
         {:ok, current} <- new(envelope, contract, policy, value.inputs["channel_id"], limits),
         :ok <- current_identity(current.sha256, value.sha256) do
      {:ok, %{"data" => rebuilt.data, "sha256" => rebuilt.sha256}}
    else
      false -> invalid()
      {:error, :unsupported_external_declaration} -> {:error, :stale_external_basis}
      error -> error
    end
  end

  def to_map(_, _, _, _, _), do: invalid()

  defp current_identity(same, same), do: :ok
  defp current_identity(_, _), do: {:error, :stale_external_basis}

  defp rebuild(i) do
    case new(i["envelope"], i["contract"], i["policy"], i["channel_id"], i["reader_limits"]) do
      {:ok, _} = result -> result
      {:error, :profiles_producer_unavailable} = error -> error
      _ -> invalid()
    end
  end

  defp policy(p, channel) do
    if EnvelopeCodec.keys?(p, ~w(capability_key evidence_ref freshness_ms risk_class thing_id)) and
         Enum.all?([channel, p["thing_id"], p["capability_key"], p["evidence_ref"]], &Id.valid?/1) and
         p["risk_class"] in ~w(ordinary sensitive) and is_integer(p["freshness_ms"]) and
         p["freshness_ms"] in 1..86_400_000, do: :ok, else: invalid()
  end

  defp correspondence(%{"value_kind" => "integer"} = c, d, limits) do
    with true <- is_map(d) and d["value_schema"]["type"] in ~w(integer number),
         {:ok, source} <- producer(Wotex.Profiles.Unit, :to_map, [d["unit"], limits]),
         {:ok, target} <- producer(Wotex.Profiles.Unit, :to_map, [c["unit"], limits]),
         true <-
           Map.take(source, ~w(quantity_kind dimension)) ==
             Map.take(target, ~w(quantity_kind dimension)),
         do: :ok,
         else: (
           false -> unsupported()
           error -> error
         )
  end

  defp correspondence(%{"value_kind" => "boolean"}, d, _) do
    if is_map(d) and d["value_schema"]["type"] == "boolean" and d["unit"] == nil,
      do: :ok,
      else: unsupported()
  end

  defp correspondence(%{"value_kind" => "external"}, d, _) when is_map(d), do: :ok
  defp correspondence(_, _, _), do: unsupported()

  defp producer(module, function, args) do
    case apply(module, function, args) do
      {:ok, _} = result ->
        result

      {:error, %{code: code}}
      when code in [
             :input_limit,
             :numeric_limit,
             :output_limit,
             :byte_limit_exceeded,
             :depth_limit_exceeded,
             :node_limit_exceeded,
             :collection_limit_exceeded,
             :string_limit_exceeded
           ] ->
        {:error, :external_profile_limit}

      _ ->
        unsupported()
    end
  rescue
    error in UndefinedFunctionError ->
      if error.module == module and error.function == function and error.arity == length(args),
        do: {:error, :profiles_producer_unavailable},
        else: unsupported()
  end

  defp invalid, do: {:error, :invalid_external_declaration}
  defp unsupported, do: {:error, :unsupported_external_declaration}
end
