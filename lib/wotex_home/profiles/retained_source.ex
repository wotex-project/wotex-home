defmodule WotexHome.Profiles.RetainedSource do
  @moduledoc "Private exact source byte witnesses; historical decoding needs no producer."
  alias WotexHome.{Id, Profiles.EnvelopeCodec}
  alias WotexHome.Profiles.{AuthoringWire, DocumentChunks, ExternalSourceSelection, RetainedJSON}
  @format "wotex-home.retained-source@1"
  @maximum 9_223_372_036_854_775_807
  @limits %{
    "max_bytes" => 262_144,
    "max_depth" => 8,
    "max_nodes" => 4096,
    "max_channels" => 32,
    "max_definitions" => 32,
    "max_bindings" => 32,
    "max_dependencies" => 32,
    "max_numeric_digits" => 64
  }

  @doc "Retains checked live inputs with independent exact reader and policy byte witnesses."
  def encode(selection, owner_epoch) do
    with {:ok, _} <- ExternalSourceSelection.to_map(selection),
         true <- epoch?(owner_epoch),
         i = selection.inputs,
         {:ok, inputs} <-
           document(%{
             "source" => i["source"],
             "reader" => i["reader"].inputs,
             "channels" => i["channels"]
           }),
         {:ok, reader} <- document(i["reader"].inputs),
         {:ok, policy} <- document(i["channels"]),
         {:ok, input_chunks} <- DocumentChunks.encode(inputs, 262_144),
         {:ok, reader_chunks} <- DocumentChunks.encode(reader, 262_144),
         {:ok, policy_chunks} <- DocumentChunks.encode(policy, 262_144),
         bytes =
           JSON.encode!([
             @format,
             owner_epoch,
             selection.sha256,
             input_chunks,
             reader_chunks,
             policy_chunks
           ]),
         {:ok, _} <- decode(bytes),
         do: {:ok, bytes},
         else: (
           false -> invalid()
           error -> error
         )
  end

  @doc "Checks original hashes, closed host fields and bounded opaque producer containers."
  def decode(bytes) do
    with {:ok, [@format, epoch, digest, ic, rc, pc]} <- AuthoringWire.decode(bytes, 600_000),
         true <- epoch?(epoch) and EnvelopeCodec.digest?(digest),
         {:ok, inputs_doc} <- DocumentChunks.decode(ic, 262_144),
         {:ok, reader_doc} <- DocumentChunks.decode(rc, 262_144),
         {:ok, policy_doc} <- DocumentChunks.decode(pc, 262_144),
         {:ok, inputs} <- RetainedJSON.decode(inputs_doc),
         {:ok, reader} <- RetainedJSON.decode(reader_doc),
         {:ok, channels} <- RetainedJSON.decode(policy_doc),
         true <- EnvelopeCodec.keys?(inputs, ~w(channels reader source)),
         true <- inputs["reader"] == reader and inputs["channels"] == channels,
         true <- source?(inputs["source"]) and reader?(reader) and channels?(channels, reader),
         true <- sha("wotex-home.external-source-selection@1\n" <> inputs_doc) == digest,
         true <- JSON.encode!([@format, epoch, digest, ic, rc, pc]) == bytes,
         do:
           {:ok,
            %{
              owner_epoch: epoch,
              sha256: digest,
              inputs: inputs,
              reader_basis_sha256: sha("wotex-home.external-reader@1\n" <> reader_doc),
              policy_sha256: sha("wotex-home.external-source-policy@1\n" <> policy_doc)
            }},
         else: (
           {:error, code} when code in [:external_profile_limit, :authoring_limit] ->
             {:error, :external_profile_limit}

           _ ->
             invalid()
         )
  end

  defp source?(s),
    do:
      EnvelopeCodec.keys?(s, ~w(method source_epoch source_generation source_ref stable_id trust)) and
        Id.valid?(s["source_ref"]) and Id.valid?(s["stable_id"]) and epoch?(s["source_epoch"]) and
        int?(s["source_generation"], 1) and
        s["method"] in ~w(operator_configured legacy_tofu physical_button qr_install_code) and
        s["trust"] in ~w(unauthenticated_local authenticated_device bridge_attested synthetic_lab)

  defp reader?(r) do
    EnvelopeCodec.keys?(r, ~w(capture installed reader_limits)) and
      EnvelopeCodec.keys?(r["reader_limits"], Enum.sort(Map.keys(@limits))) and
      Enum.all?(@limits, fn {key, maximum} ->
        is_integer(r["reader_limits"][key]) and r["reader_limits"][key] in 1..maximum
      end) and
      EnvelopeCodec.keys?(r["capture"], ~w(binding capture_epoch digest fields)) and
      EnvelopeCodec.reference?(r["capture"]["binding"]) and epoch?(r["capture"]["capture_epoch"]) and
      EnvelopeCodec.digest?(r["capture"]["digest"]) and is_map(r["capture"]["fields"]) and
      installed?(r["installed"], r["capture"]["binding"])
  end

  defp installed?(i, binding) do
    EnvelopeCodec.keys?(i, ~w(bindings contracts home_contracts producer)) and
      is_list(i["bindings"]) and length(i["bindings"]) in 1..32 and
      Enum.all?(
        i["bindings"],
        &(is_map(&1) and EnvelopeCodec.reference?(Map.take(&1, ~w(id version sha256))))
      ) and
      Enum.any?(i["bindings"], &(Map.take(&1, ~w(id version sha256)) == binding)) and
      is_list(i["contracts"]) and length(i["contracts"]) <= 32 and
      EnvelopeCodec.references?(i["contracts"]) and
      is_list(i["home_contracts"]) and length(i["home_contracts"]) <= 32 and
      EnvelopeCodec.references?(i["home_contracts"]) and
      EnvelopeCodec.keys?(
        i["producer"],
        ~w(core_archive_sha256 profiles_archive_sha256 runtime_archive_sha256)
      ) and
      Enum.all?(i["producer"], fn {_, d} -> EnvelopeCodec.digest?(d) end)
  end

  defp channels?(channels, reader) when is_list(channels) and length(channels) in 1..32 do
    ids = Enum.map(channels, &if(is_map(&1), do: &1["channel_id"]))

    keys =
      Enum.map(
        channels,
        &if(is_map(&1) and is_map(&1["policy"]), do: &1["policy"]["capability_key"])
      )

    ids == Enum.sort(Enum.uniq(ids)) and length(Enum.uniq(keys)) == length(keys) and
      Enum.all?(channels, fn c ->
        EnvelopeCodec.keys?(c, ~w(channel_id consumer policy)) and Id.valid?(c["channel_id"]) and
          consumer?(c["consumer"]) and
          c["consumer"]["reference"] in reader["installed"]["home_contracts"] and
          EnvelopeCodec.keys?(
            c["policy"],
            ~w(capability_key evidence_ref freshness_ms risk_class)
          ) and
          Id.valid?(c["policy"]["capability_key"]) and Id.valid?(c["policy"]["evidence_ref"]) and
          c["policy"]["risk_class"] in ~w(ordinary sensitive) and
          is_integer(c["policy"]["freshness_ms"]) and c["policy"]["freshness_ms"] in 1..86_400_000
      end)
  end

  defp channels?(_, _), do: false

  defp consumer?(c),
    do:
      EnvelopeCodec.keys?(c, ~w(constraints reference semantic_ref unit value_kind)) and
        EnvelopeCodec.reference?(c["reference"]) and EnvelopeCodec.reference?(c["semantic_ref"]) and
        ((c["value_kind"] == "integer" and is_map(c["unit"]) and
            EnvelopeCodec.keys?(c["constraints"], ~w(max min)) and
            is_integer(c["constraints"]["min"]) and is_integer(c["constraints"]["max"]) and
            c["constraints"]["min"] >= -@maximum - 1 and c["constraints"]["max"] <= @maximum and
            c["constraints"]["min"] <= c["constraints"]["max"]) or
           (c["value_kind"] == "boolean" and c["unit"] == nil and c["constraints"] == nil) or
           (c["value_kind"] == "external" and (is_nil(c["unit"]) or is_map(c["unit"])) and
              c["constraints"] == nil))

  defp document(value) do
    case apply(Wotex.JSON, :encode, [
           value,
           [
             max_bytes: 262_144,
             max_depth: 8,
             max_nodes: 4096,
             max_collection_size: 256,
             max_string_bytes: 4096
           ]
         ]) do
      {:ok, bytes} -> {:ok, bytes}
      _ -> {:error, :external_profile_limit}
    end
  rescue
    error in UndefinedFunctionError ->
      if error.module == Wotex.JSON and error.function == :encode and error.arity == 2,
        do: {:error, :profiles_producer_unavailable},
        else: invalid()
  end

  defp int?(value, minimum), do: is_integer(value) and value in minimum..@maximum

  defp epoch?(value),
    do: is_binary(value) and byte_size(value) == 32 and Regex.match?(~r/\A[0-9a-f]{32}\z/, value)

  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  defp invalid, do: {:error, :invalid_retained_source}
end
