defmodule WotexHome.Durable.Store.RecoverySnapshot do
  @moduledoc """
  Commits to exact retired-source or quarantine database correspondence.

  `commitment/3` validates the retired controller, mode-specific quarantine
  marker and semantic integrity, then hashes the exact schema objects and table
  content under explicit row/byte ceilings. It returns `{:ok, sha256}` or
  `{:error, :invalid_transfer_snapshot}`. Full schema-38 commitments include the
  external-input tables' exact schema and retained rows, even for an empty domain.
  `match_quarantine/2` returns `:ok` only when the checked quarantine commitment
  equals the selected source commitment; otherwise it returns
  `{:error, :transfer_snapshot_mismatch}`.

  Historical acceptance checks use a separate retained projection to account
  for the transition's intentional fences and withdrawn current state. For
  external inputs, this projection includes operations and history only through
  the source revision and reconstructs each head from that revision's latest
  history. If no input history existed then, it omits the three input tables
  from the retained projection. This compatibility rule does not omit schema
  from the full snapshot commitment or revive the source's installed heads.

  All work is read-only on Store's borrowed SQLite handle: the module neither
  opens a connection, repairs history nor establishes current input qualification,
  physical isolation or destination authority.
  """

  alias Exqlite.Sqlite3
  alias WotexHome.Durable.Store.{ControllerHistory, ControllerWriter, Integrity}
  alias WotexHome.Profiles.Codec
  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]
  @format "wotex-home.controller-snapshot.v1"
  @prefix "WOH15-controller-snapshot-v1\0"
  @max_rows 131_072
  @max_bytes 134_217_728
  @identifier ~r/\A[a-z][a-z0-9_]*\z/

  def commitment(db, mode, limits \\ []) do
    with true <- mode in [:source, :quarantine],
         {:ok, row_limit, byte_limit} <- limits(limits),
         {:ok, [[version]]}
         when version in [21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38] <-
           query(db, "PRAGMA user_version"),
         :ok <- Integrity.validate_snapshot(db),
         {:ok, %{state: "retired"}} <- ControllerWriter.identity(db),
         :ok <- marker(db, mode),
         {:ok, objects} <- objects(db, version),
         tables = for(["table", name, _, _] <- objects, do: name),
         true <- length(tables) in 1..65,
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
         {:ok, [[version]]}
         when version in [21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38] <-
           query(db, "PRAGMA user_version"),
         {:ok, objects} <- objects(db, version),
         {:ok, generations} <- generation_count(db, version, source_revision),
         {:ok, attempts} <- attempt_count(db, version, source_revision),
         {:ok, inputs} <- external_input_count(db, version, source_revision),
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
               "controller_pairings",
               "profile_authoring_objects",
               "profile_authoring_object_operations",
               "profile_authoring_candidates",
               "profile_authoring_reviews",
               "profile_external_inspections",
               "profile_external_artifacts",
               "profile_external_trust_operations",
               "profile_external_target_operations",
               "profile_external_target_history",
               "profile_external_target_current",
               "profile_external_source_bindings",
               "profile_external_observations",
               "profile_authoring_generations",
               "profile_external_observation_current",
               "profile_external_observation_sequences" | tables
             ])
           ),
         tables =
           if(generations == 0,
             do: List.delete(tables, "profile_authoring_generations"),
             else: tables
           ),
         tables =
           if(attempts == 0,
             do: List.delete(tables, "profile_authoring_generation_attempts"),
             else: tables
           ),
         tables =
           if(inputs == 0,
             do: tables -- Map.keys(WotexHome.Durable.Store.ExternalInputs.tables()),
             else: tables
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
                      (table == "controller_pairings" and version < 28) or
                      (table in ~w(profile_authoring_objects profile_authoring_object_operations) and
                         version < 29) or
                      (table == "profile_authoring_generations" and version < 36) or
                      (table == "profile_authoring_candidates" and version < 30) or
                      (table == "profile_authoring_reviews" and version < 31) or
                      (table == "profile_external_inspections" and version < 32) or
                      (table in ~w(profile_external_artifacts profile_external_trust_operations) and
                         version < 33) or
                      (table in ~w(profile_external_target_operations profile_external_target_history profile_external_target_current profile_external_source_bindings) and
                         version < 34) or
                      (table in ~w(profile_external_observations profile_external_observation_current profile_external_observation_sequences) and
                         version < 35) do
                   {:ok, state}
                 else
                   {where, params} =
                     retained_filter(table, source_revision, fresh_principal, version)

                   hash_retained_table(db, table, columns, state, where, params, version)
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

  defp retained_columns(_db, "profile_authoring_objects", version) when version < 29,
    do: {:ok, String.split(WotexHome.Durable.Store.AuthoringObjects.object_columns(), ",")}

  defp retained_columns(_db, "profile_authoring_object_operations", version) when version < 29,
    do: {:ok, String.split(WotexHome.Durable.Store.AuthoringObjects.operation_columns(), ",")}

  defp retained_columns(_db, "profile_authoring_generations", version) when version < 36,
    do: {:ok, String.split(WotexHome.Durable.Store.GenerationPreparations.columns(), ",")}

  defp retained_columns(_db, "profile_authoring_candidates", version) when version < 30,
    do: {:ok, String.split(WotexHome.Durable.Store.AuthoringCandidates.columns(), ",")}

  defp retained_columns(_db, "profile_authoring_reviews", version) when version < 31,
    do: {:ok, String.split(WotexHome.Durable.Store.AuthoringReviews.columns(), ",")}

  defp retained_columns(_db, "profile_external_inspections", version) when version < 32,
    do: {:ok, String.split(WotexHome.Durable.Store.ExternalInspections.columns(), ",")}

  defp retained_columns(_db, "profile_external_artifacts", version) when version < 33,
    do: {:ok, String.split(WotexHome.Durable.Store.ExternalTrustWriter.artifact_columns(), ",")}

  defp retained_columns(_db, "profile_external_trust_operations", version) when version < 33,
    do: {:ok, String.split(WotexHome.Durable.Store.ExternalTrustWriter.columns(), ",")}

  defp retained_columns(_db, table, version)
       when version < 34 and
              table in ~w(profile_external_target_operations profile_external_target_history profile_external_target_current profile_external_source_bindings),
       do: {:ok, WotexHome.Durable.Store.ExternalTargets.tables()[table]}

  defp retained_columns(_db, table, version)
       when version < 35 and
              table in ~w(profile_external_observations profile_external_observation_current profile_external_observation_sequences),
       do: {:ok, WotexHome.Durable.Store.ExternalObservations.tables()[table]}

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

  defp retained_filter("profile_authoring_objects", revision, _, version) when version >= 37,
    do: {" WHERE first_revision<=?", [revision]}

  defp retained_filter("profile_authoring_object_operations", revision, _, version)
       when version >= 37,
       do: {" WHERE revision<=?", [revision]}

  defp retained_filter(table, revision, principal, _),
    do: retained_filter(table, revision, principal)

  defp retained_filter("meta", _, _),
    do:
      {" WHERE key NOT IN ('revision','authority_epoch','rule_generation','maintenance_revision','restore_quarantine')",
       []}

  defp retained_filter("principals", _, fresh), do: {" WHERE principal_id!=?", [fresh]}

  defp retained_filter("profile_authoring_generations", revision, _), do: {"", [revision]}
  defp retained_filter("profile_authoring_generation_attempts", revision, _), do: {"", [revision]}

  defp retained_filter("routine_external_input_current", revision, _), do: {"", [revision]}

  defp retained_filter(table, revision, _)
       when table in ~w(routine_external_input_operations routine_external_input_history),
       do: {" WHERE revision<=?", [revision]}

  defp retained_filter(table, revision, _)
       when table in ~w(authority_journal host_maintenance_operations controller_acceptances),
       do: {" WHERE revision<=?", [revision]}

  defp retained_filter(_, _, _), do: {"", []}

  defp attempt_count(_db, version, _) when version < 37, do: {:ok, 0}

  defp attempt_count(db, _, revision) do
    with {:ok, [[n]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM profile_authoring_generation_attempts WHERE revision<=?",
             [revision]
           ),
         true <- is_integer(n) and n in 0..3072,
         do: {:ok, n},
         else: (_ -> invalid())
  end

  defp generation_count(_db, version, _revision) when version < 36, do: {:ok, 0}

  defp generation_count(db, _version, revision) do
    with {:ok, [[count]]} when count in 0..1024 <-
           query(db, "SELECT COUNT(*) FROM profile_authoring_generations WHERE revision<=?", [
             revision
           ]),
         do: {:ok, count},
         else: (_ -> invalid())
  end

  defp external_input_count(_db, version, _) when version < 38, do: {:ok, 0}

  defp external_input_count(db, _, revision) do
    with {:ok, [[count]]} when count in 0..4096 <-
           query(db, "SELECT COUNT(*) FROM routine_external_input_history WHERE revision<=?", [
             revision
           ]),
         do: {:ok, count},
         else: (_ -> invalid())
  end

  defp marker(db, mode) do
    case {mode, query(db, "SELECT value,typeof(value) FROM meta WHERE key='restore_quarantine'")} do
      {:source, {:ok, []}} -> :ok
      {:quarantine, {:ok, [[1, "integer"]]}} -> :ok
      _ -> invalid()
    end
  end

  defp objects(db, version) do
    ceiling =
      cond do
        version >= 38 -> 69
        version >= 37 -> 65
        true -> 64
      end

    with {:ok, objects} when length(objects) >= 1 and length(objects) <= ceiling <-
           query(db, """
           SELECT type,name,tbl_name,sql FROM sqlite_master WHERE name NOT GLOB 'sqlite_*'
           ORDER BY type COLLATE BINARY,name COLLATE BINARY,tbl_name COLLATE BINARY LIMIT #{ceiling + 1}
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
    hash_relation(db, "\"#{table}\"", columns, state, where, params)
  end

  defp hash_retained_table(db, "routine_external_input_current", columns, state, _, [revision], _) do
    relation = """
    (SELECT h.target_id,h.capability_key,h.revision AS history_revision,
      (SELECT MAX(i.revision) FROM routine_external_input_history i
       WHERE i.target_id=h.target_id AND i.capability_key=h.capability_key AND i.action='install' AND i.revision<=h.revision) AS install_revision,
      h.generation,CASE WHEN h.action='install' THEN 'installed' ELSE 'revoked' END AS state
     FROM routine_external_input_history h
     WHERE h.revision<=? AND NOT EXISTS
       (SELECT 1 FROM routine_external_input_history n
        WHERE n.target_id=h.target_id AND n.capability_key=h.capability_key AND n.revision>h.revision AND n.revision<=?))
    """

    hash_relation(db, relation, columns, state, "", [revision, revision])
  end

  defp hash_retained_table(db, "meta", columns, state, where, params, version)
       when version < 33 do
    hash_relation(
      db,
      "(SELECT key,value FROM meta UNION ALL SELECT 'external_profile_policy_generation',0)",
      columns,
      state,
      where,
      params
    )
  end

  defp hash_retained_table(
         db,
         "profile_authoring_generation_attempts",
         columns,
         state,
         _,
         [revision],
         _
       ) do
    unchanged = columns -- ~w(result_document result_revision)
    unchanged = Enum.map_join(unchanged, ",", &"\"#{&1}\"")

    relation =
      "(SELECT #{unchanged},CASE WHEN result_revision<=? THEN result_document ELSE NULL END AS result_document,CASE WHEN result_revision<=? THEN result_revision ELSE NULL END AS result_revision FROM profile_authoring_generation_attempts WHERE revision<=?)"

    hash_relation(db, relation, columns, state, "", [revision, revision, revision])
  end

  defp hash_retained_table(
         db,
         "profile_authoring_generations",
         columns,
         state,
         _where,
         [revision],
         _
       ) do
    unchanged = Enum.join(columns -- ["cancellation_revision"], ",")

    relation =
      "(SELECT #{unchanged},CASE WHEN cancellation_revision<=? THEN cancellation_revision ELSE NULL END AS cancellation_revision FROM profile_authoring_generations WHERE revision<=?)"

    hash_relation(db, relation, columns, state, "", [revision, revision])
  end

  defp hash_retained_table(db, table, columns, state, where, params, _),
    do: hash_table(db, table, columns, state, where, params)

  defp hash_relation(db, relation, columns, state, where, params) do
    expressions = Enum.flat_map(columns, &["typeof(\"#{&1}\")", "hex(\"#{&1}\")"])
    projection = Enum.join(expressions, ",")
    order = Enum.map_join(expressions, ",", &(&1 <> " COLLATE BINARY"))
    sql = "SELECT #{projection} FROM #{relation}#{where} ORDER BY #{order}"

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
