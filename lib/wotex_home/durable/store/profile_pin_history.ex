defmodule WotexHome.Durable.Store.ProfilePinHistory do
  @moduledoc "Bidirectional historical links from profile selections to owning receipt domains."
  alias WotexHome.Durable.Registry
  alias WotexHome.Profiles.LedgerCodec
  alias WotexHome.Rules.AdmissionArtifact
  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]

  @fields ~w(target_id owner_revision artifact_digest projection_digest selection_revision selection_generation trust_revision resource_revision)
  @columns Enum.join(@fields, ",")
  @tables %{
    observation: "profile_observation_pins",
    request: "profile_request_pins",
    rule: "profile_rule_pins",
    qualification: "profile_qualification_pins"
  }

  def validate(db) do
    with true <-
           Enum.all?(@tables, fn {kind, table} ->
             validate_rows(db, kind, table, {0, ""}) == :ok
           end),
         :ok <- missing_observations(db),
         :ok <- missing_requests(db),
         :ok <- missing_rules(db),
         :ok <- missing_qualifications(db) do
      :ok
    else
      _ -> {:error, :corrupt_profile_ledger}
    end
  end

  defp validate_rows(db, kind, table, {after_revision, after_target}) do
    extra = if kind == :request, do: ",principal_id,authority_epoch,operation_id", else: ""

    case query(
           db,
           "SELECT #{@columns}#{extra} FROM #{table} WHERE owner_revision>? OR (owner_revision=? AND target_id>?) ORDER BY owner_revision,target_id LIMIT 100",
           [after_revision, after_revision, after_target]
         ) do
      {:ok, []} ->
        :ok

      {:ok, rows} ->
        if Enum.all?(rows, &valid_pin?(db, kind, &1)),
          do:
            validate_rows(
              db,
              kind,
              table,
              {List.last(rows) |> Enum.at(1), List.last(rows) |> hd()}
            ),
          else: :error

      _ ->
        :error
    end
  end

  defp valid_pin?(db, kind, values) do
    {pin_values, scope} = Enum.split(values, length(@fields))
    pin = Map.new(Enum.zip(@fields, pin_values))

    with {:ok, _} <- LedgerCodec.encode("pin", pin),
         {:ok,
          [[target, raw, projection, generation, trust, resource, document, "selected", next]]} <-
           query(
             db,
             "SELECT h.target_id,h.artifact_digest,h.projection_digest,h.generation,h.trust_revision,h.resource_revision,h.thing_document,h.state,(SELECT MIN(n.revision) FROM profile_selection_history n WHERE n.target_id=h.target_id AND n.revision>h.revision) FROM profile_selection_history h WHERE h.revision=?",
             [pin["selection_revision"]]
           ),
         true <-
           {target, raw, projection, generation, trust, resource} ==
             {pin["target_id"], pin["artifact_digest"], pin["projection_digest"],
              pin["selection_generation"], pin["trust_revision"], pin["resource_revision"]},
         true <-
           pin["owner_revision"] > pin["selection_revision"] and
             (is_nil(next) or pin["owner_revision"] < next),
         {:ok, thing} <- Registry.decode_thing(document),
         :ok <- owner_link(db, kind, pin, scope, thing, document) do
      true
    else
      _ -> false
    end
  end

  defp owner_link(db, :observation, pin, [], thing, _document) do
    with {:ok, [["observation", target, key, profile, evidence]]} <-
           query(
             db,
             "SELECT event_type,thing_id,capability_key,profile_ref,evidence_ref FROM journal WHERE revision=?",
             [pin["owner_revision"]]
           ),
         %{evidence_ref: ^evidence} <- thing.capabilities[key],
         true <- target == thing.id and profile == thing.profile_ref do
      :ok
    else
      _ -> :error
    end
  end

  defp owner_link(db, :request, pin, [principal, epoch, operation], thing, _document) do
    case query(
           db,
           "SELECT r.target_id,r.profile_ref,j.revision FROM request_receipts r JOIN request_journal j USING (principal_id,authority_epoch,operation_id) WHERE r.principal_id=? AND r.authority_epoch=? AND r.operation_id=? AND j.revision=(SELECT MIN(first.revision) FROM request_journal first WHERE first.principal_id=r.principal_id AND first.authority_epoch=r.authority_epoch AND first.operation_id=r.operation_id)",
           [principal, epoch, operation]
         ) do
      {:ok, [[target, profile, revision]]}
      when target == thing.id and profile == thing.profile_ref ->
        if revision == pin["owner_revision"], do: :ok, else: :error

      _ ->
        :error
    end
  end

  defp owner_link(db, :rule, pin, [], thing, document) do
    with {:ok, [[artifact]]} <-
           query(db, "SELECT artifact_document FROM rule_admissions WHERE revision=?", [
             pin["owner_revision"]
           ]),
         {:ok, decoded} <- AdmissionArtifact.decode(artifact),
         true <-
           Enum.any?(
             decoded.resources,
             &(&1["thing_id"] == thing.id and &1["resource_revision"] == pin["resource_revision"] and
                 &1["document"] == document)
           ) do
      :ok
    else
      _ -> :error
    end
  end

  defp owner_link(db, :qualification, pin, [], thing, document) do
    case query(
           db,
           "SELECT thing_id,profile_ref,resource_revision,declaration_document,provenance FROM profile_qualification_history WHERE revision=?",
           [pin["owner_revision"]]
         ) do
      {:ok, [[target, profile, resource, ^document, "guarded_current"]]}
      when target == thing.id and profile == thing.profile_ref ->
        if resource == pin["resource_revision"], do: :ok, else: :error

      _ ->
        :error
    end
  end

  defp owner_link(_, _, _, _, _, _), do: :error

  defp missing_observations(db) do
    zero(
      db,
      "SELECT COUNT(*) FROM journal owner LEFT JOIN profile_observation_pins p ON p.owner_revision=owner.revision WHERE owner.event_type='observation' AND EXISTS (SELECT 1 FROM profile_selection_history h WHERE h.target_id=owner.thing_id AND h.revision<owner.revision) AND p.owner_revision IS NULL"
    )
  end

  defp missing_requests(db) do
    zero(
      db,
      "SELECT COUNT(*) FROM (SELECT r.target_id,r.principal_id,r.authority_epoch,r.operation_id,MIN(j.revision) AS revision FROM request_receipts r JOIN request_journal j USING (principal_id,authority_epoch,operation_id) GROUP BY r.principal_id,r.authority_epoch,r.operation_id) owner LEFT JOIN profile_request_pins p ON p.principal_id=owner.principal_id AND p.authority_epoch=owner.authority_epoch AND p.operation_id=owner.operation_id AND p.owner_revision=owner.revision WHERE EXISTS (SELECT 1 FROM profile_selection_history h WHERE h.target_id=owner.target_id AND h.revision<owner.revision) AND p.owner_revision IS NULL"
    )
  end

  defp missing_rules(db) do
    zero(
      db,
      "SELECT COUNT(*) FROM rule_admissions owner JOIN authority_journal a ON a.revision=owner.revision LEFT JOIN profile_rule_pins p ON p.owner_revision=owner.revision AND p.target_id=a.entity_id WHERE EXISTS (SELECT 1 FROM profile_selection_history h WHERE h.target_id=a.entity_id AND h.revision<owner.revision) AND p.owner_revision IS NULL"
    )
  end

  defp missing_qualifications(db) do
    zero(
      db,
      "SELECT COUNT(*) FROM profile_qualification_history owner LEFT JOIN profile_qualification_pins p ON p.owner_revision=owner.revision WHERE EXISTS (SELECT 1 FROM profile_selection_history h WHERE h.target_id=owner.thing_id AND h.revision<owner.revision) AND p.owner_revision IS NULL"
    )
  end

  defp zero(db, sql) do
    case query(db, sql) do
      {:ok, [[0]]} -> :ok
      _ -> :error
    end
  end
end
