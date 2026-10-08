defmodule WotexHome.AttemptGuardTest do
  @moduledoc false
  use ExUnit.Case, async: true
  alias Exqlite.Sqlite3
  alias WotexHome.Durable.Store.AttemptGuard
  alias WotexHome.Lifx.DirectPowerLimits

  @max_i64 9_223_372_036_854_775_807
  @limits %{profile: "fixture:attempts", window_ms: 1_000, max_handoffs: 3, min_gap_ms: 100}

  setup do
    {:ok, db} = Sqlite3.open(":memory:")

    :ok =
      Sqlite3.execute(
        db,
        "CREATE TABLE request_execution (effect_domain TEXT, handoff_revision INTEGER, handoff_store_boot_epoch TEXT, handoff_store_monotonic_ms INTEGER, principal_id TEXT, authority_epoch INTEGER, operation_id TEXT)"
      )

    on_exit(fn -> Sqlite3.close(db) end)
    {:ok, db: db}
  end

  test "compiled direct-power policy is closed and bounded" do
    assert DirectPowerLimits.attempts() == %{
             profile: "lifx-direct-power-attempt-v1",
             window_ms: 60_000,
             max_handoffs: 32,
             min_gap_ms: 250
           }

    assert AttemptGuard.valid_limits?(DirectPowerLimits.attempts())
  end

  test "a first attempt is allowed at zero without replenishing a durable counter", %{db: db} do
    for _ <- 1..10, do: assert(:ok == check(db, 0))
    assert :ok == check(db, @max_i64)
  end

  test "spacing has an inclusive allow boundary", %{db: db} do
    insert(db, "light:desk", "store:current", 10)
    assert {:error, :attempt_spacing} == check(db, 109)
    assert :ok == check(db, 110)
  end

  test "the oldest handoff expires exactly at the exclusive window boundary", %{db: db} do
    for ms <- [0, 100, 200], do: insert(db, "light:desk", "store:current", ms)
    assert {:error, :attempt_rate_exhausted} == check(db, 999)
    assert :ok == check(db, 1_000)
    # Reads never reset anything: until expiry all three attempts still count.
    assert {:error, :attempt_rate_exhausted} == check(db, 999)
  end

  test "a whole-Thing policy does not charge a different Thing", %{db: db} do
    for ms <- [0, 100, 200], do: insert(db, "light:hall", "store:current", ms)
    assert :ok == check(db, 201)

    assert {:error, :attempt_rate_exhausted} ==
             AttemptGuard.check(db, "light:hall", {"store:current", 300}, @limits)
  end

  test "claims and other rows without a handoff do not consume attempts", %{db: db} do
    for _ <- 1..100, do: insert(db, "light:desk", nil, nil, nil)
    assert :ok == check(db, 0)
  end

  test "old epochs and untimed history require one complete new-boot window", %{db: db} do
    # Old time can be ahead of, equal to or behind the new clock; never compare it.
    for {epoch, ms} <- [{"store:old", @max_i64}, {"store:old", 0}, {nil, nil}] do
      insert(db, "light:desk", epoch, ms)
    end

    assert {:error, :attempt_history_cold} == check(db, 999)
    assert :ok == check(db, 1_000)
    insert(db, "light:desk", "store:current", 1_000)
    assert {:error, :attempt_spacing} == check(db, 1_099)
    assert :ok == check(db, 1_100)
  end

  test "old history remains scoped to its Thing", %{db: db} do
    insert(db, "light:hall", "store:old", @max_i64)
    assert :ok == check(db, 0)
  end

  test "malformed or future current-epoch history cannot be silently filtered out", %{db: db} do
    for ms <- [nil, -1, 0.5, 101] do
      :ok = Sqlite3.execute(db, "DELETE FROM request_execution")
      insert(db, "light:desk", "store:current", ms)
      assert {:error, :corrupt_receipt} == check(db, 100)
    end
  end

  test "recent query is bounded even with a large retained history", %{db: db} do
    :ok =
      Sqlite3.execute(db, """
      WITH RECURSIVE n(x) AS (VALUES(0) UNION ALL SELECT x+1 FROM n WHERE x<9999)
      INSERT INTO request_execution (effect_domain,handoff_revision,handoff_store_boot_epoch,handoff_store_monotonic_ms) SELECT 'light:desk', x+1, 'store:current', x FROM n;
      """)

    assert {:error, :attempt_rate_exhausted} == check(db, 10_000)
    assert :ok == check(db, 11_000)
    # A malformed row outside the materialized recent page must still fail closed.
    insert(db, "light:desk", "store:current", nil)
    assert {:error, :corrupt_receipt} == check(db, 11_000)
  end

  test "a final repeat excludes only the complete tentative operation identity", %{db: db} do
    own = {"manager:one", 2, "op:one"}
    insert_identity(db, own, "store:current", 250)
    assert :ok = excluding(db, 250, own)
    assert {:error, :attempt_spacing} = check(db, 250)

    for other <- [
          {"manager:other", 2, "op:one"},
          {"manager:one", 1, "op:one"},
          {"manager:one", 2, "op:other"}
        ] do
      insert_identity(db, other, "store:current", 250)
      assert {:error, :attempt_spacing} = excluding(db, 250, own)

      :ok =
        Sqlite3.execute(
          db,
          "DELETE FROM request_execution WHERE rowid=(SELECT MAX(rowid) FROM request_execution)"
        )
    end
  end

  test "other attempts still exhaust the rate after the tentative row is excluded", %{db: db} do
    own = {"manager:one", 1, "op:own"}

    for {ms, op} <- [{0, "op:zero"}, {100, "op:hundred"}, {200, "op:twohundred"}],
        do: insert_identity(db, {"manager:one", 1, op}, "store:current", ms)

    insert_identity(db, own, "store:current", 300)
    assert {:error, :attempt_rate_exhausted} = excluding(db, 300, own)
    assert :ok = excluding(db, 1_000, own)
  end

  test "excluding a tentative row cannot hide old-boot or damaged other history", %{db: db} do
    own = {"manager:one", 1, "op:own"}
    insert_identity(db, own, "store:current", 999)
    insert_identity(db, {"manager:other", 1, "op:own"}, "store:old", 90_000)
    assert {:error, :attempt_history_cold} = excluding(db, 999, own)
    assert :ok = excluding(db, 1_000, own)
    insert_identity(db, {"manager:one", 1, "op:damaged"}, "store:current", nil)
    assert {:error, :corrupt_receipt} = excluding(db, 1_000, own)
  end

  test "invalid exclusion identities fail before reading a connection" do
    for identity <- [
          nil,
          {"bad principal", 1, "op:one"},
          {"manager:one", -1, "op:one"},
          {"manager:one", 1.0, "op:one"},
          {"manager:one", 1, "bad operation"}
        ] do
      assert {:error, :corrupt_receipt} =
               AttemptGuard.check_excluding(
                 :not_a_connection,
                 "light:desk",
                 {"store:current", 0},
                 @limits,
                 identity
               )
    end
  end

  test "invalid inputs fail without asking a connection to grant authority" do
    for limits <- [
          nil,
          %{},
          Map.put(@limits, :unknown, true),
          Map.delete(@limits, :profile),
          %{@limits | profile: "invalid profile"},
          %{@limits | window_ms: 0},
          %{@limits | window_ms: 86_400_001},
          %{@limits | max_handoffs: 0},
          %{@limits | max_handoffs: 1_025},
          %{@limits | min_gap_ms: -1},
          %{@limits | min_gap_ms: 1_001},
          %{@limits | min_gap_ms: 1.0}
        ] do
      refute AttemptGuard.valid_limits?(limits)

      assert {:error, :corrupt_receipt} ==
               AttemptGuard.check(:not_a_connection, "light:desk", {"store:current", 0}, limits)
    end

    for clock <- [
          nil,
          {"invalid epoch", 0},
          {"store:current", -1},
          {"store:current", @max_i64 + 1}
        ] do
      assert {:error, :corrupt_receipt} ==
               AttemptGuard.check(:not_a_connection, "light:desk", clock, @limits)
    end
  end

  test "finite clock histories agree with an independent sliding-window definition", %{db: db} do
    for history <- [[], [0], [0, 100], [0, 100, 200], [100, 500, 900], [0, 1_000, 2_000]],
        now <- [0, 99, 100, 199, 200, 999, 1_000, 1_099, 1_100, 2_000, 3_000] do
      :ok = Sqlite3.execute(db, "DELETE FROM request_execution")
      for ms <- history, do: insert(db, "light:desk", "store:current", ms)
      count = Enum.count(history, &(now - 1_000 < &1 and &1 <= now))

      expected =
        cond do
          Enum.any?(history, &(&1 > now)) -> {:error, :corrupt_receipt}
          count >= 3 -> {:error, :attempt_rate_exhausted}
          history != [] and now < Enum.max(history) + 100 -> {:error, :attempt_spacing}
          true -> :ok
        end

      assert check(db, now) == expected, "history=#{inspect(history)} now=#{now}"
    end
  end

  defp check(db, now), do: AttemptGuard.check(db, "light:desk", {"store:current", now}, @limits)

  defp insert(db, target, epoch, ms, revision \\ 1) do
    {:ok, statement} =
      Sqlite3.prepare(
        db,
        "INSERT INTO request_execution (effect_domain,handoff_revision,handoff_store_boot_epoch,handoff_store_monotonic_ms) VALUES (?, ?, ?, ?)"
      )

    try do
      :ok = Sqlite3.bind(statement, [target, revision, epoch, ms])
      {:ok, []} = Sqlite3.fetch_all(db, statement)
    after
      :ok = Sqlite3.release(db, statement)
    end
  end

  defp excluding(db, now, identity),
    do: AttemptGuard.check_excluding(db, "light:desk", {"store:current", now}, @limits, identity)

  defp insert_identity(db, {principal, epoch, operation}, boot, ms) do
    assert {:ok, []} =
             WotexHome.Durable.Store.SQL.query(
               db,
               "INSERT INTO request_execution VALUES (?,?,?,?,?,?,?)",
               ["light:desk", 1, boot, ms, principal, epoch, operation]
             )
  end
end
