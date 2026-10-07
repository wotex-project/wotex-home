defmodule WotexHome.Profiles.LedgerCodec do
  @moduledoc """
  Closed, ordered row encodings for the schema-19 profile mechanism design.

  Decoding preserves historical identities without authenticating an actor,
  establishing byte custody or promoting a row into current authority. The
  single Store validates journal links and current guard bases separately.
  """

  alias WotexHome.{Id, Profiles.Artifact, Profiles.Bindings, Profiles.Codec, Profiles.Operation}
  alias WotexHome.Durable.Registry

  @format "wotex-home.profile-ledger.v1"
  @max_i64 9_223_372_036_854_775_807
  @schemas %{
    "artifact" =>
      ~w(artifact_digest id version metadata_document projection_document projection_digest binding registry_digest first_approval_revision),
    "operation" =>
      ~w(principal_id authority_epoch operation_id action input_document input_digest expected_revision artifact_digest final_revision changed_targets invalidated_requests unknown_outcomes previous_trust_revision trust_generation policy_generation),
    "selection" =>
      ~w(target_id generation principal_id authority_epoch operation_id previous_selection_revision previous_resource_revision previous_binding_revision artifact_digest projection_digest trust_revision state resource_revision binding_revision runtime_digest review_document thing_document revision),
    "current" => ~w(target_id generation selection_revision state),
    "pin" =>
      ~w(target_id owner_revision artifact_digest projection_digest selection_revision selection_generation trust_revision resource_revision)
  }
  @digests ~w(artifact_digest projection_digest registry_digest input_digest runtime_digest)
  @ids ~w(id version principal_id operation_id target_id)
  @documents ~w(metadata_document projection_document input_document review_document thing_document)

  def encode(kind, row) when is_binary(kind) and is_map(row) do
    with fields when is_list(fields) <- @schemas[kind],
         true <- Enum.sort(Map.keys(row)) == Enum.sort(fields),
         true <- Enum.all?(fields, &field?(&1, row[&1])),
         :ok <- relationships(kind, row) do
      {:ok, JSON.encode!([@format, kind, Enum.map(fields, &row[&1])])}
    else
      _ -> {:error, :invalid_profile_row}
    end
  end

  def encode(_, _), do: {:error, :invalid_profile_row}

  def decode(document) when is_binary(document) and byte_size(document) <= 262_144 do
    with {:ok, [@format, kind, values]} <- JSON.decode(document),
         fields when is_list(fields) <- @schemas[kind],
         true <- is_list(values) and length(values) == length(fields),
         row = Map.new(Enum.zip(fields, values)),
         {:ok, ^document} <- encode(kind, row) do
      {:ok, kind, row}
    else
      _ -> {:error, :invalid_profile_row}
    end
  end

  def decode(_), do: {:error, :invalid_profile_row}

  defp field?(key, value) when key in @digests, do: Codec.digest?(value)
  defp field?(key, value) when key in @ids, do: Id.valid?(value)

  defp field?(key, value) when key in @documents,
    do: is_binary(value) and String.valid?(value) and byte_size(value) <= 65_536

  defp field?("binding", value), do: value == "lifx-direct-power-v1"
  defp field?("action", value), do: value in ~w(approve revoke select revoke_selection)
  defp field?("state", value), do: value in ~w(selected revoked)
  defp field?(_, value), do: is_integer(value) and value in 0..@max_i64

  defp relationships("artifact", row) do
    with true <- row["first_approval_revision"] > 0,
         {:ok, data} <- Codec.decode(row["metadata_document"]),
         true <- JSON.encode!(data) == row["metadata_document"],
         true <- data["id"] == row["id"] and data["version"] == row["version"],
         {:ok, projection} <- Bindings.historical_projection(data),
         true <- projection == row["projection_document"],
         true <- Artifact.digest(projection) == row["projection_digest"],
         true <- row["binding"] == data["binding"],
         true <- row["registry_digest"] == hd(data["dependencies"])["sha256"] do
      :ok
    else
      _ -> :error
    end
  end

  defp relationships("operation", row) do
    with {:ok, input} <- Operation.decode(row["input_document"]),
         true <- Artifact.digest(row["input_document"]) == row["input_digest"],
         true <-
           Enum.all?(
             ~w(action authority_epoch operation_id expected_revision artifact_digest),
             &(row[&1] == input[&1])
           ),
         true <- row["final_revision"] > row["expected_revision"],
         true <- row["previous_trust_revision"] == input["expected_trust_revision"],
         true <- row["trust_generation"] > 0,
         true <- row["authority_epoch"] > 0 and row["policy_generation"] > 0,
         true <- row["changed_targets"] <= 64,
         true <- row["invalidated_requests"] <= 1_024,
         true <- row["unknown_outcomes"] <= row["invalidated_requests"] do
      :ok
    else
      _ -> :error
    end
  end

  defp relationships("selection", row) do
    with true <- row["generation"] > 0 and row["authority_epoch"] > 0,
         true <- row["revision"] > row["previous_selection_revision"],
         true <- row["resource_revision"] == row["previous_resource_revision"] + 1,
         true <- row["trust_revision"] > 0 and row["binding_revision"] > 0,
         {:ok, thing} <- Registry.decode_thing(row["thing_document"]),
         true <- thing.id == row["target_id"],
         true <- row["state"] == "revoked" or byte_size(row["review_document"]) > 0 do
      :ok
    else
      _ -> :error
    end
  end

  defp relationships("current", row),
    do: if(row["generation"] > 0 and row["selection_revision"] > 0, do: :ok, else: :error)

  defp relationships("pin", row),
    do:
      if(
        Enum.all?(
          ~w(owner_revision selection_revision selection_generation trust_revision),
          &(row[&1] > 0)
        ),
        do: :ok,
        else: :error
      )
end
