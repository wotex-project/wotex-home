defmodule WotexHome.Profiles.Operation do
  @moduledoc """
  Executable canonical input encodings for the planned durable profile ledger.

  These encodings identify requests, never approve an artifact or authorize a
  selection. Store must derive the principal, retained metadata and review from
  authenticated host custody, then check all current pins in its transaction.
  """

  alias WotexHome.{Id, Profiles.Codec}

  @format "wotex-home.profile-operation.v1"
  @max_i64 9_223_372_036_854_775_807
  @common ~w(action authority_epoch operation_id expected_revision artifact_digest expected_trust_revision)
  @selection ~w(target_id expected_resource_revision expected_binding_revision expected_selection_generation expected_policy_generation expected_rule_generation session_ref candidate_ref review_ref)
  @revocation ~w(target_id expected_resource_revision expected_selection_generation)
  @integers ~w(authority_epoch expected_revision expected_trust_revision expected_resource_revision expected_binding_revision expected_selection_generation expected_policy_generation expected_rule_generation)
  @ids ~w(operation_id target_id session_ref candidate_ref review_ref)

  def encode(input) when is_map(input) do
    with fields when is_list(fields) <- fields(input["action"]),
         true <- Enum.sort(Map.keys(input)) == Enum.sort(fields),
         true <- Codec.digest?(input["artifact_digest"]),
         true <- input["authority_epoch"] > 0,
         true <- Enum.all?(fields -- ~w(action artifact_digest), &valid_field?(&1, input[&1])) do
      {:ok, JSON.encode!([@format, Enum.map(fields, &input[&1])])}
    else
      _ -> {:error, :invalid_profile_operation}
    end
  end

  def encode(_), do: {:error, :invalid_profile_operation}

  def decode(document) when is_binary(document) and byte_size(document) <= 4_096 do
    with {:ok, [@format, [action | _] = values]} <- JSON.decode(document),
         fields when is_list(fields) <- fields(action),
         true <- length(fields) == length(values),
         input = Map.new(Enum.zip(fields, values)),
         {:ok, ^document} <- encode(input) do
      {:ok, input}
    else
      _ -> {:error, :invalid_profile_operation}
    end
  end

  def decode(_), do: {:error, :invalid_profile_operation}

  defp fields(action) when action in ["approve", "revoke"], do: @common
  defp fields("select"), do: @common ++ @selection
  defp fields("revoke_selection"), do: @common ++ @revocation
  defp fields(_), do: :error

  defp valid_field?(key, value) when key in @integers,
    do: is_integer(value) and value in 0..@max_i64

  defp valid_field?(key, value) when key in @ids, do: Id.valid?(value)
  defp valid_field?(_, _), do: false
end
