defmodule WotexHome.Durable.StoreComponentsTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias WotexHome.Durable.Store.Journal
  alias WotexHome.Durable.Store.ObservationCodec
  alias WotexHome.Durable.Store.RequestLedger
  alias WotexHome.Durable.Store.SQL
  alias WotexHome.Semantics.Value

  test "observation values round-trip through the closed SQLite representation" do
    values = [
      nil,
      %Value{kind: :boolean, data: true},
      %Value{kind: :boolean, data: false},
      %Value{kind: :fraction, data: 500_000},
      %Value{kind: :kelvin, data: 3_500},
      %Value{kind: :hsv, data: {120_000, 800_000}},
      %Value{kind: :xy, data: {250_000, 300_000}},
      %Value{kind: :smoke_state, data: "alarm"}
    ]

    for value <- values do
      {kind, a, b} = ObservationCodec.encode_value(value)
      assert {:ok, ^value} = ObservationCodec.decode_value(kind, a, b)
    end
  end

  test "malformed persisted observations fail closed instead of raising" do
    assert {:error, :corrupt_value} = ObservationCodec.decode_value("kelvin", nil, nil)
    assert {:error, :corrupt_value} = ObservationCodec.decode_value("xy", "1", nil)

    assert {:error, :corrupt_value} =
             ObservationCodec.decode_current("light:desk", "power", ["truncated"])
  end

  test "authority and request journals share one checked revision sequence" do
    {:ok, db} = Sqlite3.open(":memory:")
    on_exit(fn -> Sqlite3.close(db) end)

    :ok = Sqlite3.execute(db, "CREATE TABLE meta (key TEXT PRIMARY KEY, value INTEGER NOT NULL)")

    :ok =
      Sqlite3.execute(
        db,
        "CREATE TABLE authority_journal (revision INTEGER PRIMARY KEY, event_type TEXT, entity_id TEXT)"
      )

    :ok =
      Sqlite3.execute(
        db,
        "CREATE TABLE request_journal (revision INTEGER PRIMARY KEY, principal_id TEXT, authority_epoch INTEGER, operation_id TEXT, state TEXT, reason TEXT)"
      )

    assert {:ok, []} = SQL.query(db, "INSERT INTO meta VALUES ('revision', 0)")
    assert {:ok, 1} = Journal.next_revision(db)
    assert :ok = Journal.authority_event(db, 1, "principal_provisioned", "operator:1")
    assert {:ok, 2} = Journal.next_revision(db)

    assert :ok =
             Journal.request_event(
               db,
               2,
               "operator:1",
               1,
               "operation:1",
               "held",
               nil
             )

    assert {:ok, [[2]]} = SQL.query(db, "SELECT value FROM meta WHERE key = 'revision'")

    assert {:ok, [[1, "principal_provisioned", "operator:1"]]} =
             SQL.query(db, "SELECT * FROM authority_journal")

    assert {:ok, [[2, "operator:1", 1, "operation:1", "held", nil]]} =
             SQL.query(db, "SELECT * FROM request_journal")

    assert {:error, :invalid_request_event} =
             Journal.request_event(db, 3, "operator:1", -1, "operation:2", "held", nil)

    assert {:ok, [[2]]} = SQL.query(db, "SELECT value FROM meta WHERE key = 'revision'")
  end

  test "truncated and exhausted receipt rows fail closed" do
    assert {:error, :corrupt_receipt} =
             RequestLedger.decode_receipt("operator:1", 1, "operation:1", ["truncated"])

    row = [
      0,
      "light:desk",
      "power",
      "boolean",
      1,
      nil,
      "lifx:1",
      "held",
      nil,
      9_223_372_036_854_775_808
    ]

    assert {:error, :corrupt_receipt} =
             RequestLedger.decode_receipt("operator:1", 1, "operation:1", row)
  end
end
