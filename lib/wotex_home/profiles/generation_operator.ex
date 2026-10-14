defmodule WotexHome.Profiles.GenerationOperator do
  @moduledoc """
  Validates generator option metadata and exact private operator responses.

  `validate_options/1` checks at most 32 ordered actor-scoped policy records,
  reconstructing their provider/policy digests and permitted selection metadata.
  The provider-present flag describes an installed process snapshot; it does not
  prove current source custody, available capacity, model authentication or
  permission to export. Reading options creates no preparation or provider call.

  `validate_response/2` requires the closed wrapper for the exact supplied
  request. Preparation/start receipts must match its canonical input digest,
  operation identity and original revision. Status keeps that immutable receipt
  separate from current availability or a settled attempt result; running,
  unknown and cancelled states can have no settled result.

  These are representation checks. `WotexHome.Authority` and
  `WotexHome.Durable.Store` own current actor/export checks and original-operation
  recovery. The validator reads no file, holds no bearer or connection, and
  starts neither a provider nor an automatic repair.
  """

  alias WotexHome.Id

  alias WotexHome.Profiles.{
    AuthoringProducer,
    EnvelopeCodec,
    GenerationAttempt,
    GenerationPolicy,
    GenerationPreparation
  }

  @maximum 9_223_372_036_854_775_807
  @operations ~w(authoring_generation_options authoring_generation_prepare authoring_generation_status
    authoring_generation_start authoring_generation_attempt_status authoring_generation_cancel)
  @policy_fields ~w(provider provider_sha256 policy_sha256 remote_export passages examples limits provider_present)

  @doc "Whether this operation belongs to the closed generation operator boundary."
  def operation?(operation), do: operation in @operations

  @doc "Validates metadata declarations without inferring readiness or export authority."
  def validate_options(value) do
    with true <-
           EnvelopeCodec.keys?(
             value,
             ~w(authority_epoch format policies principal_id store_revision)
           ),
         true <-
           value["format"] == "wotex-home.generation-options@1" and
             Id.valid?(value["principal_id"]),
         true <- int?(value["authority_epoch"], 1) and int?(value["store_revision"], 0),
         :ok <- bounded(value["policies"], 32),
         true <- Enum.all?(value["policies"], &valid_policy?(&1, value["principal_id"])),
         ids = Enum.map(value["policies"], & &1["provider"]["id"]),
         true <- ids == Enum.sort(Enum.uniq(ids)),
         do: :ok,
         else: (_ -> invalid())
  end

  @doc "Requires a closed response and original/status correspondence to the supplied request."
  def validate_response(request, response) do
    with true <- is_map(request) and not is_struct(request) and operation?(request["operation"]),
         true <- is_map(response) and not is_struct(response) and response["api_version"] === 1,
         :ok <- response(request, response),
         do: :ok,
         else: (_ -> invalid())
  end

  defp response(_, %{"outcome" => "error", "reason" => reason} = r) do
    if EnvelopeCodec.keys?(r, ~w(api_version outcome reason)) and is_binary(reason) and
         byte_size(reason) in 1..128 and Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, reason),
       do: :ok,
       else: invalid()
  end

  defp response(request, %{"outcome" => "not_found"} = r),
    do:
      if(
        request["operation"] != "authoring_generation_options" and
          EnvelopeCodec.keys?(r, ~w(api_version outcome)),
        do: :ok,
        else: invalid()
      )

  defp response(request, %{"outcome" => "ok"} = r) do
    operation = request["operation"]
    key = member(operation)

    with true <- EnvelopeCodec.keys?(r, Enum.sort(["api_version", "outcome", key])),
         do: body(operation, request, r[key]),
         else: (_ -> invalid())
  end

  defp response(_, _), do: invalid()

  defp body("authoring_generation_options", _, value), do: validate_options(value)

  defp body("authoring_generation_prepare", request, value) do
    input = request["input"]

    with :ok <- receipt(GenerationPreparation, value),
         {:ok, bytes} <- GenerationPreparation.encode(input),
         true <- matches_input?(value, input, bytes),
         true <-
           value["provider_sha256"] == input["provider_sha256"] and
             value["policy_sha256"] == input["policy_sha256"],
         do: :ok,
         else: (_ -> invalid())
  end

  defp body("authoring_generation_start", request, value) do
    input = request["input"]

    with :ok <- receipt(GenerationAttempt, value),
         {:ok, bytes} <- GenerationAttempt.encode(input),
         true <- matches_input?(value, input, bytes),
         true <-
           value["preparation_sha256"] == input["preparation_sha256"] and
             value["attempt"] == input["attempt"],
         do: :ok,
         else: (_ -> invalid())
  end

  defp body(operation, request, value)
       when operation in ~w(authoring_generation_status authoring_generation_cancel) do
    with true <- EnvelopeCodec.keys?(value, ~w(cancellation_revision original state)),
         :ok <- receipt(GenerationPreparation, value["original"]),
         true <- scope?(request, value["original"]),
         true <- value["state"] in ~w(prepared expired retired cancelled),
         true <- cancellation?(value),
         true <- operation != "authoring_generation_cancel" or value["state"] == "cancelled",
         do: :ok,
         else: (_ -> invalid())
  end

  defp body("authoring_generation_attempt_status", request, value) do
    with true <- EnvelopeCodec.keys?(value, ~w(original result result_revision state)),
         :ok <- receipt(GenerationAttempt, value["original"]),
         true <- scope?(request, value["original"]),
         true <- attempt_state?(value),
         do: :ok,
         else: (_ -> invalid())
  end

  defp valid_policy?(r, principal) do
    with true <-
           EnvelopeCodec.keys?(r, Enum.sort(@policy_fields)) and is_boolean(r["provider_present"]),
         input =
           Map.take(r, ~w(provider remote_export passages examples limits))
           |> Map.put("principal_id", principal),
         {:ok, p} <- GenerationPolicy.new(input),
         true <- p.sha256 == r["policy_sha256"] and p.provider_sha256 == r["provider_sha256"],
         do: true,
         else: (_ -> false)
  end

  defp attempt_state?(%{"result" => nil, "result_revision" => nil, "state" => state}),
    do: state in ~w(running unknown cancelled)

  defp attempt_state?(value) do
    with true <-
           int?(value["result_revision"], 1) and
             value["result_revision"] > value["original"]["revision"],
         {:ok, bytes} <- GenerationAttempt.encode_result(value["result"]),
         {:ok, result} <- GenerationAttempt.decode_result(bytes),
         true <- result == value["result"] and value["state"] == result["disposition"],
         do: true,
         else: (_ -> false)
  end

  defp cancellation?(%{"state" => "cancelled"} = v),
    do:
      int?(v["cancellation_revision"], 1) and
        v["cancellation_revision"] > v["original"]["revision"]

  defp cancellation?(v), do: v["cancellation_revision"] == nil

  defp receipt(codec, value) do
    with {:ok, bytes} <- codec.encode_receipt(value),
         {:ok, ^value} <- codec.decode_receipt(bytes),
         do: :ok,
         else: (_ -> invalid())
  end

  defp matches_input?(r, i, bytes),
    do:
      scope?(i, r) and r["revision"] == i["expected_revision"] + 1 and
        r["input_sha256"] == AuthoringProducer.sha(bytes)

  defp scope?(request, r),
    do:
      r["authority_epoch"] == request["authority_epoch"] and
        r["operation_id"] == request["operation_id"]

  defp member("authoring_generation_options"), do: "authoring_generation_options"
  defp member("authoring_generation_prepare"), do: "authoring_generation_receipt"
  defp member("authoring_generation_start"), do: "authoring_generation_attempt_receipt"
  defp member("authoring_generation_attempt_status"), do: "authoring_generation_attempt"
  defp member(_), do: "authoring_generation"
  defp int?(n, min), do: is_integer(n) and n >= min and n <= @maximum
  defp bounded([], _), do: :ok
  defp bounded([_ | _], 0), do: invalid()
  defp bounded([_ | tail], n), do: bounded(tail, n - 1)
  defp bounded(_, _), do: invalid()
  defp invalid, do: {:error, :invalid_generation_response}
end
