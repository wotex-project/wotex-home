defmodule WotexHome.Qualification.HistoryCodec do
  @moduledoc """
  Closed immutable qualification snapshots for the schema-20 mechanism design.

  Legacy migration preserves the original slot without inventing its declaration,
  actor, epoch or review revision. Guarded new snapshots retain those exact pins.
  A structurally valid historical row is not current physical qualification.
  """

  alias WotexHome.{Id, Durable.Registry, Profiles.Codec}
  @format "wotex-home.qualification-history.v1"
  @max_i64 9_223_372_036_854_775_807
  @fields ~w(thing_id profile_ref resource_revision identity_digest basis_digest registry_digest runtime_digest evidence_ref revision provenance declaration_document principal_id authority_epoch binding_revision)
  @digests ~w(identity_digest basis_digest registry_digest runtime_digest)
  @ids ~w(thing_id profile_ref evidence_ref)
  @nullable ~w(declaration_document principal_id authority_epoch binding_revision)
  def fields, do: @fields

  def encode(row) when is_map(row) and not is_struct(row) do
    with true <- Enum.sort(Map.keys(row)) == Enum.sort(@fields),
         true <- Enum.all?(@digests, &Codec.digest?(row[&1])),
         true <- Enum.all?(@ids, &Id.valid?(row[&1])),
         true <-
           integer?(row["resource_revision"]) and integer?(row["revision"]) and
             row["revision"] > 0,
         :ok <- provenance(row) do
      {:ok, JSON.encode!([@format, Enum.map(@fields, &row[&1])])}
    else
      _ -> {:error, :invalid_qualification_history}
    end
  end

  def encode(_), do: {:error, :invalid_qualification_history}

  def decode(document) when is_binary(document) and byte_size(document) <= 131_072 do
    with {:ok, [@format, values]} <- JSON.decode(document),
         true <- is_list(values) and length(values) == length(@fields),
         row = Map.new(Enum.zip(@fields, values)),
         {:ok, ^document} <- encode(row) do
      {:ok, row}
    else
      _ -> {:error, :invalid_qualification_history}
    end
  end

  def decode(_), do: {:error, :invalid_qualification_history}

  defp provenance(%{"provenance" => "legacy_migrated"} = row),
    do: if(Enum.all?(@nullable, &is_nil(row[&1])), do: :ok, else: :error)

  defp provenance(%{"provenance" => "guarded_current"} = row) do
    with true <- Id.valid?(row["principal_id"]),
         true <- integer?(row["authority_epoch"]) and row["authority_epoch"] > 0,
         true <-
           integer?(row["binding_revision"]) and row["binding_revision"] > 0 and
             row["binding_revision"] < row["revision"],
         document when is_binary(document) and byte_size(document) <= 65_536 <-
           row["declaration_document"],
         {:ok, thing} <- Registry.decode_thing(document),
         true <- thing.id == row["thing_id"] and thing.profile_ref == row["profile_ref"],
         {:ok, ^document} <- Registry.encode_thing(thing) do
      :ok
    else
      _ -> :error
    end
  end

  defp provenance(_), do: :error
  defp integer?(value), do: is_integer(value) and value in 0..@max_i64
end
