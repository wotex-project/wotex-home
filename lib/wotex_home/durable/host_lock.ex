defmodule WotexHome.Durable.HostLock do
  @moduledoc """
  A same-host SQLite advisory ownership gate beside the authority database.

  Exclusive WAL locking stays held for this connection's lifetime. The lock
  database is separate so diagnostic readers can still inspect the main store.
  This does not fence a writer on another host or a process that bypasses Home.
  """

  alias Exqlite.Sqlite3

  @spec acquire(String.t()) :: {:ok, term()} | {:error, atom()}
  def acquire(path) when is_binary(path) and path != "" do
    case Sqlite3.open(path <> ".owner.sqlite") do
      {:ok, db} ->
        case lock(db) do
          :ok ->
            {:ok, db}

          {:error, reason} ->
            _ = Sqlite3.close(db)
            {:error, reason}
        end

      {:error, _reason} ->
        {:error, :host_lock_unavailable}
    end
  end

  def acquire(_path), do: {:error, :host_lock_unavailable}

  @spec release(term()) :: :ok | {:error, term()}
  def release(db), do: Sqlite3.close(db)

  defp lock(db) do
    with :ok <- Sqlite3.execute(db, "PRAGMA busy_timeout=100"),
         :ok <- Sqlite3.execute(db, "PRAGMA locking_mode=EXCLUSIVE"),
         :ok <- Sqlite3.execute(db, "PRAGMA journal_mode=WAL"),
         :ok <- Sqlite3.execute(db, "CREATE TABLE IF NOT EXISTS owner (id INTEGER PRIMARY KEY)"),
         :ok <- Sqlite3.execute(db, "BEGIN IMMEDIATE"),
         :ok <- Sqlite3.execute(db, "INSERT OR IGNORE INTO owner(id) VALUES (1)"),
         :ok <- Sqlite3.execute(db, "COMMIT") do
      :ok
    else
      {:error, "database is locked"} -> {:error, :already_running}
      {:error, _reason} -> {:error, :host_lock_unavailable}
    end
  end
end
