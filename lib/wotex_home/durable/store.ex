defmodule WotexHome.Durable.Store do
  @moduledoc """
  Single-process SQLite writer for the initial observation projection and journal.

  This store has no command outbox and never dispatches physical effects. The
  host must provide an owned database path and supervise this process. A later
  authority service must add process locking, command receipts and recovery
  gates before any mutating driver can be connected.
  """

  use GenServer

  alias Exqlite.Sqlite3
  alias WotexHome.Id
  alias WotexHome.Semantics.{Capability, Observation, Value}

  @schema """
  CREATE TABLE IF NOT EXISTS meta (
    key TEXT PRIMARY KEY,
    value INTEGER NOT NULL
  );
  INSERT OR IGNORE INTO meta(key, value) VALUES ('revision', 0);
  CREATE TABLE IF NOT EXISTS observation_current (
    thing_id TEXT NOT NULL,
    capability_key TEXT NOT NULL,
    profile_ref TEXT NOT NULL,
    evidence_ref TEXT NOT NULL,
    source_epoch TEXT NOT NULL,
    source_sequence INTEGER NOT NULL,
    boot_epoch TEXT NOT NULL,
    source_time_utc_ms INTEGER,
    received_time_utc_ms INTEGER NOT NULL,
    received_monotonic_ms INTEGER NOT NULL,
    quality TEXT NOT NULL,
    trust TEXT NOT NULL,
    value_kind TEXT,
    value_a TEXT,
    value_b TEXT,
    revision INTEGER NOT NULL,
    PRIMARY KEY (thing_id, capability_key)
  );
  CREATE TABLE IF NOT EXISTS journal (
    revision INTEGER PRIMARY KEY,
    event_type TEXT NOT NULL,
    thing_id TEXT NOT NULL,
    capability_key TEXT NOT NULL,
    profile_ref TEXT NOT NULL,
    evidence_ref TEXT NOT NULL,
    source_epoch TEXT NOT NULL,
    source_sequence INTEGER NOT NULL,
    boot_epoch TEXT NOT NULL,
    source_time_utc_ms INTEGER,
    received_time_utc_ms INTEGER NOT NULL,
    received_monotonic_ms INTEGER NOT NULL,
    quality TEXT NOT NULL,
    trust TEXT NOT NULL,
    value_kind TEXT,
    value_a TEXT,
    value_b TEXT
  );
  """

  @select_current """
  SELECT profile_ref, evidence_ref, source_epoch, source_sequence, boot_epoch,
         source_time_utc_ms, received_time_utc_ms, received_monotonic_ms,
         quality, trust, value_kind, value_a, value_b, revision
  FROM observation_current WHERE thing_id = ? AND capability_key = ?
  """

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    path = Keyword.fetch!(opts, :path)
    GenServer.start_link(__MODULE__, path, Keyword.take(opts, [:name]))
  end

  @spec record(GenServer.server(), Observation.t(), Capability.t()) ::
          {:ok, non_neg_integer()} | {:duplicate, non_neg_integer()} | {:error, atom()}
  def record(server, observation, capability),
    do: GenServer.call(server, {:record, observation, capability})

  @spec current(GenServer.server(), String.t(), String.t()) ::
          {:ok, Observation.t(), non_neg_integer()} | :not_found | {:error, atom()}
  def current(server, thing_id, capability_key),
    do: GenServer.call(server, {:current, thing_id, capability_key})

  @spec revision(GenServer.server()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def revision(server), do: GenServer.call(server, :revision)

  @impl true
  def init(path) when is_binary(path) and path != "" and path != ":memory:" do
    case Sqlite3.open(path) do
      {:ok, db} ->
        case boot(db) do
          :ok ->
            {:ok, %{db: db, writable: true}}

          {:error, reason} ->
            _ = Sqlite3.close(db)
            {:stop, {:store_open_failed, reason}}
        end

      {:error, reason} ->
        {:stop, {:store_open_failed, reason}}
    end
  end

  def init(_path), do: {:stop, :invalid_store_path}

  defp boot(db) do
    with :ok <- configure(db),
         :ok <- initialize_schema(db),
         :ok <- integrity(db) do
      :ok
    end
  end

  @impl true
  def terminate(_reason, %{db: db}), do: Sqlite3.close(db)

  @impl true
  def handle_call({:record, _observation, _capability}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  def handle_call(
        {:record, %Observation{} = observation, %Capability{} = capability},
        _from,
        state
      ) do
    if valid_pair?(observation, capability) do
      case transaction(state.db, fn db -> record_tx(db, observation, capability) end) do
        {:ok, result} -> {:reply, result, state}
        {:error, {:policy, reason}} -> {:reply, {:error, reason}, state}
        {:error, _reason} -> {:reply, {:error, :store_unavailable}, %{state | writable: false}}
      end
    else
      {:reply, {:error, :invalid_observation}, state}
    end
  end

  def handle_call({:record, _observation, _capability}, _from, state),
    do: {:reply, {:error, :invalid_observation}, state}

  def handle_call({:current, thing_id, capability_key}, _from, state) do
    result =
      if Id.valid?(thing_id) and Id.valid?(capability_key) do
        case query(state.db, @select_current, [thing_id, capability_key]) do
          {:ok, []} -> :not_found
          {:ok, [row]} -> decode_current(thing_id, capability_key, row)
          {:error, _reason} -> {:error, :store_unavailable}
        end
      else
        {:error, :invalid_id}
      end

    {:reply, result, read_health(state, result)}
  end

  def handle_call(:revision, _from, state) do
    result =
      case query(state.db, "SELECT value FROM meta WHERE key = 'revision'") do
        {:ok, [[revision]]} -> {:ok, revision}
        _ -> {:error, :store_unavailable}
      end

    {:reply, result, read_health(state, result)}
  end

  defp read_health(state, {:error, :store_unavailable}), do: %{state | writable: false}
  defp read_health(state, {:error, :corrupt_value}), do: %{state | writable: false}
  defp read_health(state, _result), do: state

  defp valid_pair?(observation, capability) do
    Observation.valid?(observation, capability)
  end

  defp record_tx(db, observation, capability) do
    with {:ok, rows} <-
           query(db, @select_current, [observation.thing_id, observation.capability_key]),
         :ok <- check_previous(rows, observation, capability) do
      insert_record(db, observation, capability)
    else
      {:duplicate, revision} -> {:rollback, {:duplicate, revision}}
      {:reject, reason} -> {:rollback, {:policy, reason}}
      {:error, reason} -> {:rollback, reason}
    end
  end

  defp check_previous([], _observation, _capability), do: :ok

  defp check_previous([row], observation, capability) do
    [profile_ref, evidence_ref, source_epoch, source_sequence | _rest] = row

    cond do
      profile_ref != capability.profile_ref or evidence_ref != capability.evidence_ref ->
        {:reject, :profile_changed}

      source_epoch != observation.source_epoch ->
        {:reject, :source_epoch_changed}

      source_sequence > observation.source_sequence ->
        {:reject, :stale_sequence}

      source_sequence == observation.source_sequence ->
        if same_source_event?(row, observation),
          do: {:duplicate, List.last(row)},
          else: {:reject, :sequence_conflict}

      true ->
        :ok
    end
  end

  defp same_source_event?(row, observation) do
    [_, _, _, _, _, source_time, _, _, quality, trust, kind, a, b, _] = row
    {new_kind, new_a, new_b} = encode_value(observation.value)

    source_time == observation.source_time_utc_ms and quality == observation.quality and
      trust == observation.trust and {kind, a, b} == {new_kind, new_a, new_b}
  end

  defp insert_record(db, observation, capability) do
    with {:ok, [[revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         new_revision = revision + 1,
         {kind, a, b} = encode_value(observation.value),
         params = fields(observation, capability, kind, a, b),
         {:ok, []} <-
           query(
             db,
             "INSERT INTO journal VALUES (?, 'observation', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
             [new_revision | params]
           ),
         {:ok, []} <-
           query(
             db,
             "INSERT INTO observation_current VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(thing_id, capability_key) DO UPDATE SET profile_ref=excluded.profile_ref, evidence_ref=excluded.evidence_ref, source_epoch=excluded.source_epoch, source_sequence=excluded.source_sequence, boot_epoch=excluded.boot_epoch, source_time_utc_ms=excluded.source_time_utc_ms, received_time_utc_ms=excluded.received_time_utc_ms, received_monotonic_ms=excluded.received_monotonic_ms, quality=excluded.quality, trust=excluded.trust, value_kind=excluded.value_kind, value_a=excluded.value_a, value_b=excluded.value_b, revision=excluded.revision",
             params ++ [new_revision]
           ),
         {:ok, []} <-
           query(db, "UPDATE meta SET value = ? WHERE key = 'revision'", [new_revision]) do
      {:commit, {:ok, new_revision}}
    else
      {:error, reason} -> {:rollback, reason}
      _ -> {:rollback, :unexpected_store_result}
    end
  end

  defp fields(observation, capability, kind, a, b) do
    [
      observation.thing_id,
      observation.capability_key,
      capability.profile_ref,
      capability.evidence_ref,
      observation.source_epoch,
      observation.source_sequence,
      observation.boot_epoch,
      observation.source_time_utc_ms,
      observation.received_time_utc_ms,
      observation.received_monotonic_ms,
      observation.quality,
      observation.trust,
      kind,
      a,
      b
    ]
  end

  defp encode_value(nil), do: {nil, nil, nil}

  defp encode_value(%Value{kind: :boolean, data: value}),
    do: {"boolean", if(value, do: "1", else: "0"), nil}

  defp encode_value(%Value{kind: :fraction, data: value}),
    do: {"fraction", Integer.to_string(value), nil}

  defp encode_value(%Value{kind: :kelvin, data: value}),
    do: {"kelvin", Integer.to_string(value), nil}

  defp encode_value(%Value{kind: :hsv, data: {hue, saturation}}),
    do: {"hsv", Integer.to_string(hue), Integer.to_string(saturation)}

  defp encode_value(%Value{kind: :xy, data: {x, y}}),
    do: {"xy", Integer.to_string(x), Integer.to_string(y)}

  defp encode_value(%Value{kind: :smoke_state, data: value}), do: {"smoke_state", value, nil}

  defp decode_current(thing_id, capability_key, row) do
    [
      profile_ref,
      evidence_ref,
      source_epoch,
      source_sequence,
      boot_epoch,
      source_time,
      received_time,
      received_mono,
      quality,
      trust,
      kind,
      a,
      b,
      revision
    ] = row

    with {:ok, value} <- decode_value(kind, a, b),
         true <- is_nil(value) or Value.valid?(value) do
      observation = %Observation{
        thing_id: thing_id,
        capability_key: capability_key,
        value: value,
        quality: quality,
        trust: trust,
        source_epoch: source_epoch,
        source_sequence: source_sequence,
        boot_epoch: boot_epoch,
        source_time_utc_ms: source_time,
        received_time_utc_ms: received_time,
        received_monotonic_ms: received_mono
      }

      # Profile/evidence identity is checked before each write and remains in
      # the row. The read API currently returns only the observation/revision.
      _ = {profile_ref, evidence_ref}
      {:ok, observation, revision}
    else
      _ -> {:error, :corrupt_value}
    end
  end

  defp decode_value(nil, nil, nil), do: {:ok, nil}
  defp decode_value("boolean", "1", nil), do: {:ok, %Value{kind: :boolean, data: true}}
  defp decode_value("boolean", "0", nil), do: {:ok, %Value{kind: :boolean, data: false}}

  defp decode_value("smoke_state", value, nil) when value in ["clear", "alarm"],
    do: {:ok, %Value{kind: :smoke_state, data: value}}

  defp decode_value(kind, a, nil) when kind in ["fraction", "kelvin"] do
    case Integer.parse(a) do
      {value, ""} ->
        {:ok, %Value{kind: if(kind == "fraction", do: :fraction, else: :kelvin), data: value}}

      _ ->
        {:error, :corrupt_value}
    end
  end

  defp decode_value(kind, a, b) when kind in ["hsv", "xy"] do
    with {first, ""} <- Integer.parse(a),
         {second, ""} <- Integer.parse(b) do
      {:ok, %Value{kind: if(kind == "hsv", do: :hsv, else: :xy), data: {first, second}}}
    else
      _ -> {:error, :corrupt_value}
    end
  end

  defp decode_value(_kind, _a, _b), do: {:error, :corrupt_value}

  defp configure(db) do
    with {:ok, [["wal"]]} <- query(db, "PRAGMA journal_mode=WAL"),
         {:ok, []} <- query(db, "PRAGMA synchronous=FULL"),
         {:ok, [[2]]} <- query(db, "PRAGMA synchronous"),
         {:ok, []} <- query(db, "PRAGMA foreign_keys=ON"),
         {:ok, [[1]]} <- query(db, "PRAGMA foreign_keys"),
         {:ok, [[5000]]} <- query(db, "PRAGMA busy_timeout=5000") do
      :ok
    else
      other -> {:error, {:durability_pragma_failed, other}}
    end
  end

  defp initialize_schema(db) do
    case query(db, "PRAGMA user_version") do
      {:ok, [[0]]} ->
        with :ok <- Sqlite3.execute(db, @schema),
             :ok <- Sqlite3.execute(db, "PRAGMA user_version=1") do
          validate_schema(db)
        else
          other -> {:error, {:schema_failed, other}}
        end

      {:ok, [[1]]} ->
        validate_schema(db)

      {:ok, [[_other]]} ->
        {:error, :unsupported_schema_version}

      other ->
        {:error, {:schema_failed, other}}
    end
  end

  defp validate_schema(db) do
    with {:ok, [[revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         {:ok, [[latest_event]]} <- query(db, "SELECT COALESCE(MAX(revision), 0) FROM journal"),
         {:ok, [[latest_current]]} <-
           query(db, "SELECT COALESCE(MAX(revision), 0) FROM observation_current"),
         true <- is_integer(revision) and revision == latest_event and latest_current <= revision do
      :ok
    else
      other -> {:error, {:schema_inconsistent, other}}
    end
  end

  defp integrity(db) do
    case query(db, "PRAGMA quick_check") do
      {:ok, [["ok"]]} -> :ok
      other -> {:error, {:integrity_failed, other}}
    end
  end

  defp transaction(db, fun) do
    case Sqlite3.execute(db, "BEGIN IMMEDIATE") do
      :ok ->
        case fun.(db) do
          {:commit, result} ->
            case Sqlite3.execute(db, "COMMIT") do
              :ok ->
                {:ok, result}

              {:error, reason} ->
                _ = Sqlite3.execute(db, "ROLLBACK")
                {:error, reason}
            end

          {:rollback, {:duplicate, _} = duplicate} ->
            _ = Sqlite3.execute(db, "ROLLBACK")
            {:ok, duplicate}

          {:rollback, reason} ->
            _ = Sqlite3.execute(db, "ROLLBACK")
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp query(db, sql, params \\ []) do
    case Sqlite3.prepare(db, sql) do
      {:ok, statement} ->
        try do
          with :ok <- Sqlite3.bind(statement, params),
               {:ok, rows} <- Sqlite3.fetch_all(db, statement) do
            {:ok, rows}
          end
        after
          _ = Sqlite3.release(db, statement)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
