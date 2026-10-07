defmodule WotexHome.NativeSetup.TargetCodec do
  @moduledoc "Inert original native target-access records; no grant, listener or custody authority."
  alias WotexHome.NativeSetup.Codec, as: Setup
  alias WotexHome.Profiles.Codec, as: Profiles
  alias WotexHome.Id
  @format "wotex-home.native-target-access.v1"
  @maximum 9_223_372_036_854_775_807
  @original ~w(deployment_id owner_id authority_epoch creation_revision verifier)
  @grant @original ++
           ~w(operation_id expected_revision target_id resource_revision binding_revision selection_generation artifact_digest)
  @revoke @original ++ ~w(operation_id expected_revision target_id)
  @status @original ++ ~w(operation_id)
  @receipt ~w(deployment_id owner_id authority_epoch principal_id operation_id action target_id input_digest expected_revision change_revision final_revision affected_requests unknown_outcomes)
  @reasons ~w(invalid_native_target_record native_owner_changed native_custody_conflict native_target_unavailable native_target_changed native_target_exists native_target_missing native_target_capacity native_operation_conflict revision_conflict maintenance_active source_retired outcome_unknown)

  def encode("grant", value), do: record("grant", @grant, value, &grant?/1)
  def encode("revoke", value), do: record("revoke", @revoke, value, &revoke?/1)
  def encode("status", value), do: record("status", @status, value, &status?/1)
  def encode("not_found", value), do: record("not_found", @status, value, &status?/1)
  def encode("receipt", value), do: record("receipt", @receipt, value, &receipt?/1)
  def encode("error", value), do: record("error", ["reason"], value, &(&1["reason"] in @reasons))
  def encode(_, _), do: invalid()

  def digest(action, value) when action in ["grant", "revoke"] do
    with {:ok, bytes} <- encode(action, value),
         do: {:ok, Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}
  end

  def digest(_, _), do: invalid()

  def decode(kind, bytes) when is_binary(bytes) and byte_size(bytes) in 1..4_096 do
    with true <- String.valid?(bytes),
         {[@format, ^kind | values], {0, 0, nil}, ""} <-
           JSON.decode(bytes, {0, 0, nil}, decoders()),
         fields when is_list(fields) <- fields(kind),
         true <- length(fields) == length(values),
         value = Map.new(Enum.zip(fields, values)),
         {:ok, ^bytes} <- encode(kind, value),
         do: {:ok, value},
         else: (_ -> invalid())
  catch
    :throw, :invalid_native_target_record -> invalid()
  end

  def decode(_, _), do: invalid()

  defp record(kind, fields, value, predicate) do
    if is_map(value) and not is_struct(value) and Enum.sort(Map.keys(value)) == Enum.sort(fields) and
         predicate.(value),
       do: {:ok, JSON.encode!([@format, kind | Enum.map(fields, &value[&1])])},
       else: invalid()
  end

  defp scope?(value),
    do:
      Profiles.digest?(value["deployment_id"]) and Profiles.digest?(value["owner_id"]) and
        integer?(value["authority_epoch"], 1)

  defp original?(value),
    do:
      scope?(value) and integer?(value["creation_revision"], 1) and
        Profiles.digest?(value["verifier"])

  defp status?(value), do: original?(value) and id?(value["operation_id"])

  defp revoke?(value),
    do:
      status?(value) and integer?(value["expected_revision"], 1) and
        value["expected_revision"] < @maximum and
        value["creation_revision"] <= value["expected_revision"] and
        id?(value["target_id"])

  defp grant?(value),
    do:
      revoke?(value) and integer?(value["resource_revision"], 1) and
        integer?(value["binding_revision"], 1) and
        integer?(value["selection_generation"], 1) and Profiles.digest?(value["artifact_digest"])

  defp receipt?(value) do
    scope?(value) and
      value["principal_id"] == Setup.principal(value["authority_epoch"], "operator") and
      id?(value["operation_id"]) and value["action"] in ["grant", "revoke"] and
      id?(value["target_id"]) and
      Profiles.digest?(value["input_digest"]) and integer?(value["expected_revision"], 1) and
      integer?(value["change_revision"], 2) and integer?(value["final_revision"], 2) and
      is_integer(value["affected_requests"]) and value["affected_requests"] in 0..1_024 and
      is_integer(value["unknown_outcomes"]) and
      value["unknown_outcomes"] in 0..value["affected_requests"] and
      value["change_revision"] == value["expected_revision"] + 1 and
      value["final_revision"] == value["change_revision"] + value["affected_requests"]
  end

  defp integer?(value, minimum), do: is_integer(value) and value in minimum..@maximum

  defp id?(value), do: Id.valid?(value)
  defp fields("grant"), do: @grant
  defp fields("revoke"), do: @revoke
  defp fields("status"), do: @status
  defp fields("not_found"), do: @status
  defp fields("receipt"), do: @receipt
  defp fields("error"), do: ["reason"]
  defp fields(_), do: :invalid

  defp decoders do
    [
      array_start: fn
        {0, _, _} -> {1, 0, []}
        _ -> reject()
      end,
      array_push: fn
        value, {1, count, values} when count < 16 -> {1, count + 1, [value | values]}
        _, _ -> reject()
      end,
      array_finish: fn {1, _, values}, parent -> {Enum.reverse(values), parent} end,
      object_start: fn _ -> reject() end,
      string: fn value -> if byte_size(value) <= 128, do: value, else: reject() end,
      integer: fn value ->
        if byte_size(value) <= 19 do
          integer = String.to_integer(value)
          if integer >= 0 and integer <= @maximum, do: integer, else: reject()
        else
          reject()
        end
      end,
      float: fn _ -> reject() end
    ]
  end

  defp invalid, do: {:error, :invalid_native_target_record}
  defp reject, do: throw(:invalid_native_target_record)
end
