defmodule WotexHome.StoreStatementScopeTest do
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias WotexHome.Durable.Store
  alias WotexHome.Durable.Store.{SQL, StatementScope}

  setup do
    {:ok, db} = Sqlite3.open(":memory:")
    on_exit(fn -> Sqlite3.close(db) end)
    %{db: db}
  end

  test "repeated reads execute against current rows and independently bound values", %{db: db} do
    :ok = Sqlite3.execute(db, "CREATE TABLE facts (id INTEGER PRIMARY KEY, value TEXT)")

    StatementScope.run(db, fn ->
      assert {:ok, []} = SQL.query(db, "INSERT INTO facts VALUES (?,?)", [1, "first"])
      assert {:ok, [["first"]]} = SQL.query(db, "SELECT value FROM facts WHERE id=?", [1])
      statement = retained(db, "SELECT value FROM facts WHERE id=?")
      assert {:ok, []} = SQL.query(db, "UPDATE facts SET value=? WHERE id=?", ["second", 1])
      assert {:ok, [["second"]]} = SQL.query(db, "SELECT value FROM facts WHERE id=?", [1])
      assert retained(db, "SELECT value FROM facts WHERE id=?") == statement
      assert {:ok, []} = SQL.query(db, "SELECT value FROM facts WHERE id=?", [2])
      assert {:ok, [["second"]]} = SQL.query(db, "SELECT value FROM facts WHERE id=?", [1])
    end)
  end

  test "retained statements hold no prior text blob number or null parameter", %{db: db} do
    sql = "SELECT ?,?,?,?,?"
    values = ["private fixture", {:blob, <<0, 255, 1>>}, 77, 1.5, nil]

    statement =
      StatementScope.run(db, fn ->
        assert {:ok, [["private fixture", <<0, 255, 1>>, 77, 1.5, nil]]} =
                 SQL.query(db, sql, values)

        statement = retained(db, sql)
        assert {:row, [nil, nil, nil, nil, nil]} = Sqlite3.step(db, statement)
        assert :ok = Sqlite3.reset(statement)

        assert {:ok, [[nil, 2, "new", <<3>>, 4.5]]} =
                 SQL.query(db, sql, [nil, 2, "new", {:blob, <<3>>}, 4.5])

        assert retained(db, sql) == statement
        statement
      end)

    assert {:error, :invalid_statement} = Sqlite3.step(db, statement)
    assert Process.get({StatementScope, db}) == nil
  end

  test "different connections and processes cannot borrow the caller's statements", %{db: db} do
    {:ok, other} = Sqlite3.open(":memory:")

    try do
      :ok = Sqlite3.execute(db, "CREATE TABLE facts (value); INSERT INTO facts VALUES ('one')")
      :ok = Sqlite3.execute(other, "CREATE TABLE facts (value); INSERT INTO facts VALUES ('two')")

      StatementScope.run(db, fn ->
        assert {:ok, [["one"]]} = SQL.query(db, "SELECT value FROM facts")
        original = retained(db, "SELECT value FROM facts")
        assert {:ok, [["two"]]} = SQL.query(other, "SELECT value FROM facts")
        assert Process.get({StatementScope, other}) == nil

        assert {:ok, [["one"]]} =
                 Task.async(fn ->
                   assert Process.get({StatementScope, db}) == nil
                   result = SQL.query(db, "SELECT value FROM facts")
                   assert Process.get({StatementScope, db}) == nil
                   result
                 end)
                 |> Task.await()

        assert retained(db, "SELECT value FROM facts") == original
      end)
    after
      Sqlite3.close(other)
    end
  end

  test "nested same-connection scopes unwind only at the owning outer call", %{db: db} do
    statement =
      StatementScope.run(db, fn ->
        assert {:ok, [[1]]} = SQL.query(db, "SELECT ?", [1])
        original = retained(db, "SELECT ?")

        StatementScope.run(db, fn ->
          assert {:ok, [[2]]} = SQL.query(db, "SELECT ?", [2])
          assert retained(db, "SELECT ?") == original
        end)

        assert {:ok, [[3]]} = SQL.query(db, "SELECT ?", [3])
        original
      end)

    assert {:error, :invalid_statement} = Sqlite3.step(db, statement)
  end

  test "nested different-connection scopes release only their own statements", %{db: db} do
    {:ok, other} = Sqlite3.open(":memory:")

    try do
      StatementScope.run(db, fn ->
        assert {:ok, [[1]]} = SQL.query(db, "SELECT ?", [1])
        original = retained(db, "SELECT ?")

        inner =
          StatementScope.run(other, fn ->
            assert {:ok, [[2]]} = SQL.query(other, "SELECT ?", [2])
            retained(other, "SELECT ?")
          end)

        assert {:error, :invalid_statement} = Sqlite3.step(other, inner)
        assert Process.get({StatementScope, other}) == nil
        assert retained(db, "SELECT ?") == original
        assert {:ok, [[3]]} = SQL.query(db, "SELECT ?", [3])
      end)
    after
      Sqlite3.close(other)
    end
  end

  test "schema changes and newly installed triggers take effect on reused SQL", %{db: db} do
    :ok = Sqlite3.execute(db, "CREATE TABLE facts (value TEXT)")

    StatementScope.run(db, fn ->
      assert {:ok, []} = SQL.query(db, "SELECT * FROM facts")
      assert {:ok, []} = SQL.query(db, "INSERT INTO facts VALUES (?)", ["before"])
      assert :ok = Sqlite3.execute(db, "ALTER TABLE facts ADD COLUMN changed INTEGER DEFAULT 7")
      assert {:ok, [["before", 7]]} = SQL.query(db, "SELECT * FROM facts")
      assert :ok = Sqlite3.execute(db, "DROP TABLE facts; CREATE TABLE facts (value TEXT)")
      assert {:ok, []} = SQL.query(db, "SELECT * FROM facts")

      assert :ok =
               Sqlite3.execute(
                 db,
                 "CREATE TRIGGER reject_insert BEFORE INSERT ON facts BEGIN SELECT RAISE(ABORT,'fixture fault'); END"
               )

      assert {:error, _} = SQL.query(db, "INSERT INTO facts VALUES (?)", ["refused"])
      assert retained(db, "INSERT INTO facts VALUES (?)") == nil
      assert :ok = Sqlite3.execute(db, "DROP TRIGGER reject_insert")
      assert {:ok, []} = SQL.query(db, "INSERT INTO facts VALUES (?)", ["after"])
      assert {:ok, [["after"]]} = SQL.query(db, "SELECT * FROM facts")
    end)
  end

  test "savepoint and whole-transaction rollback do not preserve tentative rows", %{db: db} do
    :ok = Sqlite3.execute(db, "CREATE TABLE facts (value TEXT)")

    StatementScope.run(db, fn ->
      assert {:ok, :kept} =
               SQL.transaction(db, fn db ->
                 assert {:ok, []} = SQL.query(db, "INSERT INTO facts VALUES (?)", ["kept"])
                 assert {:ok, [["kept"]]} = SQL.query(db, "SELECT value FROM facts")
                 assert :ok = Sqlite3.execute(db, "SAVEPOINT guard")
                 assert {:ok, []} = SQL.query(db, "INSERT INTO facts VALUES (?)", ["tentative"])

                 assert {:ok, [["kept"], ["tentative"]]} =
                          SQL.query(db, "SELECT value FROM facts")

                 assert :ok = Sqlite3.execute(db, "ROLLBACK TO guard; RELEASE guard")
                 assert {:ok, [["kept"]]} = SQL.query(db, "SELECT value FROM facts")
                 {:commit, :kept}
               end)

      assert {:error, :fixture_refusal} =
               SQL.transaction(db, fn db ->
                 assert {:ok, []} = SQL.query(db, "INSERT INTO facts VALUES (?)", ["rolled back"])
                 {:rollback, :fixture_refusal}
               end)

      assert {:ok, [["kept"]]} = SQL.query(db, "SELECT value FROM facts")
    end)
  end

  test "binding failures discard the statement before another query can reuse it", %{db: db} do
    StatementScope.run(db, fn ->
      assert {:ok, [[1, 2]]} = SQL.query(db, "SELECT ?,?", [1, 2])
      original = retained(db, "SELECT ?,?")
      assert_raise ArgumentError, fn -> SQL.query(db, "SELECT ?,?", ["partial", self()]) end
      assert retained(db, "SELECT ?,?") == nil
      assert {:error, :invalid_statement} = Sqlite3.step(db, original)
      assert {:ok, [[nil, 4]]} = SQL.query(db, "SELECT ?,?", [nil, 4])
      assert_raise ArgumentError, fn -> SQL.query(db, "SELECT ?,?", [1]) end
      assert retained(db, "SELECT ?,?") == nil
      assert {:ok, [[5, 6]]} = SQL.query(db, "SELECT ?,?", [5, 6])
      assert {:error, _} = SQL.query(db, "SELECT value FROM absent_table")
      assert {:ok, [[5, 6]]} = SQL.query(db, "SELECT ?,?", [5, 6])
    end)
  end

  for kind <- [:exception, :throw, :exit] do
    test "#{kind} releases every statement while preserving the original failure", %{db: db} do
      parent = self()

      fun = fn ->
        StatementScope.run(db, fn ->
          assert {:ok, [[1]]} = SQL.query(db, "SELECT ?", [1])
          send(parent, {:retained_statement, retained(db, "SELECT ?")})

          case unquote(kind) do
            :exception -> raise ArgumentError, "fixture failure"
            :throw -> throw(:fixture_failure)
            :exit -> exit(:fixture_failure)
          end
        end)
      end

      case unquote(kind) do
        :exception -> assert_raise ArgumentError, "fixture failure", fun
        :throw -> assert catch_throw(fun.()) == :fixture_failure
        :exit -> assert catch_exit(fun.()) == :fixture_failure
      end

      assert_receive {:retained_statement, statement}
      assert {:error, :invalid_statement} = Sqlite3.step(db, statement)
      assert Process.get({StatementScope, db}) == nil
      assert {:ok, [[2]]} = SQL.query(db, "SELECT ?", [2])
      assert Process.get({StatementScope, db}) == nil
    end
  end

  test "statement capacity is bounded and uncached SQL still executes", %{db: db} do
    statements =
      StatementScope.run(db, fn ->
        for value <- 1..300 do
          assert {:ok, [[^value]]} = SQL.query(db, "SELECT #{value}")
        end

        statements = Process.get({StatementScope, db})
        assert map_size(statements) == 256
        assert {:ok, [["uncached"]]} = SQL.query(db, "SELECT ?", ["uncached"])
        assert map_size(Process.get({StatementScope, db})) == 256
        Map.values(statements)
      end)

    assert Process.get({StatementScope, db}) == nil
    assert Enum.all?(statements, &(Sqlite3.step(db, &1) == {:error, :invalid_statement}))
    assert :ok = Sqlite3.close(db)
  end

  test "real Store replies leave no statement scope in the owner's process" do
    directory =
      Path.join(System.tmp_dir!(), "woh-statements-#{System.unique_integer([:positive])}")

    File.mkdir!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    store = start_supervised!({Store, path: Path.join(directory, "home.sqlite")})
    assert {:ok, %{writable: true}} = Store.health(store)
    assert {:ok, 0} = Store.revision(store)
    assert {:error, :target_unavailable} = Store.revoke_thing(store, "light:absent")
    assert {:ok, 0} = Store.revision(store)
    assert {:dictionary, dictionary} = Process.info(store, :dictionary)
    refute Enum.any?(dictionary, fn {key, _} -> match?({StatementScope, _}, key) end)
    assert :ok = stop_supervised(Store)
  end

  defp retained(db, sql), do: Map.get(Process.get({StatementScope, db}, %{}), sql)
end
