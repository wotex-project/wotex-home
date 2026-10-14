defmodule WotexHome.ExternalObservationBoundsTest do
  @moduledoc false

  use ExUnit.Case, async: true
  alias Exqlite.Sqlite3
  alias WotexHome.Durable.Store.{ExternalObservations, SQL}

  setup do
    {:ok, db} = Sqlite3.open(":memory:")
    on_exit(fn -> Sqlite3.close(db) end)

    # Only the aggregate guard is under test here, not valid authority history.
    :ok =
      Sqlite3.execute(db, """
      CREATE TABLE profile_external_observations (input_document TEXT, outcome_document TEXT);
      CREATE TABLE profile_external_observation_sequences (sequence TEXT);
      """)

    %{db: db}
  end

  test "row and cursor budgets are inclusive and original recovery charges no row", %{db: db} do
    :ok =
      Sqlite3.execute(db, """
      WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<4095)
      INSERT INTO profile_external_observations SELECT '', '' FROM n;
      """)

    assert :ok = ExternalObservations.capacity(db, 0, 0)
    :ok = Sqlite3.execute(db, "INSERT INTO profile_external_observations VALUES ('','')")
    assert {:error, :external_observation_capacity} = ExternalObservations.capacity(db, 0, 0)
    assert :ok = ExternalObservations.capacity(db, 0, 0, false)
    :ok = Sqlite3.execute(db, "INSERT INTO profile_external_observations VALUES ('','')")

    assert {:error, :external_observation_capacity} =
             ExternalObservations.capacity(db, 0, 0, false)

    :ok =
      Sqlite3.execute(db, """
      DELETE FROM profile_external_observations;
      WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<8192)
      INSERT INTO profile_external_observation_sequences SELECT CAST(i AS TEXT) FROM n;
      """)

    assert :ok = ExternalObservations.capacity(db, 0, 0)

    :ok =
      Sqlite3.execute(db, "INSERT INTO profile_external_observation_sequences VALUES ('8193')")

    assert {:error, :external_observation_capacity} = ExternalObservations.capacity(db, 0, 0)
  end

  for {field, bound} <- [{"input_document", 2_097_152}, {"outcome_document", 16_777_216}] do
    test "#{field} budget counts actual UTF-8 bytes and refuses one byte over", %{db: db} do
      field = unquote(field)
      bound = unquote(bound)
      document = String.duplicate("é", div(bound, 2))
      assert byte_size(document) == bound
      assert String.length(document) == div(bound, 2)
      other = if field == "input_document", do: "outcome_document", else: "input_document"

      assert {:ok, []} =
               SQL.query(
                 db,
                 "INSERT INTO profile_external_observations (#{field},#{other}) VALUES (?,?)",
                 [document, ""]
               )

      assert :ok = ExternalObservations.capacity(db, 0, 0, false)
      args = if field == "input_document", do: {1, 0}, else: {0, 1}

      assert {:error, :external_observation_capacity} =
               ExternalObservations.capacity(db, elem(args, 0), elem(args, 1))

      assert {:ok, []} =
               SQL.query(db, "UPDATE profile_external_observations SET #{field}=?", [
                 document <> "x"
               ])

      assert {:error, :external_observation_capacity} =
               ExternalObservations.capacity(db, 0, 0, false)
    end
  end

  test "preview uses the original instant and expires exactly at the freshness boundary" do
    scope = preview_scope()

    for age <- [0, 999] do
      preview = ExternalObservations.preview(scope, nil, {"boot:1", 10 + age})
      assert preview["freshness"] == "fresh" and preview["reason"] == nil
      assert preview["age_ms"] == age and preview["remaining_ms"] == 1000 - age
      assert preview["value"] == scope.report.value
    end

    for age <- [1000, 1001] do
      preview = ExternalObservations.preview(scope, nil, {"boot:1", 10 + age})
      assert preview["freshness"] == "stale" and preview["reason"] == "expired"
      assert preview["value"] == nil and preview["remaining_ms"] == 0
    end

    for clock <- [{"boot:2", 10}, {"boot:1", 9}] do
      preview = ExternalObservations.preview(scope, nil, clock)
      assert preview["reason"] == "old_store_boot" and preview["age_ms"] == nil
      assert preview["value"] == nil and preview["remaining_ms"] == 0
    end
  end

  test "null sequence and discontinuous previews never expose a known coordinate" do
    for {changes, reason} <- [
          {%{"sequence" => nil}, "missing_sequence"},
          {%{"continuity" => "gap"}, "gap"},
          {%{"continuity" => "retained"}, "retained"},
          {%{"continuity" => "replayed"}, "replayed"},
          {%{"quality" => "invalid"}, "invalid"}
        ] do
      scope = preview_scope()
      scope = put_in(scope.report.value, Map.merge(scope.report.value, changes))
      preview = ExternalObservations.preview(scope, nil, {"boot:1", 10})
      assert preview["freshness"] == "unknown" and preview["reason"] == reason
      assert preview["value"] == nil and preview["remaining_ms"] == 0
    end
  end

  defp preview_scope do
    %{
      target_id: "sensor:1",
      capability_key: "sample",
      revision: 8,
      epoch: 1,
      current: %{selection_revision: 7, resource_revision: 0},
      capability: %{freshness_ms: 1000},
      report: %{
        receipt: %{
          "revision" => 8,
          "selection_revision" => 7,
          "store_boot_epoch" => "boot:1",
          "received_store_ms" => 10
        },
        value: %{"quality" => "usable", "sequence" => "1", "continuity" => "baseline"}
      }
    }
  end
end
