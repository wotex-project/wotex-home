defmodule WotexHome.Recovery.ClockCodec do
  @moduledoc "Canonical signed recovery time documents; signature verification creates no confidence."
  alias WotexHome.Id
  alias WotexHome.Profiles.{Artifact, Codec}
  @policy "wotex-home.controller-clock-policy.v1"
  @request "wotex-home.controller-clock-request.v1"
  @record "wotex-home.controller-clock-record.v1"
  @package "wotex-home.controller-clock-package.v1"
  @maximum 9_223_372_036_854_775_807
  @scope ~w(destination_owner_id runtime_digest challenge_id issuer_id issuer_generation policy_digest issuer_policy_digest)
  @record_fields @scope ++ ~w(procedure_ref observed_utc_ms)
  @policy_fields ~w(issuer_id public_key generation procedure_ref policy_digest maximum_response_ms maximum_age_ms maximum_error_ms)a

  def policy_document(policy) do
    if exact?(policy, @policy_fields) and Id.valid?(policy.issuer_id) and
         is_binary(policy.public_key) and byte_size(policy.public_key) == 32 and
         integer?(policy.generation, 1, @maximum) and Id.valid?(policy.procedure_ref) and
         Codec.digest?(policy.policy_digest) and integer?(policy.maximum_response_ms, 1, 60_000) and
         integer?(policy.maximum_age_ms, 1, 600_000) and
         integer?(policy.maximum_error_ms, 0, 1_000) and
         policy.maximum_age_ms > policy.maximum_response_ms + 2 * policy.maximum_error_ms do
      values =
        Enum.map(@policy_fields, fn
          :public_key -> Base.url_encode64(policy.public_key, padding: false)
          field -> policy[field]
        end)

      {:ok, JSON.encode!([@policy | values])}
    else
      invalid()
    end
  end

  def decode_policy(document) do
    with {:ok, [@policy, issuer, key, generation, procedure, digest, response, age, error]} <-
           json(document),
         {:ok, public} <- canonical_binary(key, 32),
         policy = %{
           issuer_id: issuer,
           public_key: public,
           generation: generation,
           procedure_ref: procedure,
           policy_digest: digest,
           maximum_response_ms: response,
           maximum_age_ms: age,
           maximum_error_ms: error
         },
         {:ok, ^document} <- policy_document(policy) do
      {:ok, policy}
    else
      _ -> invalid()
    end
  end

  def request_document(request) do
    if exact?(request, @scope) and scope?(request),
      do: {:ok, JSON.encode!([@request | Enum.map(@scope, &request[&1])])},
      else: invalid()
  end

  def decode_request(document),
    do: decode_ordered(document, @request, @scope, &request_document/1)

  def record_document(record) do
    if exact?(record, @record_fields) and scope?(record) and Id.valid?(record["procedure_ref"]) and
         integer?(record["observed_utc_ms"], 0, @maximum - 600_000),
       do: {:ok, JSON.encode!([@record | Enum.map(@record_fields, &record[&1])])},
       else: invalid()
  end

  def signing_payload(record) do
    with {:ok, document} <- record_document(record), do: {:ok, @record <> <<0>> <> document}
  end

  def encode(record, signature) when is_binary(signature) and byte_size(signature) == 64 do
    with {:ok, document} <- record_document(record),
         {:ok, values} <- JSON.decode(document) do
      {:ok, JSON.encode!([@package, values, Base.url_encode64(signature, padding: false)])}
    end
  end

  def encode(_, _), do: invalid()

  def decode(document) do
    with {:ok, [@package, values, encoded]} <- json(document),
         {:ok, record} <-
           decode_ordered(JSON.encode!(values), @record, @record_fields, &record_document/1),
         {:ok, signature} <- canonical_binary(encoded, 64),
         {:ok, ^document} <- encode(record, signature),
         {:ok, payload} <- signing_payload(record) do
      {:ok,
       %{
         record: record,
         signature: signature,
         signing_payload: payload,
         package_digest: Artifact.digest(document)
       }}
    else
      _ -> invalid()
    end
  rescue
    _ -> invalid()
  end

  @doc "Inert exact signature/scope audit; no clock read, boot challenge or authority."
  def verify(document, request_document, policy_document) do
    with {:ok, request} <- decode_request(request_document),
         {:ok, policy} <- decode_policy(policy_document),
         {:ok, parsed} <- decode(document),
         true <- Map.take(parsed.record, @scope) == request,
         true <-
           request["issuer_id"] == policy.issuer_id and
             request["issuer_generation"] == policy.generation and
             request["policy_digest"] == policy.policy_digest and
             request["issuer_policy_digest"] == Artifact.digest(policy_document) and
             parsed.record["procedure_ref"] == policy.procedure_ref,
         true <-
           :crypto.verify(:eddsa, :none, parsed.signing_payload, parsed.signature, [
             policy.public_key,
             :ed25519
           ]) do
      {:ok, parsed}
    else
      false -> {:error, :clock_signature_or_scope_mismatch}
      _ -> invalid()
    end
  rescue
    _ -> invalid()
  end

  defp decode_ordered(document, format, fields, encoder) do
    with {:ok, [^format | values]} <- json(document),
         true <- length(values) == length(fields),
         value = Map.new(Enum.zip(fields, values)),
         {:ok, ^document} <- encoder.(value),
         do: {:ok, value},
         else: (_ -> invalid())
  end

  defp scope?(value),
    do:
      Codec.digest?(value["destination_owner_id"]) and
        Codec.digest?(value["runtime_digest"]) and Id.valid?(value["challenge_id"]) and
        Id.valid?(value["issuer_id"]) and integer?(value["issuer_generation"], 1, @maximum) and
        Codec.digest?(value["policy_digest"]) and Codec.digest?(value["issuer_policy_digest"])

  defp exact?(value, fields),
    do:
      is_map(value) and not is_struct(value) and
        Enum.sort(Map.keys(value)) == Enum.sort(fields)

  defp integer?(value, minimum, maximum),
    do: is_integer(value) and value >= minimum and value <= maximum

  defp json(document) when is_binary(document) and byte_size(document) in 1..4_096,
    do: JSON.decode(document)

  defp json(_), do: invalid()

  defp canonical_binary(value, size) when is_binary(value) do
    with {:ok, bytes} <- Base.url_decode64(value, padding: false),
         true <- byte_size(bytes) == size and Base.url_encode64(bytes, padding: false) == value,
         do: {:ok, bytes},
         else: (_ -> invalid())
  end

  defp canonical_binary(_, _), do: invalid()
  defp invalid, do: {:error, :invalid_clock_document}
end
