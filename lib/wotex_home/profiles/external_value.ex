defmodule WotexHome.Profiles.ExternalValue do
  @moduledoc """
  Exact read-only consumption of a decoded report under an explicit Home contract.

  Values retain quality and source/receipt provenance. Construction establishes
  supplied correspondence, never source authenticity, freshness or authority.
  """

  alias WotexHome.Profiles.{EnvelopeCodec, ExternalEnvelope}

  @minimum -9_223_372_036_854_775_808
  @maximum 9_223_372_036_854_775_807
  @enforce_keys [:inputs, :data, :sha256]
  defstruct @enforce_keys
  @type t :: %__MODULE__{inputs: map(), data: map(), sha256: String.t()}

  @doc "Reinterprets one report and consumes it under the supplied exact selected contract."
  @spec project(term(), term(), term(), term()) :: {:ok, t()} | {:error, atom()}
  def project(envelope, report, contract, limits) do
    with {:ok, summary} <- ExternalEnvelope.to_map(envelope, limits),
         :ok <- native_report(report),
         {:ok, _} <- bounded_json(report, min(65536, limits["max_bytes"]), 4096, 256, 4096),
         {:ok, contract_digest} <- consumer_identity(contract, limits),
         :ok <- included(summary, report, contract),
         {:ok, proposal} <-
           producer(Wotex.Profiles.Interpreter, :project, [envelope.projection, report, limits]),
         {:ok, proposal} <- producer(Wotex.Profiles.Proposal, :to_map, [proposal, limits]),
         :ok <- semantic(proposal, contract),
         :ok <- unit_basis(proposal, contract, limits),
         {:ok, unit, value} <- consume(proposal, contract, limits),
         data =
           Map.merge(proposal, %{
             "format" => "wotex-home.external-value@1",
             "consumption_sha256" => summary["consumption_sha256"],
             "contract_sha256" => contract_digest,
             "contract_ref" => contract["reference"],
             "value_kind" => contract["value_kind"],
             "unit" => unit,
             "normalized_value" => value
           }),
         {:ok, bytes} <- bounded_json(data, min(65536, limits["max_bytes"]), 4096, 256, 4096) do
      {:ok,
       %__MODULE__{
         inputs: %{
           "envelope" => envelope,
           "report" => report,
           "contract" => contract,
           "reader_limits" => limits
         },
         data: data,
         sha256: sha("wotex-home.external-value@1\n" <> bytes)
       }}
    end
  end

  @doc "Recomputes the native original and compares the explicit current consumer/envelope basis."
  @spec to_map(term(), term(), term(), term()) :: {:ok, map()} | {:error, atom()}
  def to_map(%__MODULE__{} = value, envelope, contract, limits) when map_size(value) == 4 do
    with true <- EnvelopeCodec.keys?(value.inputs, ~w(contract envelope reader_limits report)),
         {:ok, rebuilt} <-
           rebuild(
             value.inputs["envelope"],
             value.inputs["report"],
             value.inputs["contract"],
             value.inputs["reader_limits"]
           ),
         true <- rebuilt == value,
         {:ok, current} <- ExternalEnvelope.to_map(envelope, limits),
         {:ok, current_contract} <- consumer_identity(contract, limits),
         :ok <- current_basis(value, current, current_contract, limits) do
      {:ok, %{"data" => rebuilt.data, "sha256" => rebuilt.sha256}}
    else
      false -> invalid()
      error -> error
    end
  end

  def to_map(_, _, _, _), do: invalid()

  defp rebuild(envelope, report, contract, limits) do
    case project(envelope, report, contract, limits) do
      {:ok, _} = result -> result
      {:error, :profiles_producer_unavailable} = error -> error
      _ -> invalid()
    end
  end

  @doc "Checks the explicit consumer record and returns its complete content identity."
  @spec consumer_identity(term(), term()) :: {:ok, String.t()} | {:error, atom()}
  def consumer_identity(contract, limits) do
    with :ok <- ExternalEnvelope.check_reader_limits(limits),
         true <-
           EnvelopeCodec.keys?(contract, ~w(constraints reference semantic_ref unit value_kind)),
         true <-
           EnvelopeCodec.reference?(contract["reference"]) and
             EnvelopeCodec.reference?(contract["semantic_ref"]),
         true <- contract_shape?(contract),
         {:ok, bytes} <- bounded_json(contract, 8192, 512, 32, 256),
         :ok <- contract_unit(contract, limits) do
      {:ok, sha("wotex-home.external-consumer@1\n" <> bytes)}
    else
      false -> invalid()
      error -> error
    end
  end

  defp contract_shape?(%{"value_kind" => "integer", "constraints" => c, "unit" => u}) do
    EnvelopeCodec.keys?(c, ~w(max min)) and is_integer(c["min"]) and is_integer(c["max"]) and
      c["min"] in @minimum..@maximum and c["max"] in @minimum..@maximum and c["min"] <= c["max"] and
      is_map(u) and not is_struct(u)
  end

  defp contract_shape?(%{"value_kind" => k, "constraints" => nil, "unit" => nil})
       when k in ~w(boolean external), do: true

  defp contract_shape?(_), do: false

  defp contract_unit(%{"value_kind" => "integer", "unit" => unit}, limits) do
    with {:ok, _} <- producer(Wotex.Profiles.Unit, :to_map, [unit, limits]), do: :ok
  end

  defp contract_unit(_, _), do: :ok

  defp native_report(report),
    do: if(is_map(report) and not is_struct(report), do: :ok, else: invalid())

  defp included(summary, report, contract) do
    if Enum.any?(
         summary["home_contracts"],
         &(&1["channel_id"] == report["channel_id"] and
             &1["contract_ref"] == contract["reference"])
       ), do: :ok, else: {:error, :unsupported_external_value}
  end

  defp semantic(proposal, contract),
    do:
      if(proposal["semantic"] == contract["semantic_ref"],
        do: :ok,
        else: {:error, :unsupported_external_value}
      )

  defp unit_basis(proposal, %{"value_kind" => "integer"} = contract, limits) do
    with true <- is_map(proposal["unit"]),
         {:ok, source} <- producer(Wotex.Profiles.Unit, :to_map, [proposal["unit"], limits]),
         {:ok, target} <- producer(Wotex.Profiles.Unit, :to_map, [contract["unit"], limits]),
         true <-
           Map.take(source, ~w(quantity_kind dimension)) ==
             Map.take(target, ~w(quantity_kind dimension)) do
      :ok
    else
      false -> {:error, :unsupported_external_value}
      error -> error
    end
  end

  defp unit_basis(proposal, %{"value_kind" => "boolean"}, _),
    do: if(proposal["unit"] == nil, do: :ok, else: {:error, :unsupported_external_value})

  defp unit_basis(_, _, _), do: :ok

  defp consume(%{"quality" => quality} = p, c, _) when quality != "usable" do
    unit = if c["value_kind"] == "integer", do: c["unit"], else: p["unit"]
    {:ok, unit, %{"type" => "null"}}
  end

  defp consume(p, %{"value_kind" => "integer"} = c, limits) do
    with {:ok, value} <-
           producer(Wotex.Profiles.Unit, :convert, [
             p["normalized_value"],
             p["unit"],
             c["unit"],
             limits
           ]),
         :ok <- integer_value(value, c["constraints"]),
         do: {:ok, c["unit"], value}
  end

  defp consume(
         %{"normalized_value" => %{"type" => "boolean"} = v},
         %{"value_kind" => "boolean"},
         _
       ),
       do: {:ok, nil, v}

  defp consume(p, %{"value_kind" => "external"}, _), do: {:ok, p["unit"], p["normalized_value"]}
  defp consume(_, _, _), do: {:error, :unsupported_external_value}

  defp integer_value(%{"type" => "sint", "value" => text}, c) do
    number = String.to_integer(text)
    if number in c["min"]..c["max"], do: :ok, else: {:error, :external_value_out_of_range}
  end

  defp integer_value(%{"type" => "uint"}, _), do: {:error, :external_value_out_of_range}
  defp integer_value(%{"type" => "decimal"}, _), do: {:error, :inexact_external_value}
  defp integer_value(_, _), do: {:error, :unsupported_external_value}

  defp current_basis(value, summary, contract_digest, limits) do
    if value.data["consumption_sha256"] == summary["consumption_sha256"] and
         value.data["contract_sha256"] == contract_digest and
         value.inputs["reader_limits"] == limits, do: :ok, else: {:error, :stale_external_basis}
  end

  defp bounded_json(value, bytes, nodes, collection, string) do
    producer(Wotex.JSON, :encode, [
      value,
      [
        max_bytes: bytes,
        max_depth: 8,
        max_nodes: nodes,
        max_collection_size: collection,
        max_string_bytes: string
      ]
    ])
  end

  defp producer(module, function, arguments) do
    case apply(module, function, arguments) do
      {:ok, value} -> {:ok, value}
      {:error, %{code: code}} -> {:error, error_code(code)}
      _ -> invalid()
    end
  rescue
    error in UndefinedFunctionError ->
      if error.module == module and error.function == function and
           error.arity == length(arguments),
         do: {:error, :profiles_producer_unavailable},
         else: invalid()
  end

  defp error_code(code)
       when code in [
              :input_limit,
              :numeric_limit,
              :output_limit,
              :byte_limit_exceeded,
              :depth_limit_exceeded,
              :node_limit_exceeded,
              :collection_limit_exceeded,
              :string_limit_exceeded
            ],
       do: :external_profile_limit

  defp error_code(code) when code in [:stale_basis, :reference_conflict],
    do: :stale_external_basis

  defp error_code(code)
       when code in [
              :unsupported_semantics,
              :unsupported_binding,
              :unsupported_schema,
              :missing_reference,
              :cyclic_reference
            ],
       do: :unsupported_external_value

  defp error_code(:inexact_conversion), do: :inexact_external_value
  defp error_code(_), do: :invalid_external_value
  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  defp invalid, do: {:error, :invalid_external_value}
end
