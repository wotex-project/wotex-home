defmodule WotexHome.Profiles.ExternalEnvelope do
  @moduledoc """
  Compiles an inert Home envelope with an exact external profile closure.

  `compile/5` receives original envelope bytes, explicit profile/definition
  documents, installed registrations, host capture and reader limits. It checks
  raw document identities, delegates closure compilation and capture matching
  to the installed producer, then derives Home's selected read-only consumption
  basis. Success is `{:ok, envelope}`, retaining raw, projection and consumption
  digests separately; refusal is `{:error, reason}`.

  `to_map/2` reconstructs the complete native value against the same selected
  limits and returns `{:ok, summary}` without source bytes or capture values.
  Changed or invalid correspondence returns `{:error, reason}` instead of
  substituting a later capture or producer. `check_reader_limits/1` returns
  `:ok` for the complete explicit limit set within Home's fixed ceilings, or
  `{:error, :external_profile_limit}` for malformed or excessive limits.

  Compilation performs no custody file read, source authentication or Store
  transition. The checked value grants no current trust, enrollment, observation
  acceptance or command authority; `WotexHome.Durable.Store` owns those current
  use decisions.
  """

  alias WotexHome.Profiles.EnvelopeCodec, as: Codec

  @ceilings %{
    "max_bytes" => 262_144,
    "max_depth" => 8,
    "max_nodes" => 4096,
    "max_channels" => 32,
    "max_definitions" => 32,
    "max_bindings" => 32,
    "max_dependencies" => 32,
    "max_numeric_digits" => 64
  }
  @fields ~w(bytes data raw_sha256 projection projection_sha256 consumption_sha256 documents inputs)a
  @enforce_keys @fields
  defstruct @fields

  @doc "Compiles explicitly supplied bytes/registrations/capture into a read-only inspection value."
  def compile(bytes, documents, installed, capture, reader_limits) do
    with :ok <- envelope_size(bytes),
         {:ok, data} <- Codec.decode(bytes),
         :ok <- check_reader_limits(reader_limits),
         :ok <- documents(documents, data),
         :ok <- installed(installed),
         :ok <- WotexHome.Profiles.ProducerIdentity.check_current(installed["producer"]),
         {:ok, _} <- producer(Wotex.Profiles.Limits, :new, [reader_limits]),
         {:ok, profile} <- document(documents["profile"], :profile, reader_limits),
         {:ok, definitions} <- definitions(documents["definitions"], reader_limits),
         closure = %{
           "definitions" => definitions,
           "bindings" => installed["bindings"],
           "contracts" => installed["contracts"]
         },
         {:ok, references} <-
           producer(Wotex.Profiles.Compiler, :references, [profile, closure, reader_limits]),
         true <- Enum.all?(data["definitions"], &(&1 in references)),
         {:ok, projection} <-
           producer(Wotex.Profiles.Compiler, :compile, [profile, closure, capture, reader_limits]),
         {:ok, projection_data} <-
           producer(Wotex.Profiles.Projection, :to_map, [projection, reader_limits]),
         {:ok, contracts, exclusions} <- consumption(data, installed, projection_data),
         {:ok, projection_sha256} <- identity("wotex-home.external-projection@1", projection_data),
         raw_sha256 = sha(bytes),
         basis = %{
           "envelope_sha256" => raw_sha256,
           "document_identities" => document_identities(documents),
           "projection_sha256" => projection_sha256,
           "producer" => installed["producer"],
           "home_contracts" => contracts,
           "exclusions" => exclusions
         },
         {:ok, consumption_sha256} <- identity("wotex-home.external-consumption@1", basis) do
      {:ok,
       %__MODULE__{
         bytes: bytes,
         data: data,
         raw_sha256: raw_sha256,
         projection: projection,
         projection_sha256: projection_sha256,
         consumption_sha256: consumption_sha256,
         documents: documents,
         inputs: %{
           "installed" => installed,
           "capture" => capture,
           "reader_limits" => reader_limits
         }
       }}
    else
      false -> {:error, :invalid_external_closure}
      error -> normalize(error)
    end
  end

  @doc "Regenerates the exact native basis and returns a summary without source bytes or capture values."
  def to_map(%__MODULE__{} = value, reader_limits) when map_size(value) == 9 do
    with true <- Codec.keys?(value.inputs, ~w(capture installed reader_limits)),
         true <- value.inputs["reader_limits"] == reader_limits,
         {:ok, rebuilt} <-
           compile(
             value.bytes,
             value.documents,
             value.inputs["installed"],
             value.inputs["capture"],
             reader_limits
           ),
         true <- rebuilt == value,
         {:ok, projection} <-
           producer(Wotex.Profiles.Projection, :to_map, [rebuilt.projection, reader_limits]),
         {:ok, contracts, exclusions} <-
           consumption(rebuilt.data, rebuilt.inputs["installed"], projection) do
      {:ok,
       %{
         "format" => "wotex-home.external-profile-inspection@1",
         "envelope_sha256" => rebuilt.raw_sha256,
         "document_identities" => document_identities(rebuilt.documents),
         "projection_sha256" => rebuilt.projection_sha256,
         "consumption_sha256" => rebuilt.consumption_sha256,
         "home_contracts" => contracts,
         "exclusions" => exclusions,
         "producer" => rebuilt.inputs["installed"]["producer"]
       }}
    else
      false -> {:error, :stale_external_basis}
      error -> normalize(error)
    end
  end

  def to_map(_, _), do: {:error, :invalid_external_closure}

  defp envelope_size(bytes) when is_binary(bytes) and byte_size(bytes) > 65_536,
    do: {:error, :external_profile_limit}

  defp envelope_size(_), do: :ok

  @doc "Checks the complete explicit reader limits against Home's existing ceilings."
  @spec check_reader_limits(term()) :: :ok | {:error, :external_profile_limit}
  def check_reader_limits(data) do
    valid =
      Codec.keys?(data, Enum.sort(Map.keys(@ceilings))) and
        Enum.all?(@ceilings, fn {key, maximum} ->
          is_integer(data[key]) and data[key] in 1..maximum
        end)

    if valid, do: :ok, else: {:error, :external_profile_limit}
  end

  defp documents(data, envelope) do
    with true <- Codec.keys?(data, ~w(definitions profile)),
         true <- Codec.bounded_list?(data["definitions"]),
         records = [data["profile"] | data["definitions"]],
         true <- Enum.all?(records, &document_record?/1),
         :ok <- document_sizes(records),
         true <- data["profile"]["reference"] == envelope["profile"],
         true <- Enum.map(data["definitions"], & &1["reference"]) == envelope["definitions"] do
      :ok
    else
      {:error, :external_profile_limit} = error -> error
      _ -> {:error, :invalid_external_closure}
    end
  end

  defp document_record?(data) do
    Codec.keys?(data, ~w(bytes raw_sha256 reference)) and Codec.reference?(data["reference"]) and
      Codec.digest?(data["raw_sha256"]) and is_binary(data["bytes"]) and
      byte_size(data["bytes"]) > 0
  end

  defp document_sizes(records) do
    if Enum.all?(records, &(byte_size(&1["bytes"]) <= 65_536)) and
         Enum.reduce(records, 0, &(byte_size(&1["bytes"]) + &2)) <= 262_144,
       do: :ok,
       else: {:error, :external_profile_limit}
  end

  defp installed(data) do
    valid =
      Codec.keys?(data, ~w(bindings contracts home_contracts producer)) and
        Codec.bounded_list?(data["bindings"]) and
        Codec.bounded_list?(data["contracts"]) and
        Codec.references?(data["home_contracts"]) and
        WotexHome.Profiles.ProducerIdentity.valid?(data["producer"])

    if valid, do: :ok, else: {:error, :invalid_external_closure}
  end

  defp document(record, kind, limits) do
    module = if kind == :profile, do: Wotex.Profiles.Profile, else: Wotex.Profiles.Definition

    with true <- sha(record["bytes"]) == record["raw_sha256"],
         {:ok, value} <- producer(module, :parse, [record["bytes"], limits]),
         {:ok, reference} <- producer(module, :reference, [value, limits]),
         true <- reference == record["reference"] do
      {:ok, value}
    else
      false -> {:error, :stale_external_basis}
      error -> error
    end
  end

  defp definitions(records, limits) do
    Enum.reduce_while(records, {:ok, []}, fn record, {:ok, values} ->
      case document(record, :definition, limits) do
        {:ok, value} -> {:cont, {:ok, [value | values]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp consumption(data, installed, projection) do
    plans = projection["channel_plans"]
    supplied = data["home_contracts"]

    known =
      Enum.all?(supplied, fn entry ->
        Enum.any?(plans, &(&1["channel_id"] == entry["channel_id"])) and
          entry["contract_ref"] in installed["home_contracts"]
      end)

    if known do
      consume(plans, Map.new(supplied, &{&1["channel_id"], &1}), [], [])
    else
      {:error, :unsupported_external_profile}
    end
  end

  defp consume([], _, [], _), do: {:error, :unsupported_external_profile}

  defp consume([], _, included, excluded),
    do: {:ok, Enum.reverse(included), Enum.reverse(excluded)}

  defp consume([plan | rest], table, included, excluded) do
    reason = exclusion(plan, table[plan["channel_id"]])

    cond do
      reason == nil ->
        consume(rest, table, [table[plan["channel_id"]] | included], excluded)

      plan["required"] ->
        {:error, :unsupported_external_profile}

      true ->
        consume(rest, table, included, [
          %{"channel_id" => plan["channel_id"], "reason" => reason} | excluded
        ])
    end
  end

  defp exclusion(%{"disposition" => disposition}, _) when disposition != "supported",
    do: "producer_unsupported"

  defp exclusion(plan, contract) do
    kind = plan["affordance"]["kind"]

    operations =
      if kind == "property", do: ~w(readproperty observeproperty), else: ~w(subscribeevent)

    cond do
      kind not in ~w(property event) or not Enum.all?(plan["operations"], &(&1 in operations)) ->
        "operation_unsupported"

      contract == nil ->
        "consumption_unavailable"

      true ->
        nil
    end
  end

  defp document_identities(data) do
    Enum.map([data["profile"] | data["definitions"]], &Map.take(&1, ~w(raw_sha256 reference)))
  end

  defp identity(prefix, data) do
    case producer(Wotex.JSON, :encode, [data]) do
      {:ok, bytes} -> {:ok, sha(prefix <> "\n" <> bytes)}
      error -> error
    end
  end

  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp producer(module, function, arguments) do
    apply(module, function, arguments)
  rescue
    error in UndefinedFunctionError ->
      if error.module == module and error.function == function and
           error.arity == length(arguments),
         do: {:error, :profiles_producer_unavailable},
         else: {:error, :invalid_external_closure}
  end

  defp normalize({:error, code})
       when code in [
              :invalid_external_envelope,
              :invalid_external_closure,
              :external_profile_limit,
              :unsupported_external_profile,
              :stale_external_basis,
              :profiles_producer_unavailable,
              :stale_profile_runtime,
              :profile_runtime_source_unavailable,
              :runtime_artifact_unavailable
            ],
       do: {:error, code}

  defp normalize({:error, %{code: code}}) do
    mapped =
      case code do
        value when value in [:input_limit, :numeric_limit] ->
          :external_profile_limit

        value when value in [:stale_basis, :reference_conflict] ->
          :stale_external_basis

        value
        when value in [
               :missing_reference,
               :unsupported_semantics,
               :unsupported_binding,
               :cyclic_reference,
               :unsupported_schema
             ] ->
          :unsupported_external_profile

        _ ->
          :invalid_external_closure
      end

    {:error, mapped}
  end

  defp normalize(_), do: {:error, :invalid_external_closure}
end
