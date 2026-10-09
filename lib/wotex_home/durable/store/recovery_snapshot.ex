defmodule WotexHome.Durable.Store.RecoverySnapshot do
  @moduledoc "Read-only full retired source/quarantine correspondence on a borrowed SQLite handle."
  alias Exqlite.Sqlite3
  alias WotexHome.Durable.Store.{ControllerHistory, ControllerWriter, Integrity}
  alias WotexHome.Profiles.Codec
  import WotexHome.Durable.Store.SQL, only: [query: 2]
  @format "wotex-home.controller-snapshot.v1"
  @prefix "WOH15-controller-snapshot-v1\0"
  @max_rows 131_072
  @max_bytes 134_217_728
  @identifier ~r/\A[a-z][a-z_]*\z/

  def commitment(db, mode, limits \\ []) do
    with true <- mode in [:source, :quarantine],
         {:ok, row_limit, byte_limit} <- limits(limits),
         {:ok, [[version]]} when version in [21, 22, 23, 24, 25, 26, 27, 28] <-
           query(db, "PRAGMA user_version"),
         :ok <- Integrity.validate_snapshot(db),
         {:ok, %{state: "retired"}} <- ControllerWriter.identity(db),
         :ok <- marker(db, mode),
         {:ok, objects} <- objects(db),
         tables = for(["table", name, _, _] <- objects, do: name),
         true <- length(tables) in 1..64,
         state = %{
           hash: :crypto.hash_init(:sha256),
           bytes: 0,
           rows: 0,
           row_limit: row_limit,
           byte_limit: byte_limit
         },
         {:ok, state} <- append(state, @prefix),
         {:ok, state} <- document(state, [@format, version, objects]),
         {:ok, state} <- hash_tables(db, tables, state) do
      {:ok, :crypto.hash_final(state.hash) |> Base.encode16(case: :lower)}
    else
      _ -> invalid()
    end
  end

  def match_quarantine(db, expected) do
    with true <- Codec.digest?(expected),
         {:ok, ^expected} <- commitment(db, :quarantine) do
      :ok
    else
      _ -> {:error, :transfer_snapshot_mismatch}
    end
  end

  @doc false
  def retained_commitment(db, source_revision, fresh_principal) do
    with true <-
           is_integer(source_revision) and source_revision > 0 and
             WotexHome.Id.valid?(fresh_principal),
         {:ok, [[version]]} when version in [21, 22, 23, 24, 25, 26, 27, 28] <-
           query(db, "PRAGMA user_version"),
         {:ok, objects} <- objects(db),
         tables =
           for(
             ["table", name, _, _] <- objects,
             name not in ~w(observation_current principal_targets source_epoch_grants operator_override_leases),
             do: name
           ),
         tables =
           Enum.sort(
             Enum.uniq([
               "controller_acceptances",
               "native_target_operations",
               "schedule_admissions",
               "schedule_lifecycle_operations",
               "schedule_considerations",
               "schedule_watermarks",
               "schedule_effect_operations",
               "controller_pairings" | tables
             ])
           ),
         state = %{
           hash: :crypto.hash_init(:sha256),
           bytes: 0,
           rows: 0,
           row_limit: @max_rows,
           byte_limit: @max_bytes
         },
         {:ok, state} <- append(state, "WOH15-controller-retention-v1\0"),
         {:ok, state} <-
           Enum.reduce_while(tables, {:ok, state}, fn table, {:ok, state} ->
             result =
               with {:ok, columns} <- retained_columns(db, table, version),
                    {:ok, state} <- document(state, [table, columns]) do
                 if (table == "controller_acceptances" and version == 21) or
                      (table == "native_target_operations" and version < 23) or
                      (table == "schedule_admissions" and version < 24) or
                      (table == "schedule_lifecycle_operations" and version < 25) or
                      (table in ~w(schedule_considerations schedule_watermarks) and version < 26) or
                      (table == "schedule_effect_operations" and version < 27) or
                      (table == "controller_pairings" and version < 28) do
                   {:ok, state}
                 else
                   {where, params} = retained_filter(table, source_revision, fresh_principal)
                   hash_table(db, table, columns, state, where, params)
                 end
               end

             case result do
               {:ok, state} -> {:cont, {:ok, state}}
               _ -> {:halt, invalid()}
             end
           end) do
      {:ok, :crypto.hash_final(state.hash) |> Base.encode16(case: :lower)}
    else
      _ -> invalid()
    end
  end

  defp retained_columns(_db, "controller_acceptances", 21),
    do: {:ok, String.split(ControllerHistory.acceptance_columns(), ",")}

  defp retained_columns(_db, "native_target_operations", version) when version < 23,
    do: {:ok, String.split(WotexHome.Durable.Store.NativeTargetHistory.columns(), ",")}

  defp retained_columns(_db, "schedule_admissions", version) when version < 24,
    do: {:ok, String.split(WotexHome.Durable.Store.ScheduleWriter.columns(), ",")}

  defp retained_columns(_db, "schedule_lifecycle_operations", version) when version < 25,
    do: {:ok, String.split(WotexHome.Durable.Store.ScheduleLifecycle.columns(), ",")}

  defp retained_columns(_db, "schedule_considerations", version) when version < 26,
    do: {:ok, String.split(WotexHome.Durable.Store.ScheduleOccurrences.columns(), ",")}

  defp retained_columns(_db, "schedule_watermarks", version) when version < 26,
    do: {:ok, String.split(WotexHome.Durable.Store.ScheduleOccurrences.cursor_columns(), ",")}

  defp retained_columns(_db, "schedule_effect_operations", version) when version < 27,
    do: {:ok, String.split(WotexHome.Durable.Store.ScheduleEffects.columns(), ",")}

  defp retained_columns(_db, "controller_pairings", version) when version < 28,
    do: {:ok, String.split(WotexHome.Durable.Store.PairingWriter.columns(), ",")}

  defp retained_columns(db, table, _) do
    with {:ok, columns} <- columns(db, table) do
      excluded =
        case table do
          "principals" -> ["status"]
          "profile_qualifications" -> ["status"]
          "controller_identity" -> ~w(owner_id state head_revision)
          _ -> []
        end

      {:ok, columns -- excluded}
    end
  end

  defp retained_filter("meta", _, _),
    do:
      {" WHERE key NOT IN ('revision','authority_epoch','rule_generation','maintenance_revision','restore_quarantine')",
       []}

  defp retained_filter("principals", _, fresh), do: {" WHERE principal_id!=?", [fresh]}

  defp retained_filter(table, revision, _)
       when table in ~w(authority_journal host_maintenance_operations controller_acceptances),
       do: {" WHERE revision<=?", [revision]}

  defp retained_filter(_, _, _), do: {"", []}

  defp marker(db, mode) do
    case {mode, query(db, "SELECT value,typeof(value) FROM meta WHERE key='restore_quarantine'")} do
      {:source, {:ok, []}} -> :ok
      {:quarantine, {:ok, [[1, "integer"]]}} -> :ok
      _ -> invalid()
    end
  end

  defp objects(db) do
    with {:ok, objects} when length(objects) in 1..64 <-
           query(db, """
           SELECT type,name,tbl_name,sql FROM sqlite_master WHERE name NOT GLOB 'sqlite_*'
           ORDER BY type COLLATE BINARY,name COLLATE BINARY,tbl_name COLLATE BINARY LIMIT 65
           """),
         true <-
           Enum.all?(objects, fn
             [type, name, table, sql] ->
               type in ~w(table index view trigger) and identifier?(name) and identifier?(table) and
                 is_binary(sql) and byte_size(sql) in 1..65_536

             _ ->
               false
           end) do
      {:ok, objects}
    else
      _ -> invalid()
    end
  end

  defp hash_tables(db, tables, state) do
    tables
    |> Enum.sort()
    |> Enum.reduce_while({:ok, state}, fn table, {:ok, state} ->
      with {:ok, columns} <- columns(db, table),
           {:ok, state} <- document(state, [table, columns]),
           {:ok, state} <- hash_table(db, table, columns, state) do
        {:cont, {:ok, state}}
      else
        _ -> {:halt, invalid()}
      end
    end)
  end

  defp columns(db, table) do
    with {:ok, rows} when length(rows) in 1..64 <- query(db, "PRAGMA table_info(\"#{table}\")"),
         columns = Enum.map(rows, &Enum.at(&1, 1)),
         true <- Enum.all?(columns, &identifier?/1),
         true <- Enum.uniq(columns) == columns do
      {:ok, columns}
    else
      _ -> invalid()
    end
  end

  defp hash_table(db, table, columns, state) do
    where = if table == "meta", do: " WHERE key!='restore_quarantine'", else: ""
    hash_table(db, table, columns, state, where, [])
  end

  defp hash_table(db, table, columns, state, where, params) do
    expressions = Enum.flat_map(columns, &["typeof(\"#{&1}\")", "hex(\"#{&1}\")"])
    projection = Enum.join(expressions, ",")
    order = Enum.map_join(expressions, ",", &(&1 <> " COLLATE BINARY"))
    sql = "SELECT #{projection} FROM \"#{table}\"#{where} ORDER BY #{order}"

    with {:ok, statement} <- Sqlite3.prepare(db, sql) do
      try do
        with :ok <- Sqlite3.bind(statement, params), do: chunks(db, statement, state)
      after
        Sqlite3.release(db, statement)
      end
    else
      _ -> invalid()
    end
  end

  defp chunks(db, statement, state) do
    case Sqlite3.multi_step(db, statement, 256) do
      {:rows, rows} ->
        with {:ok, state} <- hash_rows(rows, state), do: chunks(db, statement, state)

      {:done, rows} ->
        hash_rows(rows, state)

      _ ->
        invalid()
    end
  end

  defp hash_rows(rows, state) do
    Enum.reduce_while(rows, {:ok, state}, fn row, {:ok, state} ->
      cells = Enum.chunk_every(row, 2)

      with true <- state.rows < state.row_limit,
           true <-
             Enum.all?(cells, fn
               [type, bytes] ->
                 type in ~w(null integer text blob) and is_binary(bytes) and
                   rem(byte_size(bytes), 2) == 0 and bytes =~ ~r/\A[0-9A-F]*\z/

               _ ->
                 false
             end),
           {:ok, state} <- document(%{state | rows: state.rows + 1}, cells) do
        {:cont, {:ok, state}}
      else
        _ -> {:halt, invalid()}
      end
    end)
  end

  defp document(state, value), do: append(state, JSON.encode!(value) <> <<0>>)

  defp append(state, bytes) do
    count = state.bytes + byte_size(bytes)

    if count <= state.byte_limit,
      do: {:ok, %{state | hash: :crypto.hash_update(state.hash, bytes), bytes: count}},
      else: invalid()
  end

  defp limits(options) when is_list(options) do
    if Keyword.keyword?(options) and
         Enum.uniq(Keyword.keys(options)) == Keyword.keys(options) and
         Enum.all?(Keyword.keys(options), &(&1 in [:max_rows, :max_bytes])) do
      rows = Keyword.get(options, :max_rows, @max_rows)
      bytes = Keyword.get(options, :max_bytes, @max_bytes)

      if is_integer(rows) and rows in 1..@max_rows and is_integer(bytes) and
           bytes in 1..@max_bytes,
         do: {:ok, rows, bytes},
         else: invalid()
    else
      invalid()
    end
  end

  defp limits(_), do: invalid()
  defp identifier?(value), do: is_binary(value) and Regex.match?(@identifier, value)
  defp invalid, do: {:error, :invalid_transfer_snapshot}
end
