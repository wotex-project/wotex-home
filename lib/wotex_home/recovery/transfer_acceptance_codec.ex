defmodule WotexHome.Recovery.TransferAcceptanceCodec do
  @moduledoc "Canonical acceptance operations/receipts and historical policy; no activation or trust."
  alias WotexHome.{Id, Profiles.Codec}
  @maximum 9_223_372_036_854_775_807
  @operation ~w(principal_id source_epoch operation_id retirement_revision destination_owner_id review_digest isolation_package_digest)
  @receipt ~w(principal_id source_epoch authority_epoch operation_id retirement_revision source_maintenance_revision source_rule_generation rule_generation fence_revision principal_revision revision deployment_id source_owner_id destination_owner_id review_digest isolation_package_digest isolation_decision_digest domain_digest domain_count counter_state counter_state_digest revoked_principals revoked_qualifications cleared_observations cleared_target_grants cleared_source_grants cleared_override_leases)
  @policy ~w(issuer_id public_key generation method procedure_ref policy_digest counter_state)
  @policy_keys [:counter_state, :generation, :method, :policy_digest, :procedure_ref, :public_key]
  @methods ~w(physical_disconnection qualified_network_isolation device_credential_revocation)

  def encode(kind, value) when is_map(value) and not is_struct(value) do
    with {format, fields} <- schema(kind),
         true <- Enum.sort(Map.keys(value)) == Enum.sort(fields),
         true <- shape?(kind, value),
         bytes = JSON.encode!([format, Enum.map(fields, &value[&1])]),
         true <- byte_size(bytes) <= 4_096 do
      {:ok, bytes}
    else
      _ -> invalid()
    end
  end

  def encode(_, _), do: invalid()

  def decode(kind, bytes) when is_binary(bytes) and byte_size(bytes) in 1..4_096 do
    with {format, fields} <- schema(kind),
         {:ok, [^format, values]} <- JSON.decode(bytes),
         true <- is_list(values) and length(values) == length(fields),
         value = Map.new(Enum.zip(fields, values)),
         {:ok, ^bytes} <- encode(kind, value) do
      {:ok, value}
    else
      _ -> invalid()
    end
  end

  def decode(_, _), do: invalid()

  @doc "Retain an exact current policy as inert history, without installing its key."
  def policy_document(issuer, policy) when is_map(policy) and not is_struct(policy) do
    if Enum.sort(Map.keys(policy)) == @policy_keys and is_binary(policy.public_key) and
         byte_size(policy.public_key) == 32 do
      encode("policy", %{
        "issuer_id" => issuer,
        "public_key" => Base.url_encode64(policy.public_key, padding: false),
        "generation" => policy.generation,
        "method" => policy.method,
        "procedure_ref" => policy.procedure_ref,
        "policy_digest" => policy.policy_digest,
        "counter_state" => policy.counter_state
      })
    else
      invalid()
    end
  end

  def policy_document(_, _), do: invalid()

  @doc "Decode historical signature inputs only; this does not establish current issuer trust."
  def historical_issuer(document) do
    with {:ok, value} <- decode("policy", document),
         {:ok, key} <- public_key(value["public_key"]) do
      {:ok, value["issuer_id"],
       %{
         public_key: key,
         generation: value["generation"],
         method: value["method"],
         procedure_ref: value["procedure_ref"],
         policy_digest: value["policy_digest"],
         counter_state: value["counter_state"]
       }}
    end
  end

  defp schema("operation"), do: {"wotex-home.controller-acceptance-operation.v1", @operation}
  defp schema("acceptance"), do: {"wotex-home.controller-acceptance.v1", @receipt}
  defp schema("policy"), do: {"wotex-home.controller-isolation-policy-record.v1", @policy}
  defp schema(_), do: :invalid

  defp shape?("operation", value) do
    Id.valid?(value["principal_id"]) and Id.valid?(value["operation_id"]) and
      integer?(value["source_epoch"], 1, @maximum - 1) and
      integer?(value["retirement_revision"], 2, @maximum - 3) and
      Enum.all?(
        ~w(destination_owner_id review_digest isolation_package_digest),
        &Codec.digest?(value[&1])
      )
  end

  defp shape?("acceptance", value) do
    shape?("operation", value) and
      Enum.all?(
        ~w(deployment_id source_owner_id isolation_decision_digest domain_digest),
        &Codec.digest?(value[&1])
      ) and
      value["source_owner_id"] != value["destination_owner_id"] and
      Enum.all?(
        ~w(authority_epoch rule_generation fence_revision principal_revision revision),
        &integer?(value[&1], 1, @maximum)
      ) and
      value["authority_epoch"] == value["source_epoch"] + 1 and
      integer?(value["source_maintenance_revision"], 1, value["retirement_revision"] - 1) and
      integer?(value["source_rule_generation"], 1, @maximum - 1) and
      value["rule_generation"] == value["source_rule_generation"] + 1 and
      value["fence_revision"] == value["retirement_revision"] + 1 and
      value["principal_revision"] == value["retirement_revision"] + 2 and
      value["revision"] == value["retirement_revision"] + 3 and
      integer?(value["domain_count"], 0, 64) and counter?(value) and
      integer?(value["revoked_principals"], 0, 63) and
      integer?(value["revoked_qualifications"], 0, 64) and
      integer?(value["cleared_override_leases"], 0, 64) and
      Enum.all?(
        ~w(cleared_observations cleared_target_grants cleared_source_grants),
        &integer?(value[&1], 0, 131_072)
      )
  end

  defp shape?("policy", value) do
    Id.valid?(value["issuer_id"]) and Id.valid?(value["procedure_ref"]) and
      match?({:ok, _}, public_key(value["public_key"])) and
      integer?(value["generation"], 1, @maximum) and value["method"] in @methods and
      Codec.digest?(value["policy_digest"]) and
      value["counter_state"] in ["no_radio_state", "verified_continuity"]
  end

  defp shape?(_, _), do: false
  defp counter?(%{"counter_state" => "no_radio_state", "counter_state_digest" => nil}), do: true

  defp counter?(%{"counter_state" => "verified_continuity", "counter_state_digest" => digest}),
    do: Codec.digest?(digest)

  defp counter?(_), do: false

  defp public_key(encoded) when is_binary(encoded) and byte_size(encoded) == 43 do
    with {:ok, key} <- Base.url_decode64(encoded, padding: false),
         true <- byte_size(key) == 32 and Base.url_encode64(key, padding: false) == encoded,
         do: {:ok, key},
         else: (_ -> invalid())
  end

  defp public_key(_), do: invalid()
  defp integer?(value, minimum, maximum), do: is_integer(value) and value in minimum..maximum
  defp invalid, do: {:error, :invalid_transfer_acceptance}
end
