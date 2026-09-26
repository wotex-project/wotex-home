defmodule WotexHome.Durable.Store do
  @moduledoc """
  Single-process SQLite writer for observations, enrollment and held receipts.

  Its request outbox is held and has no claim or dispatch API. The host must
  provide an owned database path and supervise this process. A later authority
  service must add process locking and recovery gates
  before any mutating driver can be connected.
  """

  use GenServer

  alias Exqlite.Sqlite3
  alias WotexHome.{Id, Mutation, Policy}
  alias WotexHome.Durable.{Receipt, Registry}
  alias WotexHome.Policy.Context
  alias WotexHome.Semantics.{Capability, Observation, Thing, Value}

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

  @request_schema """
  INSERT OR IGNORE INTO meta(key, value) VALUES ('authority_epoch', 1);
  CREATE TABLE IF NOT EXISTS request_receipts (
    principal_id TEXT NOT NULL,
    authority_epoch INTEGER NOT NULL,
    operation_id TEXT NOT NULL,
    expected_revision INTEGER NOT NULL,
    target_id TEXT NOT NULL,
    capability_key TEXT NOT NULL,
    value_kind TEXT NOT NULL,
    value_a TEXT NOT NULL,
    value_b TEXT,
    profile_ref TEXT NOT NULL,
    disposition TEXT NOT NULL CHECK (disposition IN ('held', 'rejected')),
    reason TEXT,
    revision INTEGER NOT NULL,
    PRIMARY KEY (principal_id, authority_epoch, operation_id)
  );
  CREATE TABLE IF NOT EXISTS request_outbox (
    principal_id TEXT NOT NULL,
    authority_epoch INTEGER NOT NULL,
    operation_id TEXT NOT NULL,
    state TEXT NOT NULL CHECK (state = 'held'),
    revision INTEGER NOT NULL,
    PRIMARY KEY (principal_id, authority_epoch, operation_id),
    FOREIGN KEY (principal_id, authority_epoch, operation_id)
      REFERENCES request_receipts(principal_id, authority_epoch, operation_id)
  );
  CREATE TABLE IF NOT EXISTS request_journal (
    revision INTEGER PRIMARY KEY,
    principal_id TEXT NOT NULL,
    authority_epoch INTEGER NOT NULL,
    operation_id TEXT NOT NULL,
    disposition TEXT NOT NULL,
    reason TEXT
  );
  """

  @authority_schema """
  CREATE TABLE IF NOT EXISTS enrolled_things (
    thing_id TEXT PRIMARY KEY,
    profile_ref TEXT NOT NULL,
    document TEXT NOT NULL,
    resource_revision INTEGER NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('active', 'revoked'))
  );
  CREATE TABLE IF NOT EXISTS principals (
    principal_id TEXT PRIMARY KEY,
    credential_hash BLOB NOT NULL UNIQUE,
    permissions TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('active', 'revoked'))
  );
  CREATE TABLE IF NOT EXISTS principal_targets (
    principal_id TEXT NOT NULL,
    thing_id TEXT NOT NULL,
    PRIMARY KEY (principal_id, thing_id),
    FOREIGN KEY (principal_id) REFERENCES principals(principal_id),
    FOREIGN KEY (thing_id) REFERENCES enrolled_things(thing_id)
  );
  CREATE TABLE IF NOT EXISTS authority_journal (
    revision INTEGER PRIMARY KEY,
    event_type TEXT NOT NULL,
    entity_id TEXT NOT NULL
  );
  """

  @select_current """
  SELECT profile_ref, evidence_ref, source_epoch, source_sequence, boot_epoch,
         source_time_utc_ms, received_time_utc_ms, received_monotonic_ms,
         quality, trust, value_kind, value_a, value_b, revision
  FROM observation_current WHERE thing_id = ? AND capability_key = ?
  """
  @max_i64 9_223_372_036_854_775_807

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

  @doc "Trusted local provisioning boundary; never expose this through a request facade."
  @spec enroll_thing(GenServer.server(), Thing.t()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def enroll_thing(server, thing), do: GenServer.call(server, {:enroll_thing, thing})

  @doc "Trusted local removal boundary; existing held requests remain non-dispatchable."
  @spec revoke_thing(GenServer.server(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, atom()}
  def revoke_thing(server, thing_id), do: GenServer.call(server, {:revoke_thing, thing_id})

  @doc "Trusted local provisioning boundary; returns a new random credential once."
  @spec provision_principal(GenServer.server(), String.t(), [String.t()], [String.t()]) ::
          {:ok, binary(), non_neg_integer()} | {:error, atom()}
  def provision_principal(server, principal_id, permissions, target_ids),
    do: GenServer.call(server, {:provision_principal, principal_id, permissions, target_ids})

  @doc "Trusted local revocation boundary."
  @spec revoke_principal(GenServer.server(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, atom()}
  def revoke_principal(server, principal_id),
    do: GenServer.call(server, {:revoke_principal, principal_id})

  @doc "Authenticate and durably stage a typed request from current registry state."
  @spec submit_request(GenServer.server(), binary(), Mutation.t()) ::
          {:ok, Receipt.t()} | {:error, atom()}
  def submit_request(server, credential, mutation),
    do: GenServer.call(server, {:submit_request, credential, mutation})

  @spec request_status(GenServer.server(), binary(), non_neg_integer(), String.t()) ::
          {:ok, Receipt.t()} | :not_found | {:error, atom()}
  def request_status(server, credential, authority_epoch, operation_id),
    do: GenServer.call(server, {:request_status, credential, authority_epoch, operation_id})

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

  def handle_call({:enroll_thing, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  def handle_call({:revoke_thing, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  def handle_call({:submit_request, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  def handle_call({operation, _, _, _}, _from, %{writable: false} = state)
      when operation in [:provision_principal],
      do: {:reply, {:error, :store_unavailable}, state}

  def handle_call({:revoke_principal, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  def handle_call({:enroll_thing, %Thing{} = thing}, _from, state) do
    case Registry.encode_thing(thing) do
      {:ok, document} -> write_reply(state, fn db -> enroll_thing_tx(db, thing, document) end)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:enroll_thing, _thing}, _from, state),
    do: {:reply, {:error, :invalid_thing}, state}

  def handle_call({:revoke_thing, thing_id}, _from, state) do
    if Id.valid?(thing_id),
      do: write_reply(state, fn db -> revoke_thing_tx(db, thing_id) end),
      else: {:reply, {:error, :invalid_id}, state}
  end

  def handle_call({:provision_principal, principal_id, permissions, target_ids}, _from, state) do
    with true <- Id.valid?(principal_id) and valid_target_ids?(target_ids),
         {:ok, permissions_json} <- Registry.encode_permissions(permissions) do
      credential = :crypto.strong_rand_bytes(32)
      {:ok, hash} = Registry.credential_hash(credential)

      write_reply(state, fn db ->
        provision_principal_tx(db, principal_id, hash, permissions_json, target_ids, credential)
      end)
    else
      _ -> {:reply, {:error, :invalid_provisioning}, state}
    end
  end

  def handle_call({:revoke_principal, principal_id}, _from, state) do
    if Id.valid?(principal_id),
      do: write_reply(state, fn db -> revoke_principal_tx(db, principal_id) end),
      else: {:reply, {:error, :invalid_id}, state}
  end

  def handle_call({:submit_request, credential, %Mutation{} = mutation}, _from, state) do
    with true <- Mutation.valid?(mutation),
         {:ok, hash} <- Registry.credential_hash(credential) do
      write_reply(state, fn db -> submit_request_tx(db, hash, mutation) end)
    else
      _ -> {:reply, {:error, :invalid_request}, state}
    end
  end

  def handle_call({:submit_request, _credential, _mutation}, _from, state),
    do: {:reply, {:error, :invalid_request}, state}

  def handle_call({:request_status, credential, authority_epoch, operation_id}, _from, state) do
    result =
      with {:ok, hash} <- Registry.credential_hash(credential),
           true <-
             Id.valid?(operation_id) and is_integer(authority_epoch) and
               authority_epoch >= 0 and authority_epoch <= @max_i64,
           {:ok, principal_id, _permissions} <- authenticate(state.db, hash) do
        case select_request(state.db, principal_id, authority_epoch, operation_id) do
          {:ok, []} -> :not_found
          {:ok, [row]} -> decode_receipt(principal_id, authority_epoch, operation_id, row)
          {:error, _reason} -> {:error, :store_unavailable}
        end
      else
        false -> {:error, :invalid_id}
        {:error, reason} -> {:error, reason}
      end

    {:reply, result, read_health(state, result)}
  end

  defp read_health(state, {:error, :store_unavailable}), do: %{state | writable: false}
  defp read_health(state, {:error, :corrupt_value}), do: %{state | writable: false}
  defp read_health(state, {:error, :corrupt_receipt}), do: %{state | writable: false}
  defp read_health(state, {:error, :corrupt_enrollment}), do: %{state | writable: false}
  defp read_health(state, {:error, :corrupt_principal}), do: %{state | writable: false}
  defp read_health(state, _result), do: state

  defp write_reply(state, fun) do
    case transaction(state.db, fun) do
      {:ok, result} ->
        {:reply, result, state}

      {:error, {:policy, reason}} ->
        {:reply, {:error, reason}, state}

      {:error, :corrupt_enrollment} ->
        {:reply, {:error, :corrupt_enrollment}, %{state | writable: false}}

      {:error, :corrupt_principal} ->
        {:reply, {:error, :corrupt_principal}, %{state | writable: false}}

      {:error, _reason} ->
        {:reply, {:error, :store_unavailable}, %{state | writable: false}}
    end
  end

  defp enroll_thing_tx(db, thing, document) do
    case query(
           db,
           "SELECT document, resource_revision, status FROM enrolled_things WHERE thing_id = ?",
           [thing.id]
         ) do
      {:ok, []} ->
        with {:ok, revision} <- next_revision(db),
             {:ok, []} <-
               query(db, "INSERT INTO enrolled_things VALUES (?, ?, ?, 0, 'active')", [
                 thing.id,
                 thing.profile_ref,
                 document
               ]),
             :ok <- authority_event(db, revision, "thing_enrolled", thing.id) do
          {:commit, {:ok, revision}}
        else
          {:error, reason} -> {:rollback, reason}
        end

      {:ok, [[_document, _resource_revision, _status]]} ->
        {:rollback, {:policy, :enrollment_conflict}}

      {:error, reason} ->
        {:rollback, reason}
    end
  end

  defp revoke_thing_tx(db, thing_id) do
    case query(db, "SELECT status FROM enrolled_things WHERE thing_id = ?", [thing_id]) do
      {:ok, [["active"]]} ->
        with {:ok, revision} <- next_revision(db),
             {:ok, []} <-
               query(db, "UPDATE enrolled_things SET status = 'revoked' WHERE thing_id = ?", [
                 thing_id
               ]),
             :ok <- authority_event(db, revision, "thing_revoked", thing_id) do
          {:commit, {:ok, revision}}
        else
          {:error, reason} -> {:rollback, reason}
        end

      {:ok, _} ->
        {:rollback, {:policy, :target_unavailable}}

      {:error, reason} ->
        {:rollback, reason}
    end
  end

  defp provision_principal_tx(db, principal_id, hash, permissions_json, target_ids, credential) do
    with {:ok, []} <-
           query(db, "SELECT principal_id FROM principals WHERE principal_id = ?", [principal_id]),
         :ok <- active_targets(db, target_ids),
         {:ok, revision} <- next_revision(db),
         {:ok, []} <-
           query(db, "INSERT INTO principals VALUES (?, ?, ?, 'active')", [
             principal_id,
             hash,
             permissions_json
           ]),
         :ok <- insert_targets(db, principal_id, target_ids),
         :ok <- authority_event(db, revision, "principal_provisioned", principal_id) do
      {:commit, {:ok, credential, revision}}
    else
      {:ok, _existing} -> {:rollback, {:policy, :principal_exists}}
      {:error, reason} -> {:rollback, reason}
    end
  end

  defp revoke_principal_tx(db, principal_id) do
    case query(db, "SELECT status FROM principals WHERE principal_id = ?", [principal_id]) do
      {:ok, [["active"]]} ->
        with {:ok, revision} <- next_revision(db),
             {:ok, []} <-
               query(db, "UPDATE principals SET status = 'revoked' WHERE principal_id = ?", [
                 principal_id
               ]),
             :ok <- authority_event(db, revision, "principal_revoked", principal_id) do
          {:commit, {:ok, revision}}
        else
          {:error, reason} -> {:rollback, reason}
        end

      {:ok, _} ->
        {:rollback, {:policy, :principal_unavailable}}

      {:error, reason} ->
        {:rollback, reason}
    end
  end

  defp active_targets(db, target_ids) do
    Enum.reduce_while(target_ids, :ok, fn target_id, :ok ->
      case query(db, "SELECT status FROM enrolled_things WHERE thing_id = ?", [target_id]) do
        {:ok, [["active"]]} -> {:cont, :ok}
        {:ok, _} -> {:halt, {:error, {:policy, :target_unavailable}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp insert_targets(db, principal_id, target_ids) do
    Enum.reduce_while(target_ids, :ok, fn target_id, :ok ->
      case query(db, "INSERT INTO principal_targets VALUES (?, ?)", [principal_id, target_id]) do
        {:ok, []} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp authenticate(db, hash) do
    case query(
           db,
           "SELECT principal_id, permissions, status FROM principals WHERE credential_hash = ?",
           [hash]
         ) do
      {:ok, [[principal_id, permissions_json, "active"]]} ->
        with {:ok, permissions} <- Registry.decode_permissions(permissions_json) do
          {:ok, principal_id, permissions}
        end

      {:ok, _} ->
        {:error, :unauthorized}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp enrolled_thing(db, target_id) do
    case query(
           db,
           "SELECT profile_ref, document, resource_revision, status FROM enrolled_things WHERE thing_id = ?",
           [target_id]
         ) do
      {:ok, [[profile_ref, document, resource_revision, "active"]]} ->
        with {:ok, %Thing{id: ^target_id, profile_ref: ^profile_ref} = thing} <-
               Registry.decode_thing(document),
             true <- is_integer(resource_revision) and resource_revision >= 0 do
          {:ok, thing, resource_revision}
        else
          _ -> {:error, :corrupt_enrollment}
        end

      {:ok, _} ->
        {:error, :target_unavailable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp allowed_targets(db, principal_id) do
    case query(db, "SELECT thing_id FROM principal_targets WHERE principal_id = ?", [principal_id]) do
      {:ok, rows} -> {:ok, MapSet.new(Enum.map(rows, fn [target_id] -> target_id end))}
      {:error, reason} -> {:error, reason}
    end
  end

  defp valid_target_ids?(ids) do
    is_list(ids) and length(ids) > 0 and length(ids) <= 32 and
      Enum.all?(ids, &Id.valid?/1) and length(Enum.uniq(ids)) == length(ids)
  end

  defp next_revision(db) do
    case query(db, "SELECT value FROM meta WHERE key = 'revision'") do
      {:ok, [[revision]]} when is_integer(revision) and revision < @max_i64 ->
        {:ok, revision + 1}

      {:ok, _} ->
        {:error, :revision_exhausted}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp authority_event(db, revision, event_type, entity_id) do
    with {:ok, []} <-
           query(db, "INSERT INTO authority_journal VALUES (?, ?, ?)", [
             revision,
             event_type,
             entity_id
           ]),
         {:ok, []} <- query(db, "UPDATE meta SET value = ? WHERE key = 'revision'", [revision]) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp submit_request_tx(db, hash, mutation) do
    with {:ok, principal_id, permissions} <- authenticate(db, hash),
         {:ok, rows} <-
           select_request(db, principal_id, mutation.authority_epoch, mutation.operation_id) do
      case rows do
        [] ->
          with {:ok, thing, resource_revision} <- enrolled_thing(db, mutation.target_id),
               {:ok, allowed_targets} <- allowed_targets(db, principal_id),
               {:ok, [[store_epoch]]} <-
                 query(db, "SELECT value FROM meta WHERE key = 'authority_epoch'") do
            context = %Context{
              principal_id: principal_id,
              permissions: permissions,
              allowed_targets: allowed_targets,
              authority_epoch: store_epoch,
              resource_revision: resource_revision,
              enrollment_valid: true,
              profile_valid: true,
              invariants: :allow
            }

            write_request(db, principal_id, mutation, thing, context)
          else
            {:error, :corrupt_enrollment} -> {:rollback, :corrupt_enrollment}
            {:error, reason} -> {:rollback, {:policy, reason}}
          end

        [row] ->
          prior_request(row, principal_id, mutation)
      end
    else
      {:error, reason} when reason in [:corrupt_principal, :corrupt_enrollment] ->
        {:rollback, reason}

      {:error, reason} ->
        {:rollback, {:policy, reason}}
    end
  end

  defp select_request(db, principal_id, authority_epoch, operation_id) do
    query(
      db,
      "SELECT expected_revision, target_id, capability_key, value_kind, value_a, value_b, profile_ref, disposition, reason, revision FROM request_receipts WHERE principal_id = ? AND authority_epoch = ? AND operation_id = ?",
      [principal_id, authority_epoch, operation_id]
    )
  end

  defp prior_request(row, principal_id, mutation) do
    {:ok, value} = Value.new(mutation.value)
    {kind, a, b} = encode_value(value)
    [expected_revision, target_id, capability_key, old_kind, old_a, old_b | _] = row

    if {expected_revision, target_id, capability_key, old_kind, old_a, old_b} ==
         {mutation.expected_revision, mutation.target_id, mutation.capability_key, kind, a, b} do
      case decode_receipt(principal_id, mutation.authority_epoch, mutation.operation_id, row) do
        {:ok, receipt} -> {:rollback, {:unchanged, {:ok, receipt}}}
        {:error, reason} -> {:rollback, reason}
      end
    else
      {:rollback, {:policy, :operation_id_conflict}}
    end
  end

  defp write_request(db, principal_id, mutation, thing, context) do
    with {:ok, [[store_epoch]]} <-
           query(db, "SELECT value FROM meta WHERE key = 'authority_epoch'"),
         {:ok, [[revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'") do
      {disposition, reason} = request_decision(store_epoch, mutation, thing, context)
      {:ok, value} = Value.new(mutation.value)
      {kind, a, b} = encode_value(value)
      new_revision = revision + 1

      params = [
        principal_id,
        mutation.authority_epoch,
        mutation.operation_id,
        mutation.expected_revision,
        mutation.target_id,
        mutation.capability_key,
        kind,
        a,
        b,
        thing.profile_ref,
        disposition,
        reason,
        new_revision
      ]

      with {:ok, []} <-
             query(
               db,
               "INSERT INTO request_receipts VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
               params
             ),
           {:ok, []} <-
             query(db, "INSERT INTO request_journal VALUES (?, ?, ?, ?, ?, ?)", [
               new_revision,
               principal_id,
               mutation.authority_epoch,
               mutation.operation_id,
               disposition,
               reason
             ]),
           :ok <- maybe_hold_request(db, principal_id, mutation, disposition, new_revision),
           {:ok, []} <-
             query(db, "UPDATE meta SET value = ? WHERE key = 'revision'", [new_revision]) do
        receipt = %Receipt{
          principal_id: principal_id,
          authority_epoch: mutation.authority_epoch,
          operation_id: mutation.operation_id,
          disposition: if(disposition == "held", do: :held, else: :rejected),
          reason: reason,
          revision: new_revision
        }

        {:commit, {:ok, receipt}}
      else
        {:error, error} -> {:rollback, error}
      end
    else
      {:error, error} -> {:rollback, error}
    end
  end

  defp request_decision(store_epoch, mutation, _thing, _context)
       when store_epoch != mutation.authority_epoch,
       do: {"rejected", "stale_authority_epoch"}

  defp request_decision(_store_epoch, mutation, thing, context) do
    case Policy.check(mutation, thing, context) do
      :ok -> {"held", nil}
      {:error, reason} -> {"rejected", Atom.to_string(reason)}
    end
  end

  defp maybe_hold_request(_db, _principal_id, _mutation, "rejected", _revision), do: :ok

  defp maybe_hold_request(db, principal_id, mutation, "held", revision) do
    case query(db, "INSERT INTO request_outbox VALUES (?, ?, ?, 'held', ?)", [
           principal_id,
           mutation.authority_epoch,
           mutation.operation_id,
           revision
         ]) do
      {:ok, []} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp decode_receipt(principal_id, authority_epoch, operation_id, row) do
    [_expected, _target, _capability, _kind, _a, _b, _profile, disposition, reason, revision] =
      row

    case {disposition, reason, revision} do
      {"held", nil, revision} when is_integer(revision) and revision >= 0 ->
        {:ok,
         %Receipt{
           principal_id: principal_id,
           authority_epoch: authority_epoch,
           operation_id: operation_id,
           disposition: :held,
           reason: reason,
           revision: revision
         }}

      {"rejected", reason, revision}
      when is_binary(reason) and is_integer(revision) and revision >= 0 ->
        {:ok,
         %Receipt{
           principal_id: principal_id,
           authority_epoch: authority_epoch,
           operation_id: operation_id,
           disposition: :rejected,
           reason: reason,
           revision: revision
         }}

      _ ->
        {:error, :corrupt_receipt}
    end
  end

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
             :ok <- Sqlite3.execute(db, @request_schema),
             :ok <- Sqlite3.execute(db, @authority_schema),
             :ok <- Sqlite3.execute(db, "PRAGMA user_version=3") do
          validate_schema(db)
        else
          other -> {:error, {:schema_failed, other}}
        end

      {:ok, [[1]]} ->
        with :ok <- validate_observation_schema(db),
             :ok <- Sqlite3.execute(db, @request_schema),
             :ok <- Sqlite3.execute(db, @authority_schema),
             :ok <- Sqlite3.execute(db, "PRAGMA user_version=3") do
          validate_schema(db)
        else
          other -> {:error, {:schema_failed, other}}
        end

      {:ok, [[2]]} ->
        with :ok <- validate_request_schema(db),
             :ok <- Sqlite3.execute(db, @authority_schema),
             :ok <- Sqlite3.execute(db, "PRAGMA user_version=3") do
          validate_schema(db)
        else
          other -> {:error, {:schema_failed, other}}
        end

      {:ok, [[3]]} ->
        validate_schema(db)

      {:ok, [[_other]]} ->
        {:error, :unsupported_schema_version}

      other ->
        {:error, {:schema_failed, other}}
    end
  end

  defp validate_schema(db) do
    with :ok <- validate_observation_schema_tables(db),
         {:ok, [[revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         {:ok, [[observation_revision]]} <-
           query(db, "SELECT COALESCE(MAX(revision), 0) FROM journal"),
         {:ok, [[request_revision]]} <-
           query(db, "SELECT COALESCE(MAX(revision), 0) FROM request_journal"),
         {:ok, [[authority_revision]]} <-
           query(db, "SELECT COALESCE(MAX(revision), 0) FROM authority_journal"),
         {:ok, [[latest_receipt]]} <-
           query(db, "SELECT COALESCE(MAX(revision), 0) FROM request_receipts"),
         {:ok, [[latest_current]]} <-
           query(db, "SELECT COALESCE(MAX(revision), 0) FROM observation_current"),
         {:ok, [[_held_count]]} <- query(db, "SELECT COUNT(*) FROM request_outbox"),
         {:ok, [[_enrolled_count]]} <- query(db, "SELECT COUNT(*) FROM enrolled_things"),
         {:ok, [[_principal_count]]} <- query(db, "SELECT COUNT(*) FROM principals"),
         {:ok, [[epoch]]} <- query(db, "SELECT value FROM meta WHERE key = 'authority_epoch'"),
         {:ok, []} <- query(db, "PRAGMA foreign_key_check"),
         true <-
           is_integer(epoch) and epoch >= 1 and is_integer(revision) and
             revision == Enum.max([observation_revision, request_revision, authority_revision]) and
             latest_receipt <= revision and latest_current <= revision do
      :ok
    else
      other -> {:error, {:schema_inconsistent, other}}
    end
  end

  defp validate_request_schema(db) do
    with :ok <- validate_observation_schema_tables(db),
         {:ok, [[_receipt_count]]} <- query(db, "SELECT COUNT(*) FROM request_receipts"),
         {:ok, [[_outbox_count]]} <- query(db, "SELECT COUNT(*) FROM request_outbox"),
         {:ok, [[_request_revision]]} <-
           query(db, "SELECT COALESCE(MAX(revision), 0) FROM request_journal") do
      :ok
    else
      other -> {:error, {:schema_inconsistent, other}}
    end
  end

  defp validate_observation_schema(db) do
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

  defp validate_observation_schema_tables(db) do
    case query(db, "SELECT COALESCE(MAX(revision), 0) FROM observation_current") do
      {:ok, [[_latest_current]]} -> :ok
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

          {:rollback, {:unchanged, result}} ->
            _ = Sqlite3.execute(db, "ROLLBACK")
            {:ok, result}

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
