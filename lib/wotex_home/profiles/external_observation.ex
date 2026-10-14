defmodule WotexHome.Profiles.ExternalObservation do
  @moduledoc "Closed native report originals and exact producer-independent retained value documents."
  alias WotexHome.{Id, Profiles.EnvelopeCodec}
  alias WotexHome.Profiles.{AuthoringWire, DocumentChunks, RetainedJSON}
  @format "wotex-home.external-observation.v1"
  @outcome "wotex-home.external-observation-result@1"
  @fields ~w(format report_document value_document value_sha256 target_selection_revision declaration_sha256 source_selection_sha256)
  @receipt ~w(authority_epoch report_owner_epoch report_id revision input_sha256 target_id capability_key selection_revision resource_revision trust_revision policy_generation source_selection_sha256 report_sha256 value_sha256 outcome_sha256 store_boot_epoch received_store_ms)
  @value ~w(affordance capture_digest channel_id closure_sha256 compiler_ref consumption_sha256 continuity contract_ref contract_sha256 format interpretation normalized_value profile_sha256 quality quality_reason receipt_time semantic sequence source_epoch source_ref source_time unit value_kind)
  @report ~w(binding capture_epoch channel_id continuity profile_sha256 quality quality_reason receipt_time sequence source_epoch source_ref source_time value)
  @maximum 9_223_372_036_854_775_807

  def encode(i) do
    if EnvelopeCodec.keys?(i, ~w(report_id report_owner_epoch)) and
         epoch?(i["report_owner_epoch"]) and Id.valid?(i["report_id"]),
       do: {:ok, JSON.encode!([@format, i["report_owner_epoch"], i["report_id"]])},
       else: invalid()
  end

  def decode(bytes) do
    with {:ok, [@format, epoch, id]} <- wire(bytes, 512),
         i = %{"report_owner_epoch" => epoch, "report_id" => id},
         {:ok, ^bytes} <- encode(i),
         do: {:ok, i},
         else: (_ -> invalid())
  end

  def encode_outcome(o) do
    with true <- EnvelopeCodec.keys?(o, Enum.sort(@fields)),
         true <- o["format"] == @outcome and int?(o["target_selection_revision"], 1),
         true <-
           Enum.all?(
             ~w(value_sha256 declaration_sha256 source_selection_sha256),
             &EnvelopeCodec.digest?(o[&1])
           ),
         {:ok, r} <- RetainedJSON.decode(o["report_document"]),
         {:ok, v} <- RetainedJSON.decode(o["value_document"]),
         :ok <- correspondence(r, v),
         true <- value_sha(o["value_document"]) == o["value_sha256"],
         {:ok, rc} <- DocumentChunks.encode(o["report_document"], 65536),
         {:ok, vc} <- DocumentChunks.encode(o["value_document"], 65536),
         do:
           sized(
             JSON.encode!([
               @outcome,
               rc,
               vc,
               o["value_sha256"],
               o["target_selection_revision"],
               o["declaration_sha256"],
               o["source_selection_sha256"]
             ]),
             524_288
           ),
         else: (
           {:error, :external_profile_limit} = e -> e
           _ -> invalid()
         )
  end

  def decode_outcome(bytes) do
    with {:ok, [@outcome, rc, vc, value_sha, selection, declaration, source]} <-
           wire(bytes, 524_288),
         {:ok, r} <- DocumentChunks.decode(rc, 65536),
         {:ok, v} <- DocumentChunks.decode(vc, 65536),
         o = %{
           "format" => @outcome,
           "report_document" => r,
           "value_document" => v,
           "value_sha256" => value_sha,
           "target_selection_revision" => selection,
           "declaration_sha256" => declaration,
           "source_selection_sha256" => source
         },
         {:ok, ^bytes} <- encode_outcome(o),
         do: {:ok, o},
         else: (_ -> invalid())
  end

  def encode_receipt(r) do
    valid =
      EnvelopeCodec.keys?(r, Enum.sort(@receipt)) and epoch?(r["report_owner_epoch"]) and
        Id.valid?(r["report_id"]) and Id.valid?(r["target_id"]) and Id.valid?(r["capability_key"]) and
        Id.valid?(r["store_boot_epoch"]) and
        Enum.all?(
          ~w(authority_epoch revision selection_revision trust_revision policy_generation),
          &int?(r[&1], 1)
        ) and
        Enum.all?(~w(resource_revision received_store_ms), &int?(r[&1], 0)) and
        r["selection_revision"] < r["revision"] and r["trust_revision"] < r["selection_revision"] and
        Enum.all?(
          ~w(input_sha256 source_selection_sha256 report_sha256 value_sha256 outcome_sha256),
          &EnvelopeCodec.digest?(r[&1])
        )

    if valid, do: sized(JSON.encode!(Enum.map(@receipt, &r[&1])), 4096), else: invalid()
  end

  def decode_receipt(bytes) do
    with {:ok, values} <- wire(bytes, 4096),
         true <- is_list(values) and length(values) == 17,
         r = Map.new(Enum.zip(@receipt, values)),
         {:ok, ^bytes} <- encode_receipt(r),
         do: {:ok, r},
         else: (_ -> invalid())
  end

  def value_sha(bytes), do: sha("wotex-home.external-value@1\n" <> bytes)
  def report_sha(bytes), do: sha("wotex-home.external-transport-report@1\n" <> bytes)
  def sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp correspondence(r, v) do
    valid =
      EnvelopeCodec.keys?(r, @report) and EnvelopeCodec.keys?(v, @value) and
        v["format"] == "wotex-home.external-value@1" and Id.valid?(v["channel_id"]) and
        Id.valid?(v["source_ref"]) and epoch?(v["source_epoch"]) and
        EnvelopeCodec.reference?(v["semantic"]) and EnvelopeCodec.reference?(v["compiler_ref"]) and
        EnvelopeCodec.reference?(v["contract_ref"]) and
        Enum.all?(
          ~w(profile_sha256 closure_sha256 capture_digest consumption_sha256 contract_sha256),
          &EnvelopeCodec.digest?(v[&1])
        ) and
        EnvelopeCodec.keys?(v["affordance"], ~w(kind name)) and
        v["affordance"]["kind"] in ~w(property event action) and
        Id.valid?(v["affordance"]["name"]) and
        v["interpretation"] in ~w(profile_declared unconverted) and
        v["value_kind"] in ~w(integer boolean external) and
        v["quality"] in ~w(usable invalid unknown stale) and
        v["continuity"] in ~w(unknown baseline continuous gap retained replayed) and
        is_map(v["normalized_value"]) and
        Enum.all?(
          ~w(channel_id source_ref source_epoch sequence source_time receipt_time continuity profile_sha256),
          &(r[&1] == v[&1])
        ) and
        (r["quality"] == "usable" or
           (v["quality"] == r["quality"] and v["quality_reason"] == r["quality_reason"])) and
        ((v["quality"] == "usable" and v["quality_reason"] == nil and
            v["normalized_value"]["type"] != "null") or
           (v["quality"] != "usable" and v["normalized_value"] == %{"type" => "null"} and
              v["interpretation"] == "unconverted"))

    if valid, do: :ok, else: invalid()
  end

  defp epoch?(v),
    do: is_binary(v) and byte_size(v) == 32 and Regex.match?(~r/\A[0-9a-f]{32}\z/, v)

  defp int?(v, min), do: is_integer(v) and v in min..@maximum

  defp sized(b, max),
    do: if(byte_size(b) <= max, do: {:ok, b}, else: {:error, :external_profile_limit})

  defp wire(b, max) do
    case AuthoringWire.decode(b, max) do
      {:ok, _} = r -> r
      {:error, :authoring_limit} -> {:error, :external_profile_limit}
      _ -> invalid()
    end
  end

  defp invalid, do: {:error, :invalid_external_observation}
end
