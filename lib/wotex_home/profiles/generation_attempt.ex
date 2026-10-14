defmodule WotexHome.Profiles.GenerationAttempt do
  @moduledoc """
  Encodes explicit generator attempts, immutable reservations and settled results.

  `encode/1` binds an attempt to its retained preparation and expected authority
  revision. Initial requests contain no repair feedback; later requests explicitly
  name their predecessor and permit feedback. Historical receipt/result codecs
  reconstruct exact ordered bytes without a provider, installed producer or file.

  `provider_document/3` wraps an already checked private projection and optional
  preceding draft/assessment within the selected total input ceiling. Encoding
  grants no export authority. Store owns actor/source/policy checks, durable
  handoff, clocks, worker identity and final candidate retention.
  """

  alias WotexHome.Id
  alias WotexHome.Profiles.{AuthoringCandidate, AuthoringProducer, AuthoringWire, EnvelopeCodec}

  @maximum 9_223_372_036_854_775_807
  @format "wotex-home.generation-attempt.v1"
  @input ~w(authority_epoch operation_id expected_revision preparation_operation_id preparation_sha256 attempt previous_operation_id repair_export)
  @receipt ~w(authority_epoch operation_id revision input_sha256 preparation_sha256 attempt handoff_sha256 provider_sha256 disposition)
  @result ~w(disposition reason draft_ref bundle_ref assessment)
  @outcomes ~w(candidate unavailable invalid_response unknown deadline_expired cancelled withdrawn capacity)
  @reasons ~w(actor epoch maintenance policy basis source store)

  @doc "Encodes a closed, explicit initial or repair operation, at most 2048 bytes."
  def encode(input) do
    with true <- EnvelopeCodec.keys?(input, Enum.sort(@input)),
         true <- int?(input["authority_epoch"], 1) and int?(input["expected_revision"], 0),
         true <- Id.valid?(input["operation_id"]) and Id.valid?(input["preparation_operation_id"]),
         true <- EnvelopeCodec.digest?(input["preparation_sha256"]),
         true <- is_integer(input["attempt"]) and input["attempt"] in 1..3,
         true <- shape?(input),
         bytes = JSON.encode!([@format, Enum.map(@input, &input[&1])]),
         true <- byte_size(bytes) <= 2048,
         do: {:ok, bytes},
         else: (
           {:error, :authoring_limit} = error -> error
           _ -> invalid()
         )
  end

  @doc "Requires exact historical ordered representation without running a producer."
  def decode(bytes) do
    with {:ok, [@format, values]} when is_list(values) and length(values) == 8 <-
           AuthoringWire.decode(bytes, 2048),
         input = Map.new(Enum.zip(@input, values)),
         {:ok, ^bytes} <- encode(input),
         do: {:ok, input},
         else: (
           {:error, :authoring_limit} = error -> error
           _ -> invalid()
         )
  end

  @doc "Encodes the original handoff reservation without private input or clocks."
  def encode_receipt(r) do
    if EnvelopeCodec.keys?(r, Enum.sort(@receipt)) and int?(r["authority_epoch"], 1) and
         int?(r["revision"], 1) and Id.valid?(r["operation_id"]) and
         is_integer(r["attempt"]) and r["attempt"] in 1..3 and
         r["disposition"] == "handoff_reserved" and
         Enum.all?(
           ~w(input_sha256 preparation_sha256 handoff_sha256 provider_sha256),
           &EnvelopeCodec.digest?(r[&1])
         ) do
      {:ok, JSON.encode!(Enum.map(@receipt, &r[&1]))}
    else
      invalid()
    end
  end

  def decode_receipt(bytes) do
    with {:ok, values} when is_list(values) and length(values) == 9 <-
           AuthoringWire.decode(bytes, 2048),
         r = Map.new(Enum.zip(@receipt, values)),
         {:ok, ^bytes} <- encode_receipt(r),
         do: {:ok, r},
         else: (
           {:error, :authoring_limit} = error -> error
           _ -> invalid()
         )
  end

  @doc "Constructs payload-free failure metadata with a closed withdrawal reason."
  def failure(disposition, reason \\ nil),
    do: %{
      "disposition" => disposition,
      "reason" => reason,
      "draft_ref" => nil,
      "bundle_ref" => nil,
      "assessment" => nil
    }

  @doc "Encodes a candidate's owned references/assessment or bounded failure metadata."
  def encode_result(r) do
    with true <- EnvelopeCodec.keys?(r, Enum.sort(@result)),
         true <- r["disposition"] in @outcomes,
         {:ok, assessment} <- result_values(r),
         bytes =
           JSON.encode!([
             r["disposition"],
             r["reason"],
             ref_values(r["draft_ref"]),
             ref_values(r["bundle_ref"]),
             assessment
           ]),
         true <- byte_size(bytes) <= 131_072,
         do: {:ok, bytes},
         else: (_ -> invalid())
  end

  def decode_result(bytes) do
    with {:ok, [d, reason, draft, bundle, assessment]} <- AuthoringWire.decode(bytes, 131_072),
         {:ok, draft} <- native_ref(draft),
         {:ok, bundle} <- native_ref(bundle),
         {:ok, assessment} <- native_assessment(assessment),
         r = %{
           "disposition" => d,
           "reason" => reason,
           "draft_ref" => draft,
           "bundle_ref" => bundle,
           "assessment" => assessment
         },
         {:ok, ^bytes} <- encode_result(r),
         do: {:ok, r},
         else: (
           {:error, :authoring_limit} = error -> error
           _ -> invalid()
         )
  end

  @doc "Builds the exact private provider document within the original input ceiling."
  def provider_document(projection, feedback, limit)
      when is_binary(projection) and is_integer(limit) and limit in 1..1_048_576 do
    with true <- byte_size(projection) <= limit,
         {:ok, initial} <-
           AuthoringProducer.call(
             Wotex.JSON,
             :decode,
             [
               projection,
               [
                 max_bytes: limit,
                 max_depth: 8,
                 max_nodes: 4096,
                 max_collection_size: 256,
                 max_string_bytes: 262_144
               ]
             ],
             :invalid_generation_attempt
           ),
         true <- is_map(initial) and not is_struct(initial),
         {:ok, f} <- feedback_values(feedback),
         {:ok, bytes} <-
           AuthoringProducer.call(
             Wotex.JSON,
             :encode,
             [
               ["wotex-home.generation-attempt-input@1", initial, f],
               [
                 max_bytes: limit,
                 max_depth: 10,
                 max_nodes: 8192,
                 max_collection_size: 256,
                 max_string_bytes: 262_144
               ]
             ],
             :invalid_generation_attempt
           ),
         true <- byte_size(bytes) <= limit,
         do: {:ok, bytes},
         else: (
           false -> {:error, :authoring_limit}
           {:error, _} = error -> error
           _ -> invalid()
         )
  end

  def provider_document(_, _, _), do: invalid()

  @doc "Derives a stable import operation ID for a generated draft or derived bundle."
  def object_operation(principal, epoch, operation, kind) do
    if Id.valid?(principal) and int?(epoch, 1) and Id.valid?(operation) and
         kind in ~w(draft bundle),
       do:
         "ga:" <>
           AuthoringProducer.sha(
             "wotex-home.generation-object-operation@1\n" <>
               JSON.encode!([principal, epoch, operation, kind])
           ),
       else: nil
  end

  defp result_values(%{"disposition" => "candidate", "reason" => nil} = r) do
    with true <- handle?(r["draft_ref"]),
         true <- r["bundle_ref"] == nil or handle?(r["bundle_ref"]),
         {:ok, bytes} <- AuthoringCandidate.encode_assessment(r["assessment"]),
         true <- r["bundle_ref"] == nil == (r["assessment"]["bundle_sha256"] == nil),
         {:ok, values} <- JSON.decode(bytes),
         do: {:ok, values},
         else: (_ -> invalid())
  end

  defp result_values(r) do
    if r["disposition"] != "candidate" and r["draft_ref"] == nil and r["bundle_ref"] == nil and
         r["assessment"] == nil and
         ((r["disposition"] == "withdrawn" and r["reason"] in @reasons) or
            (r["disposition"] != "withdrawn" and r["reason"] == nil)),
       do: {:ok, nil},
       else: invalid()
  end

  defp feedback_values(nil), do: {:ok, nil}

  defp feedback_values({bytes, assessment})
       when is_binary(bytes) and byte_size(bytes) in 1..262_144 do
    with true <- String.valid?(bytes),
         {:ok, encoded} <- AuthoringCandidate.encode_assessment(assessment),
         true <-
           assessment["disposition"] == "invalid" and
             assessment["draft_sha256"] == AuthoringProducer.sha(bytes),
         {:ok, values} <- JSON.decode(encoded),
         do: {:ok, [bytes, values]},
         else: (_ -> invalid())
  end

  defp feedback_values(_), do: invalid()

  defp native_assessment(nil), do: {:ok, nil}
  defp native_assessment(values), do: AuthoringCandidate.decode_assessment(JSON.encode!(values))
  defp native_ref(nil), do: {:ok, nil}

  defp native_ref([digest, revision]) do
    r = %{"object_digest" => digest, "first_revision" => revision}
    if handle?(r), do: {:ok, r}, else: invalid()
  end

  defp native_ref(_), do: invalid()
  defp ref_values(nil), do: nil
  defp ref_values(r), do: [r["object_digest"], r["first_revision"]]

  defp handle?(r),
    do:
      EnvelopeCodec.keys?(r, ~w(first_revision object_digest)) and
        EnvelopeCodec.digest?(r["object_digest"]) and int?(r["first_revision"], 1)

  defp shape?(%{"attempt" => 1} = r),
    do: r["previous_operation_id"] == nil and r["repair_export"] == false

  defp shape?(r), do: Id.valid?(r["previous_operation_id"]) and r["repair_export"] == true
  defp int?(v, low), do: is_integer(v) and v >= low and v <= @maximum
  defp invalid, do: {:error, :invalid_generation_attempt}
end
