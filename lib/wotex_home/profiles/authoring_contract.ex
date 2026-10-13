defmodule WotexHome.Profiles.AuthoringContract do
  @moduledoc "Pure installed producer grammar export with an explicit Home artifact and consumption basis."

  alias WotexHome.Profiles.{AuthoringProducer, EnvelopeCodec}

  @reader %{
    "max_bytes" => 262_144,
    "max_depth" => 8,
    "max_nodes" => 4096,
    "max_channels" => 32,
    "max_definitions" => 32,
    "max_bindings" => 32,
    "max_dependencies" => 32,
    "max_numeric_digits" => 64
  }
  @authoring %{
    "max_bundle_bytes" => 262_144,
    "max_diagnostics" => 64,
    "max_report_bytes" => 24_576,
    "max_check_steps" => 1_000_000
  }
  @enforce_keys [:bytes, :contract, :contract_sha256, :basis_sha256, :inputs]
  defstruct @enforce_keys

  def export(installed, limits) do
    with :ok <- installed(installed),
         :ok <- limits(limits),
         {:ok, artifacts} <- artifacts(),
         {:ok, contract} <-
           producer(Wotex.Profiles.Contract, :export, [
             installed["bindings"],
             installed["contracts"],
             limits,
             artifacts
           ]),
         {:ok, bytes} <- producer(Wotex.Profiles.Contract, :encode, [contract]),
         true <- is_binary(bytes),
         :ok <- byte_limit(bytes),
         {:ok, digest} <- producer(Wotex.Profiles.Contract, :identity, [contract]),
         true <- EnvelopeCodec.digest?(digest),
         {:ok, basis} <- basis(bytes, digest, installed, limits) do
      {:ok,
       %__MODULE__{
         bytes: bytes,
         contract: contract,
         contract_sha256: digest,
         basis_sha256: basis,
         inputs: %{"installed" => installed, "limits" => limits}
       }}
    else
      false -> {:error, :invalid_authoring_contract}
      error -> error
    end
  end

  def to_map(%__MODULE__{} = value) when map_size(value) == 6 do
    with true <- EnvelopeCodec.keys?(value.inputs, ~w(installed limits)),
         {:ok, rebuilt} <- export(value.inputs["installed"], value.inputs["limits"]),
         true <- rebuilt == value do
      {:ok,
       summary(
         rebuilt.bytes,
         rebuilt.contract_sha256,
         rebuilt.inputs["installed"],
         rebuilt.inputs["limits"]
       )
       |> Map.put("basis_sha256", rebuilt.basis_sha256)}
    else
      false -> {:error, :invalid_authoring_contract}
      error -> error
    end
  end

  def to_map(_), do: {:error, :invalid_authoring_contract}

  defp artifacts do
    {:ok, apply(Wotex.Profiles.Artifacts, :current, [])}
  rescue
    error in UndefinedFunctionError ->
      if error.module == Wotex.Profiles.Artifacts and error.function == :current and
           error.arity == 0,
         do: {:error, :profiles_producer_unavailable},
         else: {:error, :invalid_authoring_contract}
  end

  defp producer(module, function, args),
    do: AuthoringProducer.call(module, function, args, :invalid_authoring_contract)

  defp installed(data) do
    valid =
      EnvelopeCodec.keys?(data, ~w(bindings contracts home_contracts producer)) and
        EnvelopeCodec.bounded_list?(data["bindings"]) and
        EnvelopeCodec.bounded_list?(data["contracts"]) and
        EnvelopeCodec.references?(data["home_contracts"]) and
        EnvelopeCodec.keys?(
          data["producer"],
          ~w(core_archive_sha256 profiles_archive_sha256 runtime_archive_sha256)
        ) and
        Enum.all?(Map.values(data["producer"]), &EnvelopeCodec.digest?/1)

    if valid, do: :ok, else: {:error, :invalid_authoring_contract}
  end

  defp limits(data) do
    with true <- EnvelopeCodec.keys?(data, Enum.sort(["reader" | Map.keys(@authoring)])),
         :ok <- selected(Map.delete(data, "reader"), @authoring),
         :ok <- selected(data["reader"], @reader),
         do: :ok,
         else: (
           false -> {:error, :invalid_authoring_contract}
           error -> error
         )
  end

  defp selected(data, ceilings) do
    cond do
      not EnvelopeCodec.keys?(data, Enum.sort(Map.keys(ceilings))) ->
        {:error, :invalid_authoring_contract}

      not Enum.all?(ceilings, fn {key, _} -> is_integer(data[key]) and data[key] > 0 end) ->
        {:error, :invalid_authoring_contract}

      not Enum.all?(ceilings, fn {key, ceiling} -> data[key] <= ceiling end) ->
        {:error, :authoring_limit}

      true ->
        :ok
    end
  end

  defp byte_limit(bytes) do
    if byte_size(bytes) in 1..262_144, do: :ok, else: {:error, :authoring_limit}
  end

  defp basis(bytes, digest, installed, limits) do
    with {:ok, encoded} <-
           producer(Wotex.JSON, :encode, [summary(bytes, digest, installed, limits)]),
         do: {:ok, AuthoringProducer.sha("wotex-home.authoring-contract-basis@1\n" <> encoded)}
  end

  defp summary(bytes, digest, installed, limits),
    do: %{
      "format" => "wotex-home.authoring-contract@1",
      "contract_sha256" => digest,
      "contract_raw_sha256" => AuthoringProducer.sha(bytes),
      "producer" => installed["producer"],
      "home_contracts" => installed["home_contracts"],
      "limits" => limits,
      "consumption_policy" => "wotex-home.read-only-profile@1"
    }
end
