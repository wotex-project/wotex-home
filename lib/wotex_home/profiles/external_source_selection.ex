defmodule WotexHome.Profiles.ExternalSourceSelection do
  @moduledoc """
  Checks explicit host source assertions and per-channel Home consumption policy.

  `new/3` joins the source identity/epoch/generation assertions with an exact
  `WotexHome.Profiles.ReaderSelection` and selected channel consumers. It
  rechecks each consumer, retaining private native inputs plus a payload-free
  summary with separate source-selection, reader and policy identities.
  `to_map/1` rebuilds the complete native value before exporting the safe summary.

  Stable identity is hashed in that summary; source assertions remain host
  inputs, not authentication evidence. Constructing a complete basis creates no
  fresh lease, current target selection or physical qualification.
  `WotexHome.Profiles.ExternalSourceOwner` owns transient custody and
  `WotexHome.Durable.Store` owns current use.
  """

  alias WotexHome.Id
  alias WotexHome.Profiles.{EnvelopeCodec, ExternalValue, ReaderSelection}
  @enforce_keys [:inputs, :data, :sha256]
  defstruct @enforce_keys
  @type t :: %__MODULE__{inputs: map(), data: map(), sha256: String.t()}
  @maximum 9_223_372_036_854_775_807

  @doc "Checks explicit private host inputs and produces their payload-free basis."
  @spec new(term(), term(), term()) :: {:ok, t()} | {:error, atom()}
  def new(source, reader, channels) do
    with :ok <- source(source),
         :ok <- channel_shapes(channels),
         {:ok, selection} <- ReaderSelection.to_map(reader),
         encoded_inputs = %{"source" => source, "reader" => reader.inputs, "channels" => channels},
         {:ok, bytes} <- bounded_json(encoded_inputs, selection["reader_limits"]),
         :ok <- consumers(channels, selection),
         {:ok, policy_bytes} <- bounded_json(channels, selection["reader_limits"]) do
      data = %{
        "format" => "wotex-home.external-source-selection@1",
        "source_ref" => source["source_ref"],
        "stable_id_sha256" => sha("wotex-home.external-stable-id@1\n" <> source["stable_id"]),
        "source_epoch" => source["source_epoch"],
        "source_generation" => source["source_generation"],
        "method" => source["method"],
        "trust" => source["trust"],
        "reader_basis_sha256" => selection["basis_sha256"],
        "policy_sha256" => sha("wotex-home.external-source-policy@1\n" <> policy_bytes)
      }

      {:ok,
       %__MODULE__{
         inputs: %{"source" => source, "reader" => reader, "channels" => channels},
         data: data,
         sha256: sha("wotex-home.external-source-selection@1\n" <> bytes)
       }}
    end
  end

  @doc "Rebuilds every native field before exporting the safe host selection summary."
  @spec to_map(term()) :: {:ok, map()} | {:error, atom()}
  def to_map(%__MODULE__{} = value) when map_size(value) == 4 do
    with true <- EnvelopeCodec.keys?(value.inputs, ~w(channels reader source)),
         {:ok, rebuilt} <-
           new(value.inputs["source"], value.inputs["reader"], value.inputs["channels"]),
         true <- rebuilt == value,
         do: {:ok, %{"data" => rebuilt.data, "sha256" => rebuilt.sha256}},
         else: (
           false -> invalid()
           error -> error
         )
  end

  def to_map(_), do: invalid()

  defp source(s) do
    if EnvelopeCodec.keys?(
         s,
         ~w(method source_epoch source_generation source_ref stable_id trust)
       ) and
         Id.valid?(s["source_ref"]) and Id.valid?(s["stable_id"]) and
         is_binary(s["source_epoch"]) and byte_size(s["source_epoch"]) == 32 and
         Regex.match?(~r/\A[0-9a-f]{32}\z/, s["source_epoch"]) and
         is_integer(s["source_generation"]) and s["source_generation"] in 1..@maximum and
         s["method"] in ~w(operator_configured legacy_tofu physical_button qr_install_code) and
         s["trust"] in ~w(unauthenticated_local authenticated_device bridge_attested synthetic_lab),
       do: :ok,
       else: invalid()
  end

  defp channel_shapes(channels) when is_list(channels) and length(channels) in 1..32 do
    valid =
      Enum.all?(channels, fn c ->
        EnvelopeCodec.keys?(c, ~w(channel_id consumer policy)) and Id.valid?(c["channel_id"]) and
          EnvelopeCodec.keys?(
            c["policy"],
            ~w(capability_key evidence_ref freshness_ms risk_class)
          ) and
          Id.valid?(c["policy"]["capability_key"]) and Id.valid?(c["policy"]["evidence_ref"]) and
          c["policy"]["risk_class"] in ~w(ordinary sensitive) and
          is_integer(c["policy"]["freshness_ms"]) and c["policy"]["freshness_ms"] in 1..86_400_000
      end)

    if valid do
      ids = Enum.map(channels, & &1["channel_id"])
      keys = Enum.map(channels, & &1["policy"]["capability_key"])

      if ids == Enum.sort(Enum.uniq(ids)) and length(Enum.uniq(keys)) == length(keys),
        do: :ok,
        else: invalid()
    else
      invalid()
    end
  end

  defp channel_shapes(channels) when is_list(channels) and length(channels) > 32,
    do: {:error, :external_profile_limit}

  defp channel_shapes(_), do: invalid()

  defp consumers(channels, selection) do
    Enum.reduce_while(channels, :ok, fn c, :ok ->
      with {:ok, _} <- ExternalValue.consumer_identity(c["consumer"], selection["reader_limits"]),
           true <- c["consumer"]["reference"] in selection["home_contracts"],
           do: {:cont, :ok},
           else: (
             false -> {:halt, {:error, :unsupported_external_source}}
             error -> {:halt, error}
           )
    end)
  end

  defp bounded_json(value, limits) do
    case apply(Wotex.JSON, :encode, [
           value,
           [
             max_bytes: limits["max_bytes"],
             max_depth: limits["max_depth"],
             max_nodes: limits["max_nodes"],
             max_collection_size: 256,
             max_string_bytes: 4096
           ]
         ]) do
      {:ok, _} = result ->
        result

      {:error, %{code: code}}
      when code in [
             :input_limit,
             :numeric_limit,
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
      if error.module == Wotex.JSON and error.function == :encode and error.arity == 2,
        do: {:error, :profiles_producer_unavailable},
        else: invalid()
  end

  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  defp invalid, do: {:error, :invalid_external_source}
end
