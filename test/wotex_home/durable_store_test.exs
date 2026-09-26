defmodule WotexHome.DurableStoreTest do
  use ExUnit.Case

  alias Exqlite.Sqlite3
  alias WotexHome.Durable.Store
  alias WotexHome.Semantics.{Capability, Observation, Value}

  @capability %{
    "thing_id" => "light:desk",
    "role" => "Light",
    "key" => "power",
    "value_kind" => "boolean",
    "unit" => "none",
    "operations" => ["read", "write"],
    "risk_class" => "ordinary",
    "profile_ref" => "lifx.old:1",
    "evidence_ref" => "fixture:power:1",
    "freshness_ms" => 5_000,
    "constraints" => %{},
    "extensions" => %{}
  }

  @report %{
    "thing_id" => "light:desk",
    "capability_key" => "power",
    "value" => %{"type" => "boolean", "value" => false},
    "quality" => "reported",
    "trust" => "unauthenticated_local",
    "source_epoch" => "device:1",
    "source_sequence" => 7,
    "boot_epoch" => "boot:1",
    "source_time_utc_ms" => nil,
    "received_time_utc_ms" => 1_000_000,
    "received_monotonic_ms" => 100
  }

  setup do
    directory =
      Path.join(System.tmp_dir!(), "wotex-home-store-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    path = Path.join(directory, "home.sqlite")
    on_exit(fn -> File.rm_rf!(directory) end)
    {:ok, path: path}
  end

  test "one observation commits projection, journal and revision together", %{path: path} do
    assert {:ok, capability} = Capability.new(@capability)
    assert {:ok, observation} = Observation.new(@report, capability)
    assert {:ok, store} = Store.start_link(path: path)

    assert {:ok, 0} = Store.revision(store)
    assert :not_found = Store.current(store, "light:desk", "power")
    assert {:ok, 1} = Store.record(store, observation, capability)
    assert {:ok, 1} = Store.revision(store)
    assert {:ok, persisted, 1} = Store.current(store, "light:desk", "power")
    assert persisted == observation
    assert {:duplicate, 1} = Store.record(store, observation, capability)
    assert {:ok, 1} = Store.revision(store)
    :ok = GenServer.stop(store)

    assert {:ok, db} = Sqlite3.open(path, mode: :readonly)
    assert {:ok, statement} = Sqlite3.prepare(db, "SELECT COUNT(*) FROM journal")
    assert {:ok, [[1]]} = Sqlite3.fetch_all(db, statement)
    :ok = Sqlite3.release(db, statement)
    :ok = Sqlite3.close(db)
  end

  test "same sequence with changed content conflicts; older sequence is stale", %{path: path} do
    assert {:ok, capability} = Capability.new(@capability)
    assert {:ok, observation} = Observation.new(@report, capability)

    assert {:ok, changed} =
             Observation.new(
               %{@report | "value" => %{"type" => "boolean", "value" => true}},
               capability
             )

    assert {:ok, older} = Observation.new(%{@report | "source_sequence" => 6}, capability)
    assert {:ok, store} = Store.start_link(path: path)

    assert {:ok, 1} = Store.record(store, observation, capability)
    assert {:error, :sequence_conflict} = Store.record(store, changed, capability)
    assert {:error, :stale_sequence} = Store.record(store, older, capability)
    assert {:ok, 1} = Store.revision(store)
    assert {:ok, ^observation, 1} = Store.current(store, "light:desk", "power")
    :ok = GenServer.stop(store)
  end

  test "restart keeps source identity and refuses silent profile or epoch changes", %{path: path} do
    assert {:ok, capability} = Capability.new(@capability)
    assert {:ok, observation} = Observation.new(@report, capability)
    assert {:ok, first} = Store.start_link(path: path)
    assert {:ok, 1} = Store.record(first, observation, capability)
    :ok = GenServer.stop(first)

    assert {:ok, second} = Store.start_link(path: path)
    assert {:ok, ^observation, 1} = Store.current(second, "light:desk", "power")

    assert {:error, :source_epoch_changed} =
             Store.record(
               second,
               %{observation | source_epoch: "device:2", source_sequence: 8},
               capability
             )

    assert {:ok, newer_profile} = Capability.new(%{@capability | "profile_ref" => "lifx.old:2"})

    assert {:error, :profile_changed} =
             Store.record(second, %{observation | source_sequence: 8}, newer_profile)

    next = %{
      observation
      | source_sequence: 8,
        received_time_utc_ms: 1_000_001,
        received_monotonic_ms: 101,
        value: %Value{kind: :boolean, data: true}
    }

    assert {:ok, 2} = Store.record(second, next, capability)
    assert {:ok, ^next, 2} = Store.current(second, "light:desk", "power")
    :ok = GenServer.stop(second)
  end

  test "in-memory storage is rejected for an authority store" do
    Process.flag(:trap_exit, true)
    assert {:error, :invalid_store_path} = Store.start_link(path: ":memory:")
  end

  test "an unknown on-disk schema is refused instead of overwritten", %{path: path} do
    assert {:ok, db} = Sqlite3.open(path)
    assert :ok = Sqlite3.execute(db, "PRAGMA user_version=2")
    assert :ok = Sqlite3.close(db)

    Process.flag(:trap_exit, true)

    assert {:error, {:store_open_failed, :unsupported_schema_version}} =
             Store.start_link(path: path)
  end
end
