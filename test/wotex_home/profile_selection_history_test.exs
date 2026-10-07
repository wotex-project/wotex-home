Code.require_file(Path.expand("../support/portable_profile_fixture.exs", __DIR__))

defmodule WotexHome.ProfileSelectionHistoryTest do
  use ExUnit.Case
  alias Exqlite.Sqlite3
  alias WotexHome.Durable.{Registry, Store}
  alias WotexHome.Durable.Store.{ProfilePinHistory, ProfilePins, ProfileSelectionHistory, SQL}
  alias WotexHome.Lifx.ProfileCatalogue
  alias WotexHome.Profiles.{Artifact, Custody, Operation, Review}

  @artifact_fields ~w(artifact_digest id version metadata_document projection_document projection_digest binding registry_digest first_approval_revision)
  @operation_fields ~w(principal_id authority_epoch operation_id action input_document input_digest expected_revision artifact_digest final_revision changed_targets invalidated_requests unknown_outcomes previous_trust_revision trust_generation policy_generation)

  setup do
    c = WotexHome.Test.PortableProfileFixture.context()
    temporary = System.tmp_dir!()

    temporary =
      if String.starts_with?(temporary, "/var/"), do: "/private" <> temporary, else: temporary

    directory =
      Path.join(temporary, "woh-selection-history-#{System.unique_integer([:positive])}")

    root = Path.join(directory, "profiles")
    File.mkdir_p!(root)
    File.chmod!(directory, 0o700)
    File.chmod!(root, 0o700)
    custody = start_supervised!({Custody, root: root})
    path = Path.join(directory, "home.sqlite")
    store = start_supervised!({Store, path: path, profile_custody: custody})

    {:ok, operator, 1} =
      Store.provision_principal(
        store,
        c.basis["principal_id"],
        ["enroll:review", "profile:manage"],
        []
      )

    {:ok, package} = ProfileCatalogue.fetch(c.current.profile_ref, c.current.id)

    selection = %{
      "operator_id" => c.basis["principal_id"],
      "candidate_ref" => c.input["candidate_ref"],
      "stable_id" => c.basis["stable_id"],
      "profile_ref" => package.profile.id <> ":" <> package.profile.version,
      "qualification_ref" => package.profile.qualification_ref,
      "method" => "legacy_tofu",
      "review_ref" => "review:compiled"
    }

    assert {:ok, 2} =
             Store.commit_enrollment(
               store,
               operator,
               c.evidence.candidates,
               c.evidence.interview,
               [package.profile],
               c.current,
               selection
             )

    {:ok, maintainer, 3} =
      Store.provision_principal(store, "maintainer:fixture", ["host:maintain"], [])

    {:ok, _} = Store.begin_maintenance(store, maintainer, 1, "maint:fixture", 3)
    {:ok, expected} = Store.revision(store)
    {:ok, _} = Custody.stage(custody, c.artifact.bytes)

    approve = %{
      "action" => "approve",
      "authority_epoch" => 1,
      "operation_id" => "profile:approve",
      "expected_revision" => expected,
      "artifact_digest" => c.artifact.digest,
      "expected_trust_revision" => 0
    }

    {:ok, approved} = Store.profile_change(store, operator, approve)
    {:ok, status} = Store.maintenance_status(store, maintainer)

    input = %{
      c.input
      | "expected_revision" => approved.final_revision,
        "expected_trust_revision" => approved.final_revision,
        "expected_rule_generation" => status.rule_generation
    }

    {:ok, :new, basis} = Store.profile_selection_basis(store, operator, input)
    {:ok, review} = Review.new(basis, c.artifact, c.evidence, input, c.runtime)
    stop_supervised(Store)
    {:ok, db} = Sqlite3.open(path)
    # Correspondence fixture only. The public writer still refuses selection;
    # constructing these rows is neither activation nor physical evidence.
    binding = input["expected_revision"] + 1
    selected = binding + 1
    final = selected + 1
    {:ok, document} = Registry.encode_thing(review.thing)
    e = review.enrollment

    assert {:ok, []} =
             SQL.query(
               db,
               "INSERT INTO enrollment_review_history VALUES (?,?,?,?,2,?,?,?,?,?,?,?,?,?)",
               [
                 binding,
                 e.thing_id,
                 e.stable_id,
                 e.identity_digest,
                 e.candidate_ref,
                 e.review_ref,
                 e.method,
                 e.qualification_ref,
                 e.operator_id,
                 e.profile_ref,
                 review.interview.manufacturer,
                 review.interview.model,
                 review.interview.firmware
               ]
             )

    assert {:ok, []} =
             SQL.query(
               db,
               "UPDATE enrollment_bindings SET identity_digest=?,candidate_ref=?,review_ref=?,qualification_ref=?,operator_id=?,profile_ref=?,revision=? WHERE thing_id=?",
               [
                 e.identity_digest,
                 e.candidate_ref,
                 e.review_ref,
                 e.qualification_ref,
                 e.operator_id,
                 e.profile_ref,
                 binding,
                 e.thing_id
               ]
             )

    assert {:ok, []} =
             SQL.query(
               db,
               "UPDATE enrolled_things SET profile_ref=?,document=?,resource_revision=1 WHERE thing_id=?",
               [e.profile_ref, document, e.thing_id]
             )

    for {revision, event, entity} <- [
          {binding, "thing_enrollment_rereviewed", e.thing_id},
          {selected, "thing_profile_selected", e.thing_id},
          {final, "portable_profile_selection_committed", c.artifact.digest}
        ] do
      assert {:ok, []} =
               SQL.query(db, "INSERT INTO authority_journal VALUES (?,?,?)", [
                 revision,
                 event,
                 entity
               ])
    end

    {:ok, input_document} = Operation.encode(input)

    parent = %{
      "principal_id" => e.operator_id,
      "authority_epoch" => 1,
      "operation_id" => input["operation_id"],
      "action" => "select",
      "input_document" => input_document,
      "input_digest" => Artifact.digest(input_document),
      "expected_revision" => input["expected_revision"],
      "artifact_digest" => c.artifact.digest,
      "final_revision" => final,
      "changed_targets" => 1,
      "invalidated_requests" => 0,
      "unknown_outcomes" => 0,
      "previous_trust_revision" => approved.final_revision,
      "trust_generation" => 1,
      "policy_generation" => 1
    }

    insert(db, "profile_operations", @operation_fields, parent)

    row = %{
      "target_id" => e.thing_id,
      "generation" => 1,
      "principal_id" => e.operator_id,
      "authority_epoch" => 1,
      "operation_id" => input["operation_id"],
      "previous_selection_revision" => 0,
      "previous_resource_revision" => 0,
      "previous_binding_revision" => 2,
      "artifact_digest" => c.artifact.digest,
      "projection_digest" => c.artifact.projection_digest,
      "trust_revision" => approved.final_revision,
      "state" => "selected",
      "resource_revision" => 1,
      "binding_revision" => binding,
      "runtime_digest" => c.runtime,
      "review_document" => review.document,
      "thing_document" => document,
      "revision" => selected
    }

    insert(db, "profile_selection_history", ProfileSelectionHistory.fields(), row)

    assert {:ok, []} =
             SQL.query(db, "INSERT INTO profile_current VALUES (?,1,?,'selected')", [
               e.thing_id,
               selected
             ])

    assert {:ok, []} = SQL.query(db, "UPDATE meta SET value=? WHERE key='revision'", [final])

    artifacts =
      SQL.query(db, "SELECT #{Enum.join(@artifact_fields, ",")} FROM portable_profiles")
      |> maps(@artifact_fields)
      |> Map.new(&{&1["artifact_digest"], &1})

    operations =
      SQL.query(db, "SELECT #{Enum.join(@operation_fields, ",")} FROM profile_operations")
      |> maps(@operation_fields)
      |> Map.new(&{{&1["principal_id"], &1["authority_epoch"], &1["operation_id"]}, &1})

    on_exit(fn ->
      Sqlite3.close(db)
      File.rm_rf!(directory)
    end)

    %{
      db: db,
      artifacts: artifacts,
      operations: operations,
      revision: final,
      row: row,
      review: review
    }
  end

  test "exact selection review chain and current pointer retain correspondence", c do
    assert :ok = validate(c)
    assert :ok = ProfilePinHistory.validate(c.db)
  end

  for damage <- [
        "UPDATE profile_current SET generation=2",
        "UPDATE profile_selection_history SET generation=2",
        "UPDATE profile_selection_history SET trust_revision=1",
        "UPDATE profile_selection_history SET resource_revision=2",
        "UPDATE profile_selection_history SET review_document=''",
        "UPDATE enrollment_review_history SET identity_digest='ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff' WHERE review_ref='review:fixture'",
        "UPDATE enrolled_things SET resource_revision=2",
        "DELETE FROM authority_journal WHERE event_type='thing_profile_selected'"
      ] do
    @damage damage
    test "damaged original link is rejected: #{damage}", c do
      assert :ok = validate(c)
      assert :ok = Sqlite3.execute(c.db, @damage)
      assert {:error, :corrupt_profile_ledger} = validate(c)
    end
  end

  test "a scoped parent receipt cannot claim another target count", c do
    key = {c.row["principal_id"], 1, c.row["operation_id"]}
    operations = Map.update!(c.operations, key, &Map.put(&1, "changed_targets", 0))
    assert {:error, :corrupt_profile_ledger} = validate(%{c | operations: operations})
  end

  test "artifact revocation cannot omit a selected target's barrier", c do
    selected_key = {c.row["principal_id"], 1, c.row["operation_id"]}
    selected = c.operations[selected_key]

    input = %{
      "action" => "revoke",
      "authority_epoch" => 1,
      "operation_id" => "profile:bad:revoke",
      "expected_revision" => c.revision,
      "artifact_digest" => c.row["artifact_digest"],
      "expected_trust_revision" => c.row["trust_revision"]
    }

    {:ok, document} = Operation.encode(input)

    parent =
      Map.merge(selected, %{
        "action" => "revoke",
        "operation_id" => input["operation_id"],
        "input_document" => document,
        "input_digest" => Artifact.digest(document),
        "expected_revision" => c.revision,
        "final_revision" => c.revision + 1,
        "changed_targets" => 0,
        "trust_generation" => 2,
        "policy_generation" => 2
      })

    insert(c.db, "profile_operations", @operation_fields, parent)

    assert {:ok, []} =
             SQL.query(
               c.db,
               "INSERT INTO authority_journal VALUES (?,'portable_profile_revoked',?)",
               [parent["final_revision"], parent["artifact_digest"]]
             )

    operations =
      Map.put(c.operations, {parent["principal_id"], 1, parent["operation_id"]}, parent)

    assert {:error, :corrupt_profile_ledger} =
             validate(%{c | operations: operations, revision: c.revision + 1})
  end

  test "observation owners require one exact retained pin and cannot inherit earlier generations",
       c do
    owner = c.revision + 1
    thing = c.review.thing
    power = thing.capabilities["power"]

    assert {:ok, []} =
             SQL.query(
               c.db,
               "INSERT INTO journal VALUES (?,'observation',?,'power',?,?,'source:fixture',1,'boot:fixture',NULL,1000,10,'reported','unauthenticated_local','boolean','0',NULL,'store:fixture',10)",
               [owner, thing.id, thing.profile_ref, power.evidence_ref]
             )

    assert {:error, :corrupt_profile_ledger} = ProfilePinHistory.validate(c.db)

    pin = %{
      "target_id" => thing.id,
      "artifact_digest" => c.row["artifact_digest"],
      "projection_digest" => c.row["projection_digest"],
      "selection_revision" => c.row["revision"],
      "selection_generation" => 1,
      "trust_revision" => c.row["trust_revision"],
      "resource_revision" => 1
    }

    assert :ok = ProfilePins.retain(c.db, :observation, pin, owner, nil)
    assert :ok = ProfilePinHistory.validate(c.db)

    assert {:error, :corrupt_profile_ledger} =
             ProfilePins.retain(c.db, :observation, pin, owner, nil)

    assert {:ok, []} =
             SQL.query(c.db, "UPDATE profile_observation_pins SET selection_generation=2")

    assert {:error, :corrupt_profile_ledger} = ProfilePinHistory.validate(c.db)
  end

  defp validate(c),
    do: ProfileSelectionHistory.validate(c.db, c.artifacts, c.operations, c.revision, 1)

  defp maps({:ok, rows}, fields), do: Enum.map(rows, &Map.new(Enum.zip(fields, &1)))

  defp insert(db, table, fields, row) do
    assert {:ok, []} =
             SQL.query(
               db,
               "INSERT INTO #{table} (#{Enum.join(fields, ",")}) VALUES (#{Enum.map_join(fields, ",", fn _ -> "?" end)})",
               Enum.map(fields, &row[&1])
             )
  end
end
