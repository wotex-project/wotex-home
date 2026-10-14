defmodule WotexHome.Profiles.GenerationPreparation do
  @moduledoc """
  Encodes initial generator preparation requests and immutable original receipts.

  `encode/1` and `decode/1` use one bounded ordered-array representation for the
  operation, provider/policy identities, projection selection and explicit attempt
  budget. Decoding requires exact re-encoding; it needs no current producer,
  policy, clock or private object. Receipt helpers preserve the original hashes
  and revision without including document content or credentials.

  A valid representation grants no export authority and records no provider call.
  Authority and Store own current authentication, source ownership, CAS and
  preparation/cancellation transitions. Manual candidate encodings remain separate.
  """

  alias WotexHome.Id
  alias WotexHome.Profiles.{AuthoringWire, EnvelopeCodec, GenerationInput}
  @maximum 9_223_372_036_854_775_807
  @limits ~w(max_passages max_passage_bytes max_passages_bytes max_examples max_examples_bytes max_input_bytes)
  @receipt ~w(authority_epoch operation_id revision input_sha256 projection_sha256 basis_sha256 provider_sha256 policy_sha256 disposition)
  @format "wotex-home.generation-preparation.v1"

  def encode(input) do
    with true <-
           EnvelopeCodec.keys?(
             input,
             ~w(authority_epoch budget expected_revision operation_id policy_sha256 projection provider_sha256 remote_export)
           ),
         true <-
           integer?(input["authority_epoch"], 1) and integer?(input["expected_revision"], 0) and
             Id.valid?(input["operation_id"]),
         true <-
           EnvelopeCodec.digest?(input["policy_sha256"]) and
             EnvelopeCodec.digest?(input["provider_sha256"]) and
             is_boolean(input["remote_export"]),
         :ok <- GenerationInput.validate_request(input["projection"]),
         :ok <- budget(input["budget"]),
         bytes =
           JSON.encode!([
             @format,
             [
               input["authority_epoch"],
               input["operation_id"],
               input["expected_revision"],
               input["provider_sha256"],
               input["policy_sha256"],
               input["remote_export"],
               projection_values(input["projection"]),
               Enum.map(~w(attempts attempt_ms total_ms), &input["budget"][&1])
             ]
           ]),
         true <- byte_size(bytes) <= 32768,
         do: {:ok, bytes},
         else: (
           false -> invalid()
           {:error, :invalid_generation_input} -> invalid()
           error -> error
         )
  end

  def decode(bytes) do
    with {:ok,
          [
            @format,
            [
              epoch,
              operation,
              revision,
              provider,
              policy,
              remote,
              projection,
              [attempts, attempt_ms, total_ms]
            ]
          ]} <- AuthoringWire.decode(bytes, 32768),
         {:ok, p} <- native_projection(projection),
         value = %{
           "authority_epoch" => epoch,
           "operation_id" => operation,
           "expected_revision" => revision,
           "provider_sha256" => provider,
           "policy_sha256" => policy,
           "remote_export" => remote,
           "projection" => p,
           "budget" => %{
             "attempts" => attempts,
             "attempt_ms" => attempt_ms,
             "total_ms" => total_ms
           }
         },
         {:ok, ^bytes} <- encode(value),
         do: {:ok, value},
         else: (
           {:error, :authoring_limit} = error -> error
           _ -> invalid()
         )
  end

  @doc false
  def projection_values(p),
    do: [
      p["contract_digest"],
      p["instruction"],
      Enum.map(p["passages"], &(ref_values(&1["reference"]) ++ [&1["offset"], &1["length"]])),
      Enum.map(p["examples"], &ref_values/1),
      Enum.map(@limits, &p["limits"][&1])
    ]

  @doc false
  def native_projection([contract, instruction, passages, examples, limits])
      when is_list(limits) and length(limits) == 6 do
    with :ok <- bounded(passages),
         :ok <- bounded(examples),
         true <- Enum.all?(passages, &(is_list(&1) and length(&1) == 4)),
         true <- Enum.all?(examples, &(is_list(&1) and length(&1) == 2)) do
      {:ok,
       %{
         "contract_digest" => contract,
         "instruction" => instruction,
         "passages" =>
           Enum.map(passages, fn [d, r, o, n] ->
             %{"reference" => ref(d, r), "offset" => o, "length" => n}
           end),
         "examples" => Enum.map(examples, fn [d, r] -> ref(d, r) end),
         "limits" => Map.new(Enum.zip(@limits, limits))
       }}
    else
      false -> invalid()
      error -> error
    end
  end

  def native_projection(_), do: invalid()

  def encode_receipt(r) do
    if EnvelopeCodec.keys?(r, Enum.sort(@receipt)) and integer?(r["authority_epoch"], 1) and
         integer?(r["revision"], 1) and Id.valid?(r["operation_id"]) and
         r["disposition"] == "prepared" and
         Enum.all?(
           ~w(input_sha256 projection_sha256 basis_sha256 provider_sha256 policy_sha256),
           &EnvelopeCodec.digest?(r[&1])
         ), do: {:ok, JSON.encode!(Enum.map(@receipt, &r[&1]))}, else: invalid()
  end

  def decode_receipt(bytes) do
    with {:ok, values} <- AuthoringWire.decode(bytes, 2048),
         true <- is_list(values) and length(values) == 9,
         r = Map.new(Enum.zip(@receipt, values)),
         {:ok, ^bytes} <- encode_receipt(r),
         do: {:ok, r},
         else: (_ -> invalid())
  end

  defp budget(b) do
    cond do
      not EnvelopeCodec.keys?(b, ~w(attempt_ms attempts total_ms)) ->
        invalid()

      not Enum.all?(Map.values(b), &(is_integer(&1) and &1 > 0)) ->
        invalid()

      b["attempts"] > 3 or b["attempt_ms"] > 30000 or b["total_ms"] > 120_000 ->
        {:error, :authoring_limit}

      b["attempt_ms"] > b["total_ms"] ->
        invalid()

      true ->
        :ok
    end
  end

  defp bounded(list), do: bounded(list, 32)
  defp bounded([], _), do: :ok
  defp bounded([_ | _], 0), do: {:error, :authoring_limit}
  defp bounded([_ | rest], n), do: bounded(rest, n - 1)
  defp bounded(_, _), do: invalid()
  defp integer?(v, min), do: is_integer(v) and v >= min and v <= @maximum
  defp ref_values(r), do: [r["object_digest"], r["first_revision"]]
  defp ref(d, r), do: %{"object_digest" => d, "first_revision" => r}
  defp invalid, do: {:error, :invalid_generation_preparation}
end
