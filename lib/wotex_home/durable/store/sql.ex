defmodule WotexHome.Durable.Store.SQL do
  @moduledoc """
  Stateless SQLite primitives used inside the single Store owner.

  This module never opens, closes or retains a database handle. Keeping those
  responsibilities in `WotexHome.Durable.Store` preserves the one-writer
  invariant while making transaction mechanics reusable and independently
  testable.

  Store may reuse compiled statements inside one synchronous call scope. Each
  query still binds and executes afresh, and the scope releases its statements
  before Store replies. Callers outside that scope prepare and release normally.
  """

  alias Exqlite.Sqlite3
  alias WotexHome.Durable.Store.StatementScope

  @spec transaction(Sqlite3.db(), (Sqlite3.db() -> tuple())) ::
          {:ok, term()} | {:error, term()}
  def transaction(db, fun) when is_function(fun, 1) do
    case Sqlite3.execute(db, "BEGIN IMMEDIATE") do
      :ok -> finish_transaction(db, fun.(db))
      {:error, reason} -> {:error, reason}
    end
  end

  @spec query(Sqlite3.db(), String.t(), list()) :: {:ok, list()} | {:error, term()}
  def query(db, sql, params \\ []) when is_binary(sql) and is_list(params) do
    case StatementScope.checkout(db, sql) do
      {:ok, statement} ->
        try do
          with :ok <- Sqlite3.bind(statement, params),
               {:ok, rows} <- Sqlite3.fetch_all(db, statement),
               :ok <- StatementScope.checkin(db, sql, statement, length(params)) do
            {:ok, rows}
          end
        after
          unless StatementScope.retained?(db, sql, statement),
            do: Sqlite3.release(db, statement)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finish_transaction(db, {:commit, result}) do
    case Sqlite3.execute(db, "COMMIT") do
      :ok ->
        {:ok, result}

      {:error, reason} ->
        _ = Sqlite3.execute(db, "ROLLBACK")
        {:error, reason}
    end
  end

  defp finish_transaction(db, {:rollback, {:duplicate, _} = duplicate}) do
    _ = Sqlite3.execute(db, "ROLLBACK")
    {:ok, duplicate}
  end

  defp finish_transaction(db, {:rollback, {:unchanged, result}}) do
    _ = Sqlite3.execute(db, "ROLLBACK")
    {:ok, result}
  end

  defp finish_transaction(db, {:rollback, reason}) do
    _ = Sqlite3.execute(db, "ROLLBACK")
    {:error, reason}
  end
end
