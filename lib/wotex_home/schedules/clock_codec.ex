defmodule WotexHome.Schedules.ClockCodec do
  @moduledoc "Closed purpose-specific temporal clock signatures. Parsing or signature verification alone establishes no confidence."
  alias WotexHome.{Id, Schedules.Codec}
  alias WotexHome.Profiles.Codec, as: ProfileCodec
  @policy "wotex-home.schedule-clock-policy.v1"
  @request "wotex-home.schedule-clock-request.v1"
  @record "wotex-home.schedule-clock-record.v1"
  @package "wotex-home.schedule-clock-package.v1"
  @policy_fields ~w(source_id issuer_id public_key issuer_generation procedure_ref qualification_digest runtime_digest maximum_response_ms maximum_age_ms maximum_error_ms drift_ppm maximum_discontinuity_ms monotonic_policy)a
  @scope ~w(deployment_id owner_id authority_epoch store_boot_epoch clock_generation runtime_digest challenge_nonce source_id issuer_id issuer_generation qualification_digest policy_document_digest)
  @record_fields @scope ++ ~w(procedure_ref observed_utc_ms)

  def policy_document(policy) do
    if Codec.exact?(policy, @policy_fields) and
         Enum.all?([:source_id, :issuer_id, :procedure_ref], &Id.valid?(policy[&1])) and
         is_binary(policy.public_key) and byte_size(policy.public_key) == 32 and
         Codec.integer?(policy.issuer_generation, 1, Codec.maximum()) and
         ProfileCodec.digest?(policy.qualification_digest) and
         ProfileCodec.digest?(policy.runtime_digest) and
         Codec.integer?(policy.maximum_response_ms, 1, 60_000) and
         Codec.integer?(policy.maximum_age_ms, 1, 600_000) and
         Codec.integer?(policy.maximum_error_ms, 0, 1_000) and
         policy.maximum_age_ms > policy.maximum_response_ms + 2 * policy.maximum_error_ms and
         Codec.integer?(policy.drift_ppm, 0, 1_000) and
         Codec.integer?(policy.maximum_discontinuity_ms, 0, 1_000) and
         policy.monotonic_policy == "invalidate_on_discontinuity" do
      {:ok, ordered(@policy, @policy_fields, Map.update!(policy, :public_key, &binary/1))}
    else
      invalid()
    end
  end

  def decode_policy(document) do
    with {:ok, [@policy | values]} <- Codec.record(document),
         true <- length(values) == length(@policy_fields),
         encoded = Map.new(Enum.zip(@policy_fields, values)),
         {:ok, public} <- canonical_binary(encoded.public_key, 32),
         policy = %{encoded | public_key: public},
         {:ok, ^document} <- policy_document(policy),
         do: {:ok, policy},
         else: (_ -> invalid())
  end

  def request_document(request) do
    if Codec.exact?(request, @scope) and scope?(request),
      do: {:ok, ordered(@request, @scope, request)},
      else: invalid()
  end

  def decode_request(document),
    do: decode_ordered(document, @request, @scope, &request_document/1)

  def record_document(record) do
    if Codec.exact?(record, @record_fields) and scope?(record) and
         Id.valid?(record["procedure_ref"]) and Codec.utc?(record["observed_utc_ms"]),
       do: {:ok, ordered(@record, @record_fields, record)},
       else: invalid()
  end

  def signing_payload(record) do
    with {:ok, document} <- record_document(record), do: {:ok, @record <> <<0>> <> document}
  end

  def encode(record, signature) when is_binary(signature) and byte_size(signature) == 64 do
    with {:ok, document} <- record_document(record),
         {:ok, values} <- Codec.record(document),
         do: {:ok, JSON.encode!([@package, values, binary(signature)])}
  end

  def encode(_, _), do: invalid()

  def decode(document) do
    with {:ok, [@package, values, signature]} <- Codec.record(document),
         true <- is_list(values),
         {:ok, record} <-
           decode_ordered(JSON.encode!(values), @record, @record_fields, &record_document/1),
         {:ok, signature} <- canonical_binary(signature, 64),
         {:ok, ^document} <- encode(record, signature),
         {:ok, payload} <- signing_payload(record),
         do:
           {:ok,
            %{
              record: record,
              signature: signature,
              signing_payload: payload,
              package_digest: Codec.hash(document)
            }},
         else: (_ -> invalid())
  rescue
    _ -> invalid()
  end

  def verify(document, request_document, policy_document) do
    with {:ok, request} <- decode_request(request_document),
         {:ok, policy} <- decode_policy(policy_document),
         {:ok, parsed} <- decode(document),
         true <- Map.take(parsed.record, @scope) == request,
         true <-
           request["source_id"] == policy.source_id and
             request["issuer_id"] == policy.issuer_id and
             request["issuer_generation"] == policy.issuer_generation and
             request["qualification_digest"] == policy.qualification_digest and
             request["runtime_digest"] == policy.runtime_digest and
             request["policy_document_digest"] == Codec.hash(policy_document) and
             parsed.record["procedure_ref"] == policy.procedure_ref,
         true <-
           :crypto.verify(:eddsa, :none, parsed.signing_payload, parsed.signature, [
             policy.public_key,
             :ed25519
           ]),
         do: {:ok, parsed},
         else: (
           false -> {:error, :schedule_clock_signature_or_scope_mismatch}
           _ -> invalid()
         )
  rescue
    _ -> invalid()
  end

  defp ordered(format, fields, value), do: JSON.encode!([format | Enum.map(fields, &value[&1])])

  defp decode_ordered(document, format, fields, encoder) do
    with {:ok, [^format | values]} <- Codec.record(document),
         true <- length(values) == length(fields),
         value = Map.new(Enum.zip(fields, values)),
         {:ok, ^document} <- encoder.(value),
         do: {:ok, value},
         else: (_ -> invalid())
  end

  defp scope?(value),
    do:
      Enum.all?(
        ~w(deployment_id owner_id runtime_digest qualification_digest policy_document_digest),
        &ProfileCodec.digest?(value[&1])
      ) and
        Enum.all?(~w(store_boot_epoch source_id issuer_id), &Id.valid?(value[&1])) and
        Enum.all?(
          ~w(authority_epoch clock_generation issuer_generation),
          &Codec.integer?(value[&1], 1, Codec.maximum())
        ) and
        match?({:ok, _}, canonical_binary(value["challenge_nonce"], 32))

  defp binary(bytes), do: Base.url_encode64(bytes, padding: false)

  defp canonical_binary(value, size) when is_binary(value) do
    with {:ok, bytes} <- Base.url_decode64(value, padding: false),
         true <- byte_size(bytes) == size and binary(bytes) == value,
         do: {:ok, bytes},
         else: (_ -> invalid())
  end

  defp canonical_binary(_, _), do: invalid()
  defp invalid, do: {:error, :invalid_schedule_clock_document}
end
