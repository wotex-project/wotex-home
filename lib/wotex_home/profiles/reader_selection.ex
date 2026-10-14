defmodule WotexHome.Profiles.ReaderSelection do
  @moduledoc """
  Explicit checked reader registrations, artifact assertions and host capture.

  This pure value establishes supplied correspondence. It does not install a
  producer, authenticate a source or grant inspection/selection authority.
  """
  alias WotexHome.Profiles.EnvelopeCodec

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
  @producer ~w(core_archive_sha256 profiles_archive_sha256 runtime_archive_sha256)
  @enforce_keys [:inputs, :data]
  defstruct @enforce_keys
  @type t :: %__MODULE__{inputs: map(), data: map()}

  @doc "Validates the complete explicitly supplied selection and exports its safe basis."
  @spec new(term(), term(), term()) :: {:ok, t()} | {:error, atom()}
  def new(installed, capture, limits) do
    with :ok <- limits(limits),
         true <- EnvelopeCodec.keys?(installed, ~w(bindings contracts home_contracts producer)),
         :ok <- bounded(installed["bindings"], limits["max_bindings"]),
         true <- installed["bindings"] != [],
         :ok <- bounded(installed["contracts"], 32),
         :ok <- bounded(installed["home_contracts"], 32),
         true <-
           EnvelopeCodec.references?(installed["contracts"]) and
             EnvelopeCodec.references?(installed["home_contracts"]),
         true <-
           EnvelopeCodec.keys?(installed["producer"], @producer) and
             Enum.all?(@producer, &EnvelopeCodec.digest?(installed["producer"][&1])),
         true <- EnvelopeCodec.keys?(capture, ~w(binding capture_epoch digest fields)),
         inputs = %{"installed" => installed, "capture" => capture, "reader_limits" => limits},
         {:ok, bytes} <-
           call(Wotex.JSON, :encode, [
             inputs,
             [
               max_bytes: limits["max_bytes"],
               max_depth: limits["max_depth"],
               max_nodes: limits["max_nodes"],
               max_collection_size: 32,
               max_string_bytes: 4096
             ]
           ]),
         {:ok, bindings} <- bindings(installed["bindings"], limits),
         refs = Enum.map(bindings, &Map.take(&1, ~w(id version sha256))),
         true <- EnvelopeCodec.references?(refs),
         selected when is_map(selected) <-
           Enum.find(bindings, &(Map.take(&1, ~w(id version sha256)) == capture["binding"])),
         {:ok, ^capture} <- call(Wotex.Profiles.Capture, :to_map, [capture, selected, limits]) do
      data = %{
        "format" => "wotex-home.external-reader@1",
        "basis_sha256" => sha("wotex-home.external-reader@1\n" <> bytes),
        "producer" => installed["producer"],
        "reader_limits" => limits,
        "home_contracts" => installed["home_contracts"],
        "bindings" => refs,
        "contracts" => installed["contracts"],
        "capture_digest" => capture["digest"],
        "capture_epoch" => capture["capture_epoch"]
      }

      {:ok, %__MODULE__{inputs: inputs, data: data}}
    else
      false -> invalid()
      {:error, _} = error -> error
      _ -> invalid()
    end
  end

  @doc "Rebuilds the complete native original before returning its payload-free selection summary."
  @spec to_map(term()) :: {:ok, map()} | {:error, atom()}
  def to_map(%__MODULE__{} = value) when map_size(value) == 3 do
    with true <- EnvelopeCodec.keys?(value.inputs, ~w(capture installed reader_limits)),
         {:ok, rebuilt} <-
           new(value.inputs["installed"], value.inputs["capture"], value.inputs["reader_limits"]),
         true <- rebuilt == value,
         do: {:ok, rebuilt.data},
         else: (
           false -> invalid()
           error -> error
         )
  end

  def to_map(_), do: invalid()

  defp limits(data) do
    with true <- EnvelopeCodec.keys?(data, Enum.sort(Map.keys(@ceilings))),
         true <- Enum.all?(@ceilings, fn {k, _} -> is_integer(data[k]) and data[k] > 0 end) do
      if Enum.all?(@ceilings, fn {k, max} -> data[k] <= max end),
        do: :ok,
        else: {:error, :external_profile_limit}
    else
      _ -> invalid()
    end
  end

  defp bindings(values, limits) do
    Enum.reduce_while(values, {:ok, []}, fn input, {:ok, checked} ->
      case call(Wotex.Profiles.Binding, :to_map, [input, limits]) do
        {:ok, binding} -> {:cont, {:ok, [binding | checked]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp bounded([], _), do: :ok
  defp bounded([_ | _], 0), do: {:error, :external_profile_limit}
  defp bounded([_ | t], n), do: bounded(t, n - 1)
  defp bounded(_, _), do: invalid()

  defp call(module, function, args) do
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
        invalid()
    end
  rescue
    error in UndefinedFunctionError ->
      if error.module == module and error.function == function and error.arity == length(args),
        do: {:error, :profiles_producer_unavailable},
        else: invalid()
  end

  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  defp invalid, do: {:error, :invalid_external_reader}
end
