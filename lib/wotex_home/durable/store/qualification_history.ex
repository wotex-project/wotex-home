defmodule WotexHome.Durable.Store.QualificationHistory do
  @moduledoc "Immutable qualification snapshots on the Store-owned connection."
  alias WotexHome.Durable.Registry
  alias WotexHome.Qualification.HistoryCodec
  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]

  @fields HistoryCodec.fields()
  @columns Enum.join(@fields, ",")
  @head ~w(thing_id profile_ref resource_revision identity_digest basis_digest registry_digest runtime_digest evidence_ref revision)
  @capacity 4_096

  def validate(db) do
    with {:ok, [[revision, epoch]]} <-
           query(
             db,
             "SELECT (SELECT value FROM meta WHERE key='revision'),(SELECT value FROM meta WHERE key='authority_epoch')"
           ),
         {:ok, [[boundary]]} <-
           query(
             db,
             "SELECT value FROM meta WHERE key='qualification_history_migration_revision'"
           ),
         true <- is_integer(boundary) and boundary in 0..revision,
         {:ok, rows} <-
           query(
             db,
             "SELECT #{@columns} FROM profile_qualification_history ORDER BY revision LIMIT 4097"
           ),
         true <- length(rows) <= @capacity,
         true <- Enum.all?(rows, &valid_row?(db, &1, revision, epoch, boundary)),
         {:ok, [[0]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM authority_journal a LEFT JOIN profile_qualification_history h ON h.revision=a.revision AND h.thing_id=a.entity_id WHERE a.event_type='profile_qualified' AND h.revision IS NULL"
           ),
         {:ok, [[0]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM profile_qualification_history h WHERE NOT EXISTS (SELECT 1 FROM profile_qualifications q WHERE q.thing_id=h.thing_id)"
           ),
         {:ok, [[0]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM profile_qualifications q LEFT JOIN profile_qualification_history h ON h.revision=q.revision WHERE h.revision IS NULL OR " <>
               Enum.map_join(@head, " OR ", &"q.#{&1} != h.#{&1}") <>
               " OR EXISTS (SELECT 1 FROM profile_qualification_history newer WHERE newer.thing_id=q.thing_id AND newer.revision>q.revision)"
           ),
         {:ok, [[0]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM profile_qualifications q JOIN profile_qualification_history h ON h.revision=q.revision JOIN enrolled_things t ON t.thing_id=q.thing_id JOIN enrollment_bindings b ON b.thing_id=q.thing_id WHERE q.status='qualified' AND (q.resource_revision!=t.resource_revision OR q.profile_ref!=t.profile_ref OR q.identity_digest!=b.identity_digest OR q.profile_ref!=b.profile_ref OR (h.provenance='guarded_current' AND h.declaration_document!=t.document))"
           ) do
      :ok
    else
      _ -> {:error, :corrupt_qualification_history}
    end
  end

  def find(db, verified) do
    case query(
           db,
           "SELECT #{@columns} FROM profile_qualification_history WHERE thing_id=? AND evidence_ref=?",
           [verified.thing_id, verified.evidence_ref]
         ) do
      {:ok, []} ->
        {:ok, nil}

      {:ok, [values]} ->
        row = Map.new(Enum.zip(@fields, values))

        if Enum.all?(
             @head -- ["revision"],
             &(row[&1] == Map.get(verified, String.to_existing_atom(&1)))
           ) do
          {:ok, row["revision"]}
        else
          {:error, :qualification_conflict}
        end

      _ ->
        {:error, :corrupt_qualification_history}
    end
  end

  def append(db, verified, principal, revision) do
    with {:ok, [[count]]} <- query(db, "SELECT COUNT(*) FROM profile_qualification_history"),
         true <- count < @capacity,
         {:ok, [[document, binding, epoch]]} <-
           query(
             db,
             "SELECT t.document,b.revision,(SELECT value FROM meta WHERE key='authority_epoch') FROM enrolled_things t JOIN enrollment_bindings b ON b.thing_id=t.thing_id WHERE t.thing_id=?",
             [verified.thing_id]
           ),
         row =
           Map.new(
             @head -- ["revision"],
             &{&1, Map.fetch!(verified, String.to_existing_atom(&1))}
           ),
         row =
           Map.merge(row, %{
             "revision" => revision,
             "provenance" => "guarded_current",
             "declaration_document" => document,
             "principal_id" => principal,
             "authority_epoch" => epoch,
             "binding_revision" => binding
           }),
         {:ok, _} <- HistoryCodec.encode(row),
         {:ok, []} <-
           query(
             db,
             "INSERT INTO profile_qualification_history (#{@columns}) VALUES (#{Enum.map_join(@fields, ",", fn _ -> "?" end)})",
             Enum.map(@fields, &row[&1])
           ) do
      :ok
    else
      false -> {:error, :qualification_history_full}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :corrupt_qualification_history}
    end
  end

  defp valid_row?(db, values, revision, epoch, boundary) do
    row = Map.new(Enum.zip(@fields, values))

    with {:ok, _} <- HistoryCodec.encode(row),
         true <- row["revision"] <= revision,
         true <- row["provenance"] == "legacy_migrated" == row["revision"] <= boundary,
         {:ok, [["profile_qualified", target]]} <-
           query(db, "SELECT event_type,entity_id FROM authority_journal WHERE revision=?", [
             row["revision"]
           ]),
         true <- target == row["thing_id"],
         :ok <- provenance_links(db, row, epoch) do
      true
    else
      _ -> false
    end
  end

  defp provenance_links(_db, %{"provenance" => "legacy_migrated"}, _epoch), do: :ok

  defp provenance_links(db, row, epoch) do
    with true <- row["authority_epoch"] <= epoch,
         {:ok, [[1]]} <-
           query(db, "SELECT COUNT(*) FROM principals WHERE principal_id=?", [row["principal_id"]]),
         {:ok, [[profile, identity, 2]]} <-
           query(
             db,
             "SELECT profile_ref,identity_digest,digest_version FROM enrollment_review_history WHERE revision=? AND thing_id=?",
             [row["binding_revision"], row["thing_id"]]
           ),
         true <- profile == row["profile_ref"] and identity == row["identity_digest"],
         {:ok, thing} <- Registry.decode_thing(row["declaration_document"]),
         true <- thing.id == row["thing_id"] and thing.profile_ref == profile do
      :ok
    else
      _ -> :error
    end
  end
end
