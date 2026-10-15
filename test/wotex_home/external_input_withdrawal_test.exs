Code.require_file(Path.expand("../support/external_input_history_fixture.exs", __DIR__))

defmodule WotexHome.ExternalInputWithdrawalTest do
  @moduledoc false

  use ExUnit.Case
  alias Exqlite.Sqlite3
  alias WotexHome.Durable.Store
  alias WotexHome.Durable.Store.{ExternalInputs, Integrity, Journal, Schema, SQL}
  alias WotexHome.ExternalInputHistoryFixture, as: F
  alias WotexHome.Rules.ExternalInputOperation, as: Operation

  setup tags do
    temporary = if :os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()

    root =
      Path.join(
        temporary,
        "woh-input-withdrawal-" <> Base.encode16(:crypto.strong_rand_bytes(12))
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    path = Path.join(root, "home.sqlite")
    {:ok, db} = Sqlite3.open(path)
    :ok = File.chmod(path, 0o600)
    :ok = Sqlite3.execute(db, "PRAGMA foreign_keys=ON")
    :ok = Schema.initialize(db, &Integrity.validate_schema_version/2)
    credential = :crypto.strong_rand_bytes(32)
    slots = if tags[:input_quota], do: Enum.map(1..160, &"slot:#{&1}"), else: ["sample", "second"]
    vector = F.seed(db, credential, slots)
    assert :ok = Integrity.validate_snapshot(db)
    %{root: root, path: path, db: db, credential: credential, v: vector}
  end

  test "exact reserve includes every installed outcome and can exclude one replacement", c do
    on_exit(fn -> Sqlite3.close(c.db) end)

    assert {:ok, [[one], [two]]} =
             SQL.query(
               c.db,
               "SELECT outcome_document FROM routine_external_input_history ORDER BY capability_key"
             )

    documents =
      for doc <- [one, two] do
        {:ok, outcome} = Operation.decode_outcome(doc)
        {:ok, withdrawal} = Operation.encode_outcome(Map.put(outcome, "action", "withdraw"))
        withdrawal
      end

    assert {:ok, %{history_rows: 2, bytes: bytes}} = ExternalInputs.retirement_reserve(c.db)
    assert bytes == Enum.sum(Enum.map(documents, &byte_size/1))

    assert {:ok, %{history_rows: 1, bytes: remaining}} =
             ExternalInputs.retirement_reserve(c.db, {"sensor:independent", "sample"})

    assert remaining == byte_size(List.last(documents))

    assert {:ok, %{history_rows: 2, bytes: ^bytes}} =
             ExternalInputs.retirement_reserve(c.db, {"absent", "sample"})

    assert {:error, :invalid_external_input} = ExternalInputs.retirement_reserve(c.db, %{})
    assert :ok = ExternalInputs.capacity(c.db, 0, 2, 0, bytes)
    assert :ok = Integrity.validate_snapshot(c.db)
  end

  test "a full lexical batch uses the first loss and repeats without another revision", c do
    on_exit(fn -> Sqlite3.close(c.db) end)

    assert {:ok, :ok} =
             SQL.transaction(c.db, fn db ->
               :ok =
                 Journal.authority_event(
                   db,
                   23,
                   "host_maintenance_started",
                   "synthetic:domain-only"
                 )

               :ok = Journal.authority_event(db, 24, "principal_revoked", "operator:entry")

               case ExternalInputs.withdraw_invalidated(db) do
                 :ok -> {:commit, :ok}
                 {:error, reason} -> {:rollback, reason}
               end
             end)

    assert :ok = ExternalInputs.validate(c.db)

    assert {:ok, [["sample", 25, 2, 23], ["second", 26, 2, 23]]} =
             SQL.query(
               c.db,
               "SELECT capability_key,revision,generation,cause_revision FROM routine_external_input_history WHERE action='withdraw' ORDER BY revision"
             )

    assert {:ok, [["sample", 21, "revoked"], ["second", 22, "revoked"]]} =
             SQL.query(
               c.db,
               "SELECT capability_key,install_revision,state FROM routine_external_input_current ORDER BY capability_key"
             )

    assert {:ok, %{history_rows: 0, bytes: 0}} = ExternalInputs.retirement_reserve(c.db)
    assert :ok = ExternalInputs.withdraw_invalidated(c.db)
    assert {:ok, [[26]]} = SQL.query(c.db, "SELECT value FROM meta WHERE key='revision'")

    assert {:ok, [[2]]} =
             SQL.query(c.db, "SELECT COUNT(*) FROM routine_external_input_operations")
  end

  test "actual maintenance retires before later controller retirement and keeps its original receipt",
       c do
    c = start_store(c)
    {:ok, transfer, _} = Store.provision_transfer(c.store)
    {:ok, before} = Store.revision(c.store)

    assert {:ok, barrier} =
             Store.begin_maintenance(c.store, c.credential, 1, "maint:inputs", before)

    assert {:ok, final} = Store.revision(c.store)
    assert final == barrier.revision + 2

    assert {:ok, ^barrier} =
             Store.maintenance_operation_status(c.store, c.credential, 1, "maint:inputs")

    assert {:ok, ^barrier} =
             Store.begin_maintenance(c.store, c.credential, 1, "maint:inputs", before)

    assert {:ok, [[0]]} =
             SQL.query(
               c.db,
               "SELECT COUNT(*) FROM routine_external_input_current WHERE state='installed'"
             )

    input = %{
      "authority_epoch" => 1,
      "operation_id" => "retire:inputs",
      "expected_revision" => final,
      "destination_owner_id" => String.duplicate("a", 64)
    }

    assert {:ok, retired} = Store.retire_controller(c.store, transfer, input)
    assert retired["revision"] == final + 1
    assert {:ok, revision} = Store.revision(c.store)
    assert revision == retired["revision"]
    assert :ok = Integrity.validate_snapshot(c.db)
  end

  test "actual author grant removal and regrant cannot revive an input", c do
    c = start_store(c)
    assert {:ok, _} = Store.revoke_target_grant(c.store, "operator:entry", "sensor:independent")

    assert {:ok, [[0]]} =
             SQL.query(
               c.db,
               "SELECT COUNT(*) FROM routine_external_input_current WHERE state='installed'"
             )

    assert {:ok, _, _} =
             Store.grant_target_and_rotate(c.store, "operator:entry", "sensor:independent")

    assert {:ok, [[0]]} =
             SQL.query(
               c.db,
               "SELECT COUNT(*) FROM routine_external_input_current WHERE state='installed'"
             )

    assert {:ok, [[2]]} =
             SQL.query(c.db, "SELECT COUNT(*) FROM routine_external_input_operations")

    assert :ok = Integrity.validate_snapshot(c.db)
  end

  test "failure on the second withdrawal rolls back the cause, earlier head and every revision",
       c do
    :ok =
      Sqlite3.execute(
        c.db,
        "CREATE TRIGGER reject_second_input_withdrawal BEFORE INSERT ON authority_journal WHEN NEW.event_type='external_input_withdrawn' AND (SELECT COUNT(*) FROM routine_external_input_history WHERE action='withdraw')>0 BEGIN SELECT RAISE(ABORT,'injected withdrawal failure'); END"
      )

    c = start_store(c)
    before = retained(c.db)

    assert {:error, :store_unavailable} =
             Store.begin_maintenance(c.store, c.credential, 1, "maint:failure", 22)

    assert retained(c.db) == before
    refute :sys.get_state(c.store).writable
    assert :ok = Integrity.validate_snapshot(c.db)
  end

  test "actual principal revocation retires the complete dependent input set", c do
    c = start_store(c)
    assert {:ok, _} = Store.revoke_principal(c.store, "operator:entry")

    assert {:ok, [["revoked"]]} =
             SQL.query(c.db, "SELECT status FROM principals WHERE principal_id='operator:entry'")

    assert {:ok, [["sample", "revoked"], ["second", "revoked"]]} =
             SQL.query(
               c.db,
               "SELECT capability_key,state FROM routine_external_input_current ORDER BY capability_key"
             )

    assert {:ok, [[2]]} =
             SQL.query(c.db, "SELECT COUNT(*) FROM routine_external_input_operations")

    assert :ok = Integrity.validate_snapshot(c.db)
  end

  test "a counter-exhausted retirement refuses the owning change as policy without partial loss",
       c do
    :ok =
      Journal.authority_event(
        c.db,
        9_223_372_036_854_775_806,
        "synthetic_counter_boundary",
        "fixture:counter"
      )

    assert :ok = Integrity.validate_snapshot(c.db)
    c = start_store(c)
    before = retained(c.db)

    assert {:error, :revision_exhausted} =
             Store.revoke_target_grant(c.store, "operator:entry", "sensor:independent")

    assert retained(c.db) == before
    assert :sys.get_state(c.store).writable
    assert :ok = Integrity.validate_snapshot(c.db)
  end

  @tag input_quota: true, timeout: 60_000
  test "legacy actual-byte quota cannot commit a partially fitting withdrawal batch", c do
    on_exit(fn -> Sqlite3.close(c.db) end)
    assert :ok = ExternalInputs.capacity(c.db, 0, 0, 0, 0)
    assert {:ok, reserve} = ExternalInputs.retirement_reserve(c.db)
    assert reserve.history_rows == 160

    assert {:error, :external_input_capacity} =
             ExternalInputs.capacity(c.db, 0, reserve.history_rows, 0, reserve.bytes)

    before = retained(c.db)

    assert {:error, :external_input_capacity} =
             SQL.transaction(c.db, fn db ->
               {:ok, revision} = Journal.next_revision(db)
               :ok = Journal.authority_event(db, revision, "principal_revoked", "operator:entry")

               case ExternalInputs.withdraw_invalidated(db) do
                 :ok -> {:commit, :ok}
                 {:error, reason} -> {:rollback, reason}
               end
             end)

    assert retained(c.db) == before
    assert :ok = ExternalInputs.validate(c.db)
  end

  test "ending maintenance and restarting Store never reactivate retired input heads", c do
    c = start_store(c)
    {:ok, barrier} = Store.begin_maintenance(c.store, c.credential, 1, "maint:restart", 22)
    {:ok, revision} = Store.revision(c.store)

    {:ok, _} =
      Store.end_maintenance(
        c.store,
        c.credential,
        1,
        "maint:end",
        revision,
        barrier.begin_revision
      )

    before = retained(c.db)

    assert {:ok, [["revoked"], ["revoked"]]} =
             SQL.query(
               c.db,
               "SELECT state FROM routine_external_input_current ORDER BY capability_key"
             )

    stop_supervised!(Store)
    store = start_supervised!({Store, path: c.path})
    db = :sys.get_state(store).db
    assert {:ok, ^barrier} = Store.begin_maintenance(store, c.credential, 1, "maint:restart", 22)
    assert retained(db) == before
    assert :ok = Integrity.validate_snapshot(db)
  end

  defp start_store(c) do
    :ok = Sqlite3.close(c.db)
    store = start_supervised!({Store, path: c.path})
    Map.merge(c, %{store: store, db: :sys.get_state(store).db})
  end

  defp retained(db) do
    for table <- [
          "meta",
          "principals",
          "principal_targets",
          "host_maintenance_operations",
          "routine_external_input_operations",
          "routine_external_input_history",
          "routine_external_input_current",
          "authority_journal"
        ],
        into: %{} do
      {:ok, rows} = SQL.query(db, "SELECT * FROM " <> table <> " ORDER BY rowid")
      {table, rows}
    end
  end
end
