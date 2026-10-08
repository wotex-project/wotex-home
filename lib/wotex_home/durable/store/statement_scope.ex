defmodule WotexHome.Durable.Store.StatementScope do
  @moduledoc """
  Bounded prepared statements borrowed during one synchronous Store call.

  Store opens the scope on its owned connection. Every query still executes
  against SQLite; no rows, authorization decisions or freshness are retained.
  Successful statements are reset and their parameters cleared before reuse.
  Errors discard the statement. All retained statements are released when the
  outer call returns or unwinds, including on exceptions, throws and exits.
  Other connections and processes use the ordinary prepare/release path.
  """

  alias Exqlite.Sqlite3

  @max_statements 256

  @doc false
  def run(db, fun) when is_function(fun, 0) do
    key = key(db)

    if Process.get(key) == nil do
      Process.put(key, %{})

      try do
        fun.()
      after
        statements = Process.delete(key)
        Enum.each(statements, fn {_sql, statement} -> Sqlite3.release(db, statement) end)
      end
    else
      fun.()
    end
  end

  @doc false
  def checkout(db, sql) do
    key = key(db)

    case Process.get(key) do
      nil ->
        Sqlite3.prepare(db, sql)

      statements ->
        case Map.pop(statements, sql) do
          {nil, _} ->
            Sqlite3.prepare(db, sql)

          {statement, remaining} ->
            Process.put(key, remaining)
            {:ok, statement}
        end
    end
  end

  @doc false
  def checkin(db, sql, statement, parameter_count) do
    key = key(db)

    case Process.get(key) do
      statements when is_map(statements) and map_size(statements) < @max_statements ->
        unless Map.has_key?(statements, sql) do
          with :ok <- Sqlite3.reset(statement),
               :ok <- Sqlite3.bind(statement, List.duplicate(nil, parameter_count)) do
            Process.put(key, Map.put(statements, sql, statement))
            :ok
          end
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  @doc false
  def retained?(db, sql, statement),
    do: Map.get(Process.get(key(db), %{}), sql) == statement

  defp key(db), do: {__MODULE__, db}
end
