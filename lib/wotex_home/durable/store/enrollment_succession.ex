defmodule WotexHome.Durable.Store.EnrollmentSuccession do
  @moduledoc "Exact retained reviewer succession through audited ownership; borrowed Store handle only."
  alias WotexHome.Durable.Store.{ControllerHistory, ControllerWriter}
  alias WotexHome.Profiles.Artifact
  alias WotexHome.Recovery.TransferAcceptanceRecord
  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]

  @history ~w(revision thing_id stable_id identity_digest digest_version candidate_ref review_ref method qualification_ref operator_id profile_ref manufacturer model firmware)
  @binding ~w(thing_id stable_id identity_digest candidate_ref review_ref method qualification_ref operator_id profile_ref revision digest_version)
  def binding_columns, do: Enum.join(@binding, ",")

  def authorize(db, operator, binding) when is_list(binding) and length(binding) == 11 do
    with {:ok, [[22]]} <- query(db, "PRAGMA user_version"),
         {:ok, %{state: "active", retirement_revision: head, authority_epoch: epoch}} <-
           ControllerWriter.identity(db),
         true <- head > 0,
         {:ok, accepted} <- acceptance(db, "revision=?", [head]),
         true <- accepted.receipt["principal_id"] == operator,
         true <- accepted.receipt["authority_epoch"] == epoch,
         {:ok, [["revoked"]]} <-
           query(db, "SELECT status FROM principals WHERE principal_id=?", [Enum.at(binding, 7)]),
         {:ok, [previous]} <-
           query(
             db,
             "SELECT #{Enum.join(@history, ",")} FROM enrollment_review_history WHERE revision=? AND thing_id=?",
             [Enum.at(binding, 9), hd(binding)]
           ),
         {:ok, archived} <- prior(accepted, previous),
         true <- Enum.at(archived, 6) == binding,
         {:ok, [[document, resource, profile, "active"]]} <-
           query(
             db,
             "SELECT document,resource_revision,profile_ref,status FROM enrolled_things WHERE thing_id=?",
             [hd(binding)]
           ),
         true <-
           {Artifact.digest(document), resource, profile} ==
             {Enum.at(archived, 4), Enum.at(archived, 3), Enum.at(archived, 2)} do
      :ok
    else
      _ -> {:error, :review_binding_mismatch}
    end
  end

  def authorize(_, _, _), do: {:error, :review_binding_mismatch}

  @doc "Read-only historical crossing validation; original signatures install no current trust."
  def validate(db) do
    case query(db, "PRAGMA user_version") do
      {:ok, [[22]]} -> validate_current(db)
      {:ok, [[version]]} when version in 7..21 -> :ok
      _ -> corrupt()
    end
  end

  defp validate_current(db) do
    previous = Enum.map_join(@history, ",", &("p." <> &1))
    current = Enum.map_join(@history, ",", &("h." <> &1))

    with {:ok, rows} when length(rows) <= 4_096 <-
           query(db, """
           SELECT #{previous},#{current}
           FROM enrollment_review_history h JOIN enrollment_review_history p
           ON p.thing_id=h.thing_id AND p.revision=(
             SELECT MAX(x.revision) FROM enrollment_review_history x
             WHERE x.thing_id=h.thing_id AND x.revision<h.revision)
           WHERE p.operator_id!=h.operator_id
           ORDER BY h.revision LIMIT 4097
           """),
         :ok <- ownership(db, rows),
         true <- Enum.all?(rows, &crossing?(db, &1)) do
      :ok
    else
      _ -> corrupt()
    end
  end

  defp ownership(_, []), do: :ok
  defp ownership(db, _), do: ControllerWriter.validate(db)

  defp crossing?(db, row) do
    {previous, current} = Enum.split(row, 14)
    target = Enum.at(current, 1)
    revision = hd(current)
    operator = Enum.at(current, 9)

    case query(
           db,
           "SELECT principal_id FROM profile_selection_history WHERE target_id=? AND binding_revision=? AND state='selected'",
           [target, revision]
         ) do
      {:ok, [[^operator]]} -> true
      {:ok, []} -> succession?(db, previous, current)
      _ -> false
    end
  end

  defp succession?(db, previous, current) do
    target = Enum.at(current, 1)
    revision = hd(current)

    with {:ok, accepted} <-
           acceptance(db, "revision<? ORDER BY revision DESC LIMIT 1", [revision]),
         true <- accepted.receipt["principal_id"] == Enum.at(current, 9),
         {:ok, _} <- prior(accepted, previous),
         true <-
           Enum.map([1, 2, 7, 8, 10], &Enum.at(previous, &1)) ==
             Enum.map([1, 2, 7, 8, 10], &Enum.at(current, &1)),
         {:ok, [["thing_enrollment_rereviewed"]]} <-
           query(
             db,
             "SELECT event_type FROM authority_journal WHERE revision=? AND entity_id=?",
             [revision, target]
           ),
         {:ok, [[0]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM controller_retirements WHERE revision>? AND revision<?",
             [accepted.receipt["revision"], revision]
           ),
         {:ok, [[0]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM authority_journal WHERE entity_id=? AND revision>? AND revision<? AND event_type IN ('thing_narrowed','thing_revoked','thing_profile_selected','thing_profile_selection_revoked')",
             [target, accepted.receipt["revision"], revision]
           ) do
      true
    else
      _ -> false
    end
  end

  defp acceptance(db, where, parameters) do
    with {:ok, [row]} <-
           query(
             db,
             "SELECT #{ControllerHistory.acceptance_columns()} FROM controller_acceptances WHERE #{where}",
             parameters
           ),
         {:ok, accepted} <- TransferAcceptanceRecord.audit(row) do
      {:ok, accepted}
    else
      _ -> corrupt()
    end
  end

  defp prior(accepted, previous) do
    target = Enum.at(previous, 1)
    binding = Enum.map([1, 2, 3, 5, 6, 7, 8, 9, 10, 0, 4], &Enum.at(previous, &1))

    with true <- hd(previous) < accepted.receipt["revision"],
         {:ok, ["wotex-home.controller-domains.v2", _, _, records]} <-
           JSON.decode(accepted.domains.document),
         [archived] <- Enum.filter(records, &(hd(&1) == target)),
         true <- Enum.at(archived, 1) == "active" and Enum.at(archived, 6) == binding,
         true <- Enum.any?(Enum.at(archived, 7), fn [values, _basis] -> values == previous end) do
      {:ok, archived}
    else
      _ -> corrupt()
    end
  end

  defp corrupt, do: {:error, :corrupt_enrollment}
end
