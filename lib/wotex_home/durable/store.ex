defmodule WotexHome.Durable.Store do
  @moduledoc """
  Single-process SQLite writer for observations, enrollment and held receipts.

  Its request outbox is held and has no claim or dispatch API. The host must
  provide an owned database path and supervise this process. A later authority
  service must add recovery gates before any mutating driver can be connected.
  """

  use GenServer

  alias Exqlite.Sqlite3
  alias WotexHome.{Id, Mutation, Policy}
  alias WotexHome.Durable.{Backup, HostLock, Receipt, Registry}
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

  @source_epoch_schema """
  CREATE TABLE IF NOT EXISTS source_epoch_grants (
    thing_id TEXT NOT NULL,
    capability_key TEXT NOT NULL,
    old_epoch TEXT NOT NULL,
    new_epoch TEXT NOT NULL,
    current_revision INTEGER NOT NULL,
    grant_revision INTEGER NOT NULL,
    PRIMARY KEY (thing_id, capability_key),
    FOREIGN KEY (thing_id, capability_key)
      REFERENCES observation_current(thing_id, capability_key)
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

  @doc "Atomically record one device reply's declared capability observations."
  @spec record_batch(GenServer.server(), Thing.t(), [Observation.t()]) ::
          {:ok, [non_neg_integer()]}
          | {:duplicate, [non_neg_integer()]}
          | {:error, atom()}
  def record_batch(server, thing, observations),
    do: GenServer.call(server, {:record_batch, thing, observations})

  @doc "Trusted, one-use source-epoch approval after device identity requalification."
  @spec authorize_source_epoch(
          GenServer.server(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          non_neg_integer()
        ) :: {:ok, non_neg_integer()} | {:error, atom()}
  def authorize_source_epoch(
        server,
        thing_id,
        capability_key,
        old_epoch,
        new_epoch,
        current_revision
      ),
      do:
        GenServer.call(
          server,
          {:authorize_source_epoch, thing_id, capability_key, old_epoch, new_epoch,
           current_revision}
        )

  @spec current(GenServer.server(), String.t(), String.t()) ::
          {:ok, Observation.t(), non_neg_integer()} | :not_found | {:error, atom()}
  def current(server, thing_id, capability_key),
    do: GenServer.call(server, {:current, thing_id, capability_key})

  @spec revision(GenServer.server()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def revision(server), do: GenServer.call(server, :revision)

  @doc "Bounded in-process recovery view without principal, target or secret data."
  @spec health(GenServer.server()) :: {:ok, map()} | {:error, atom()}
  def health(server), do: GenServer.call(server, :health)

  @spec authorized_health(GenServer.server(), binary()) :: {:ok, map()} | {:error, atom()}
  def authorized_health(server, credential),
    do: GenServer.call(server, {:authorized_health, credential})

  @doc "A scoped, revision-stable page of current reports. Any intervening write requires a new snapshot."
  @spec snapshot_page(
          GenServer.server(),
          binary(),
          nil | non_neg_integer(),
          nil | map(),
          pos_integer()
        ) ::
          {:ok, map()} | {:error, atom()}
  def snapshot_page(server, credential, watermark, after_key, page_size),
    do: GenServer.call(server, {:snapshot_page, credential, watermark, after_key, page_size})

  @doc "A scoped, revision-stable page of active Thing declarations."
  @spec catalogue_page(
          GenServer.server(),
          binary(),
          nil | non_neg_integer(),
          nil | String.t(),
          pos_integer()
        ) ::
          {:ok, map()} | {:error, atom()}
  def catalogue_page(server, credential, watermark, after_id, page_size),
    do: GenServer.call(server, {:catalogue_page, credential, watermark, after_id, page_size})

  @doc "A scoped page of the append-only observation journal for one capability."
  @spec history_page(
          GenServer.server(),
          binary(),
          String.t(),
          String.t(),
          nil | non_neg_integer(),
          non_neg_integer(),
          pos_integer()
        ) ::
          {:ok, map()} | {:error, atom()}
  def history_page(
        server,
        credential,
        thing_id,
        capability_key,
        watermark,
        after_revision,
        page_size
      ),
      do:
        GenServer.call(
          server,
          {:history_page, credential, thing_id, capability_key, watermark, after_revision,
           page_size}
        )

  @doc "A scoped observation feed after a global revision cursor; no device I/O or subscription."
  @spec events_page(GenServer.server(), binary(), non_neg_integer(), pos_integer()) ::
          {:ok, map()} | {:error, atom()}
  def events_page(server, credential, after_revision, page_size),
    do: GenServer.call(server, {:events_page, credential, after_revision, page_size})

  @doc "A principal's durable request events after a global revision cursor."
  @spec request_events_page(GenServer.server(), binary(), non_neg_integer(), pos_integer()) ::
          {:ok, map()} | {:error, atom()}
  def request_events_page(server, credential, after_revision, page_size),
    do: GenServer.call(server, {:request_events_page, credential, after_revision, page_size})

  @doc "Read-only, target-scoped inputs for an external draft review."
  @spec review_inputs(GenServer.server(), binary()) ::
          {:ok, %{String.t() => Thing.t()}, non_neg_integer()} | {:error, atom()}
  def review_inputs(server, credential), do: GenServer.call(server, {:review_inputs, credential})

  @doc "Confirm that the review credential and inputs remain current after external checking."
  @spec review_current(GenServer.server(), binary(), non_neg_integer()) ::
          :ok | {:error, atom()}
  def review_current(server, credential, watermark),
    do: GenServer.call(server, {:review_current, credential, watermark})

  @doc "Trusted local encrypted backup export; key custody and restore authorization stay outside Store."
  @spec export_backup(GenServer.server(), String.t(), binary()) :: {:ok, map()} | {:error, atom()}
  def export_backup(server, destination, key),
    do: GenServer.call(server, {:export_backup, destination, key}, 120_000)

  @doc "Trusted local provisioning boundary; never expose this through a request facade."
  @spec enroll_thing(GenServer.server(), Thing.t()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def enroll_thing(server, thing), do: GenServer.call(server, {:enroll_thing, thing})

  @doc "Trusted compare-and-swap reduction of an enrolled declaration; clears current reports and held work."
  @spec narrow_thing(GenServer.server(), Thing.t(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, atom()}
  def narrow_thing(server, thing, expected_revision),
    do: GenServer.call(server, {:narrow_thing, thing, expected_revision})

  @doc "Trusted local removal boundary; atomically rejects this Thing's held requests."
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

  @doc "Trusted target-grant revocation; atomically rejects this principal's held work for the target."
  @spec revoke_target_grant(GenServer.server(), String.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, atom()}
  def revoke_target_grant(server, principal_id, thing_id),
    do: GenServer.call(server, {:revoke_target_grant, principal_id, thing_id})

  @doc "Trusted one-time credential rotation; invalidates the prior credential and held work."
  @spec rotate_principal_credential(GenServer.server(), String.t()) ::
          {:ok, binary(), non_neg_integer()} | {:error, atom()}
  def rotate_principal_credential(server, principal_id),
    do: GenServer.call(server, {:rotate_principal_credential, principal_id})

  @doc "Authenticate and durably stage a typed request from current registry state."
  @spec submit_request(GenServer.server(), binary(), Mutation.t()) ::
          {:ok, Receipt.t()} | {:error, atom()}
  def submit_request(server, credential, mutation),
    do: GenServer.call(server, {:submit_request, credential, mutation})

  @spec request_status(GenServer.server(), binary(), non_neg_integer(), String.t()) ::
          {:ok, Receipt.t()} | :not_found | {:error, atom()}
  def request_status(server, credential, authority_epoch, operation_id),
    do: GenServer.call(server, {:request_status, credential, authority_epoch, operation_id})

  @doc "Withdraw one held request while retaining its operation-ID receipt and history."
  @spec cancel_request(GenServer.server(), binary(), non_neg_integer(), String.t()) ::
          {:ok, Receipt.t()} | :not_found | {:error, atom()}
  def cancel_request(server, credential, authority_epoch, operation_id),
    do: GenServer.call(server, {:cancel_request, credential, authority_epoch, operation_id})

  @impl true
  def init(path) when is_binary(path) and path != "" and path != ":memory:" do
    case HostLock.acquire(path) do
      {:ok, lock} ->
        case Sqlite3.open(path) do
          {:ok, db} ->
            case with :ok <- File.chmod(path, 0o600), do: boot(db) do
              :ok ->
                {:ok, %{db: db, lock: lock, writable: true}}

              {:error, reason} ->
                _ = Sqlite3.close(db)
                _ = HostLock.release(lock)
                {:stop, {:store_open_failed, reason}}
            end

          {:error, reason} ->
            _ = HostLock.release(lock)
            {:stop, {:store_open_failed, reason}}
        end

      {:error, reason} ->
        {:stop, {:store_open_failed, reason}}
    end
  end

  def init(_path), do: {:stop, :invalid_store_path}

  defp boot(db) do
    with :ok <- ensure_not_quarantined(db),
         :ok <- configure(db),
         :ok <- initialize_schema(db),
         :ok <- integrity(db) do
      :ok
    end
  end

  defp ensure_not_quarantined(db) do
    case query(db, "SELECT value FROM meta WHERE key = 'restore_quarantine'") do
      {:ok, []} -> :ok
      {:ok, _} -> {:error, :restore_requires_transfer}
      {:error, _} -> :ok
    end
  end

  @impl true
  def terminate(_reason, %{db: db, lock: lock}) do
    _ = Sqlite3.close(db)
    HostLock.release(lock)
  end

  @impl true
  def handle_call({:record, _observation, _capability}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  def handle_call({:record_batch, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  def handle_call({:authorize_source_epoch, _, _, _, _, _}, _from, %{writable: false} = state),
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

  def handle_call({:record_batch, %Thing{} = thing, observations}, _from, state) do
    with {:ok, pairs} <- valid_record_batch(thing, observations) do
      case transaction(state.db, fn db -> record_batch_tx(db, pairs) end) do
        {:ok, result} -> {:reply, result, state}
        {:error, {:policy, reason}} -> {:reply, {:error, reason}, state}
        {:error, _reason} -> {:reply, {:error, :store_unavailable}, %{state | writable: false}}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:record_batch, _thing, _observations}, _from, state),
    do: {:reply, {:error, :invalid_observation_batch}, state}

  def handle_call(
        {:authorize_source_epoch, thing_id, capability_key, old_epoch, new_epoch,
         current_revision},
        _from,
        state
      ) do
    if Enum.all?([thing_id, capability_key, old_epoch, new_epoch], &Id.valid?/1) and
         old_epoch != new_epoch and is_integer(current_revision) and current_revision >= 0 and
         current_revision <= @max_i64 do
      write_reply(state, fn db ->
        authorize_source_epoch_tx(
          db,
          thing_id,
          capability_key,
          old_epoch,
          new_epoch,
          current_revision
        )
      end)
    else
      {:reply, {:error, :invalid_source_epoch_grant}, state}
    end
  end

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

  def handle_call(:health, _from, state) do
    result = health_result(state)
    {:reply, result, read_health(state, result)}
  end

  def handle_call({:authorized_health, credential}, _from, state) do
    result =
      with {:ok, hash} <- Registry.credential_hash(credential),
           {:ok, _principal_id, permissions} <- authenticate(state.db, hash),
           true <- Enum.any?(permissions, &(&1 in ["read", "control:ordinary"])) do
        health_result(state)
      else
        false -> {:error, :permission_denied}
        {:error, reason} -> {:error, reason}
      end

    {:reply, result, read_health(state, result)}
  end

  def handle_call({:review_inputs, credential}, _from, state) do
    result = review_inputs_result(state.db, credential)
    {:reply, result, read_health(state, result)}
  end

  def handle_call({:review_current, credential, watermark}, _from, state) do
    result = review_current_result(state.db, credential, watermark)
    {:reply, result, read_health(state, result)}
  end

  def handle_call({:snapshot_page, credential, watermark, after_key, page_size}, _from, state) do
    result = snapshot_page_result(state.db, credential, watermark, after_key, page_size)
    {:reply, result, read_health(state, result)}
  end

  def handle_call({:catalogue_page, credential, watermark, after_id, page_size}, _from, state) do
    result = catalogue_page_result(state.db, credential, watermark, after_id, page_size)
    {:reply, result, read_health(state, result)}
  end

  def handle_call(
        {:history_page, credential, thing_id, capability_key, watermark, after_revision,
         page_size},
        _from,
        state
      ) do
    result =
      history_page_result(
        state.db,
        credential,
        thing_id,
        capability_key,
        watermark,
        after_revision,
        page_size
      )

    {:reply, result, read_health(state, result)}
  end

  def handle_call({:events_page, credential, after_revision, page_size}, _from, state) do
    result = events_page_result(state.db, credential, after_revision, page_size)
    {:reply, result, read_health(state, result)}
  end

  def handle_call({:request_events_page, credential, after_revision, page_size}, _from, state) do
    result = request_events_page_result(state.db, credential, after_revision, page_size)
    {:reply, result, read_health(state, result)}
  end

  def handle_call({:export_backup, destination, key}, _from, state) do
    {:reply, Backup.export(state.db, destination, key), state}
  end

  def handle_call({:enroll_thing, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  def handle_call({:narrow_thing, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  def handle_call({:revoke_thing, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  def handle_call({:submit_request, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  def handle_call({:cancel_request, _, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  def handle_call({operation, _, _, _}, _from, %{writable: false} = state)
      when operation in [:provision_principal],
      do: {:reply, {:error, :store_unavailable}, state}

  def handle_call({:revoke_principal, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  def handle_call({:revoke_target_grant, _, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  def handle_call({:rotate_principal_credential, _}, _from, %{writable: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  def handle_call({:enroll_thing, %Thing{} = thing}, _from, state) do
    case Registry.encode_thing(thing) do
      {:ok, document} -> write_reply(state, fn db -> enroll_thing_tx(db, thing, document) end)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:enroll_thing, _thing}, _from, state),
    do: {:reply, {:error, :invalid_thing}, state}

  def handle_call({:narrow_thing, %Thing{} = thing, expected_revision}, _from, state) do
    with true <-
           is_integer(expected_revision) and expected_revision >= 0 and
             expected_revision < @max_i64,
         {:ok, document} <- Registry.encode_thing(thing) do
      write_reply(state, fn db -> narrow_thing_tx(db, thing, document, expected_revision) end)
    else
      _ -> {:reply, {:error, :invalid_declaration_change}, state}
    end
  end

  def handle_call({:narrow_thing, _, _}, _from, state),
    do: {:reply, {:error, :invalid_declaration_change}, state}

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

  def handle_call({:revoke_target_grant, principal_id, thing_id}, _from, state) do
    if Id.valid?(principal_id) and Id.valid?(thing_id),
      do: write_reply(state, fn db -> revoke_target_grant_tx(db, principal_id, thing_id) end),
      else: {:reply, {:error, :invalid_id}, state}
  end

  def handle_call({:rotate_principal_credential, principal_id}, _from, state) do
    if Id.valid?(principal_id) do
      credential = :crypto.strong_rand_bytes(32)
      {:ok, hash} = Registry.credential_hash(credential)

      write_reply(state, fn db ->
        rotate_principal_credential_tx(db, principal_id, hash, credential)
      end)
    else
      {:reply, {:error, :invalid_id}, state}
    end
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

  def handle_call({:cancel_request, credential, authority_epoch, operation_id}, _from, state) do
    if Id.valid?(operation_id) and is_integer(authority_epoch) and authority_epoch >= 0 and
         authority_epoch <= @max_i64 do
      with {:ok, hash} <- Registry.credential_hash(credential) do
        write_reply(state, fn db -> cancel_request_tx(db, hash, authority_epoch, operation_id) end)
      else
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :invalid_id}, state}
    end
  end

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

  defp review_inputs_result(db, credential) do
    with {:ok, principal_id} <- review_principal(db, credential),
         {:ok, [[revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         {:ok, rows} <- catalogue_rows(db, principal_id, "", 33),
         true <- rows != [] and length(rows) <= 32,
         {:ok, things} <- review_things(rows) do
      {:ok, things, revision}
    else
      false ->
        {:error, :review_scope_unavailable}

      {:error, reason}
      when reason in [
             :invalid_credential,
             :unauthorized,
             :permission_denied,
             :corrupt_principal,
             :corrupt_enrollment
           ] ->
        {:error, reason}

      _ ->
        {:error, :store_unavailable}
    end
  end

  defp review_current_result(db, credential, watermark) do
    with true <- is_integer(watermark) and watermark >= 0 and watermark <= @max_i64,
         {:ok, _principal_id} <- review_principal(db, credential),
         {:ok, [[revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         :ok <- snapshot_watermark(watermark, revision) do
      :ok
    else
      false ->
        {:error, :invalid_review_watermark}

      {:error, reason}
      when reason in [
             :invalid_credential,
             :unauthorized,
             :permission_denied,
             :corrupt_principal,
             :resnapshot_required
           ] ->
        {:error, reason}

      _ ->
        {:error, :store_unavailable}
    end
  end

  defp review_principal(db, credential) do
    with {:ok, hash} <- Registry.credential_hash(credential),
         {:ok, principal_id, permissions} <- authenticate(db, hash),
         true <- "rule:review" in permissions do
      {:ok, principal_id}
    else
      false -> {:error, :permission_denied}
      {:error, reason} -> {:error, reason}
    end
  end

  defp review_things(rows) do
    Enum.reduce_while(rows, {:ok, %{}}, fn
      [thing_id, profile_ref, document, revision], {:ok, things} ->
        case Registry.decode_thing(document) do
          {:ok, %Thing{id: ^thing_id, profile_ref: ^profile_ref} = thing}
          when is_integer(revision) and revision >= 0 ->
            {:cont, {:ok, Map.put(things, thing_id, thing)}}

          _ ->
            {:halt, {:error, :corrupt_enrollment}}
        end
    end)
  end

  defp snapshot_page_result(db, credential, watermark, after_key, page_size) do
    with :ok <- valid_snapshot_request(watermark, after_key, page_size),
         {:ok, hash} <- Registry.credential_hash(credential),
         {:ok, principal_id, permissions} <- authenticate(db, hash),
         true <- Enum.any?(permissions, &(&1 in ["read", "control:ordinary"])),
         {:ok, [[revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         :ok <- snapshot_watermark(watermark, revision),
         {:ok, [[epoch]]} <- query(db, "SELECT value FROM meta WHERE key = 'authority_epoch'"),
         {:ok, rows} <- snapshot_rows(db, principal_id, after_key, page_size + 1),
         {:ok, items} <- snapshot_items(Enum.take(rows, page_size)) do
      more? = length(rows) > page_size

      next_after =
        if more? do
          last = List.last(items)
          %{"thing_id" => last["thing_id"], "capability_key" => last["capability_key"]}
        end

      {:ok,
       %{
         authority_epoch: epoch,
         watermark: revision,
         items: items,
         next_after: next_after
       }}
    else
      false ->
        {:error, :permission_denied}

      {:error, reason} when reason in [:invalid_snapshot_request, :resnapshot_required] ->
        {:error, reason}

      {:error, reason} when reason in [:invalid_credential, :unauthorized, :permission_denied] ->
        {:error, reason}

      {:error, reason} when reason in [:corrupt_principal, :corrupt_value] ->
        {:error, reason}

      _ ->
        {:error, :store_unavailable}
    end
  end

  defp catalogue_page_result(db, credential, watermark, after_id, page_size) do
    with :ok <- valid_catalogue_request(watermark, after_id, page_size),
         {:ok, hash} <- Registry.credential_hash(credential),
         {:ok, principal_id, permissions} <- authenticate(db, hash),
         true <- Enum.any?(permissions, &(&1 in ["read", "control:ordinary"])),
         {:ok, [[revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         :ok <- snapshot_watermark(watermark, revision),
         {:ok, [[epoch]]} <- query(db, "SELECT value FROM meta WHERE key = 'authority_epoch'"),
         {:ok, rows} <- catalogue_rows(db, principal_id, after_id || "", page_size + 1),
         {:ok, items} <- catalogue_items(Enum.take(rows, page_size)) do
      next_after = if length(rows) > page_size, do: List.last(items)["id"]

      {:ok,
       %{
         authority_epoch: epoch,
         watermark: revision,
         items: items,
         next_after: next_after
       }}
    else
      false ->
        {:error, :permission_denied}

      {:error, reason}
      when reason in [
             :invalid_catalogue_request,
             :resnapshot_required,
             :invalid_credential,
             :unauthorized,
             :permission_denied,
             :corrupt_principal,
             :corrupt_enrollment
           ] ->
        {:error, reason}

      _ ->
        {:error, :store_unavailable}
    end
  end

  defp history_page_result(
         db,
         credential,
         thing_id,
         capability_key,
         watermark,
         after_revision,
         page_size
       ) do
    with :ok <-
           valid_history_request(thing_id, capability_key, watermark, after_revision, page_size),
         {:ok, hash} <- Registry.credential_hash(credential),
         {:ok, principal_id, permissions} <- authenticate(db, hash),
         true <- Enum.any?(permissions, &(&1 in ["read", "control:ordinary"])),
         {:ok, targets} <- allowed_targets(db, principal_id),
         true <- MapSet.member?(targets, thing_id),
         {:ok, thing, _resource_revision} <- enrolled_thing(db, thing_id),
         {:ok, _capability} <- Thing.capability(thing, capability_key),
         {:ok, [[revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         :ok <- snapshot_watermark(watermark, revision),
         {:ok, [[epoch]]} <- query(db, "SELECT value FROM meta WHERE key = 'authority_epoch'"),
         {:ok, rows} <-
           history_rows(db, thing_id, capability_key, after_revision, revision, page_size + 1),
         {:ok, items} <- history_items(Enum.take(rows, page_size), thing_id, capability_key) do
      next_after = if length(rows) > page_size, do: List.last(items)["revision"]

      {:ok,
       %{
         authority_epoch: epoch,
         watermark: revision,
         items: items,
         next_after: next_after
       }}
    else
      false ->
        {:error, :permission_denied}

      :error ->
        {:error, :unknown_capability}

      {:error, reason}
      when reason in [
             :invalid_history_request,
             :resnapshot_required,
             :invalid_credential,
             :unauthorized,
             :permission_denied,
             :target_unavailable,
             :corrupt_enrollment,
             :corrupt_principal,
             :corrupt_value
           ] ->
        {:error, reason}

      _ ->
        {:error, :store_unavailable}
    end
  end

  defp events_page_result(db, credential, after_revision, page_size) do
    with :ok <- valid_events_request(after_revision, page_size),
         {:ok, hash} <- Registry.credential_hash(credential),
         {:ok, principal_id, permissions} <- authenticate(db, hash),
         true <- Enum.any?(permissions, &(&1 in ["read", "control:ordinary"])),
         {:ok, [[watermark]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         :ok <- event_cursor_not_ahead(after_revision, watermark),
         {:ok, [[epoch]]} <- query(db, "SELECT value FROM meta WHERE key = 'authority_epoch'"),
         {:ok, rows} <- event_rows(db, principal_id, after_revision, watermark, page_size + 1),
         {:ok, items} <- event_items(Enum.take(rows, page_size)) do
      more? = length(rows) > page_size
      next_after = if more?, do: List.last(items)["revision"], else: watermark

      {:ok,
       %{
         authority_epoch: epoch,
         watermark: watermark,
         items: items,
         next_after: next_after,
         has_more: more?
       }}
    else
      false ->
        {:error, :permission_denied}

      {:error, reason}
      when reason in [
             :invalid_events_request,
             :invalid_event_cursor,
             :invalid_credential,
             :unauthorized,
             :permission_denied,
             :corrupt_principal,
             :corrupt_value
           ] ->
        {:error, reason}

      _ ->
        {:error, :store_unavailable}
    end
  end

  defp request_events_page_result(db, credential, after_revision, page_size) do
    with :ok <- valid_events_request(after_revision, page_size),
         {:ok, hash} <- Registry.credential_hash(credential),
         {:ok, principal_id, _permissions} <- authenticate(db, hash),
         {:ok, [[watermark]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         :ok <- event_cursor_not_ahead(after_revision, watermark),
         {:ok, [[epoch]]} <- query(db, "SELECT value FROM meta WHERE key = 'authority_epoch'"),
         {:ok, rows} <-
           query(
             db,
             "SELECT authority_epoch, operation_id, disposition, reason, revision FROM request_journal WHERE principal_id = ? AND revision > ? AND revision <= ? ORDER BY revision LIMIT ?",
             [principal_id, after_revision, watermark, page_size + 1]
           ),
         {:ok, items} <- request_event_items(Enum.take(rows, page_size)) do
      more? = length(rows) > page_size
      next_after = if more?, do: List.last(items)["revision"], else: watermark

      {:ok,
       %{
         authority_epoch: epoch,
         watermark: watermark,
         items: items,
         next_after: next_after,
         has_more: more?
       }}
    else
      {:error, reason}
      when reason in [
             :invalid_events_request,
             :invalid_event_cursor,
             :invalid_credential,
             :unauthorized,
             :corrupt_principal,
             :corrupt_receipt
           ] ->
        {:error, reason}

      _ ->
        {:error, :store_unavailable}
    end
  end

  defp request_event_items(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn
      [epoch, operation_id, disposition, reason, revision], {:ok, items}
      when is_integer(epoch) and epoch >= 0 and is_binary(operation_id) and
             is_integer(revision) and revision >= 0 ->
        if Id.valid?(operation_id) and
             ((disposition == "held" and is_nil(reason)) or
                (disposition == "rejected" and is_binary(reason) and byte_size(reason) <= 128)) do
          item = %{
            "authority_epoch" => epoch,
            "operation_id" => operation_id,
            "disposition" => disposition,
            "reason" => reason,
            "revision" => revision
          }

          {:cont, {:ok, [item | items]}}
        else
          {:halt, {:error, :corrupt_receipt}}
        end

      _, _ ->
        {:halt, {:error, :corrupt_receipt}}
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp valid_events_request(after_revision, page_size) do
    if is_integer(after_revision) and after_revision >= 0 and after_revision <= @max_i64 and
         is_integer(page_size) and page_size >= 1 and page_size <= 100,
       do: :ok,
       else: {:error, :invalid_events_request}
  end

  defp event_cursor_not_ahead(after_revision, watermark) when after_revision <= watermark,
    do: :ok

  defp event_cursor_not_ahead(_after_revision, _watermark),
    do: {:error, :invalid_event_cursor}

  defp event_rows(db, principal_id, after_revision, watermark, limit) do
    query(
      db,
      "SELECT j.thing_id, j.capability_key, j.profile_ref, j.evidence_ref, j.source_epoch, j.source_sequence, j.boot_epoch, j.source_time_utc_ms, j.received_time_utc_ms, j.received_monotonic_ms, j.quality, j.trust, j.value_kind, j.value_a, j.value_b, j.revision FROM journal j JOIN principal_targets g ON g.thing_id = j.thing_id JOIN enrolled_things t ON t.thing_id = j.thing_id WHERE g.principal_id = ? AND t.status = 'active' AND j.event_type = 'observation' AND j.revision > ? AND j.revision <= ? ORDER BY j.revision LIMIT ?",
      [principal_id, after_revision, watermark, limit]
    )
  end

  defp event_items(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn
      [thing_id, capability_key | rest], {:ok, items} ->
        case decode_current(thing_id, capability_key, rest) do
          {:ok, observation, revision} ->
            [profile_ref, evidence_ref | _] = rest
            item = observation_item(observation, revision, profile_ref, evidence_ref)
            {:cont, {:ok, [item | items]}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp valid_history_request(thing_id, capability_key, watermark, after_revision, page_size) do
    valid_watermark =
      is_nil(watermark) or
        (is_integer(watermark) and watermark >= 0 and watermark <= @max_i64)

    if Id.valid?(thing_id) and Id.valid?(capability_key) and valid_watermark and
         is_integer(after_revision) and after_revision >= 0 and after_revision <= @max_i64 and
         is_integer(page_size) and page_size >= 1 and page_size <= 100,
       do: :ok,
       else: {:error, :invalid_history_request}
  end

  defp history_rows(db, thing_id, capability_key, after_revision, watermark, limit) do
    query(
      db,
      "SELECT profile_ref, evidence_ref, source_epoch, source_sequence, boot_epoch, source_time_utc_ms, received_time_utc_ms, received_monotonic_ms, quality, trust, value_kind, value_a, value_b, revision FROM journal WHERE thing_id = ? AND capability_key = ? AND revision > ? AND revision <= ? ORDER BY revision LIMIT ?",
      [thing_id, capability_key, after_revision, watermark, limit]
    )
  end

  defp history_items(rows, thing_id, capability_key) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, items} ->
      case decode_current(thing_id, capability_key, row) do
        {:ok, observation, revision} ->
          [profile_ref, evidence_ref | _] = row

          item =
            observation_item(observation, revision, profile_ref, evidence_ref)

          {:cont, {:ok, [item | items]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp valid_catalogue_request(watermark, after_id, page_size) do
    valid_watermark =
      is_nil(watermark) or
        (is_integer(watermark) and watermark >= 0 and watermark <= @max_i64)

    if valid_watermark and (is_nil(after_id) or Id.valid?(after_id)) and
         (is_nil(after_id) or not is_nil(watermark)) and is_integer(page_size) and
         page_size >= 1 and page_size <= 10,
       do: :ok,
       else: {:error, :invalid_catalogue_request}
  end

  defp catalogue_rows(db, principal_id, after_id, limit) do
    query(
      db,
      "SELECT t.thing_id, t.profile_ref, t.document, t.resource_revision FROM enrolled_things t JOIN principal_targets g ON g.thing_id = t.thing_id WHERE g.principal_id = ? AND t.status = 'active' AND t.thing_id > ? ORDER BY t.thing_id LIMIT ?",
      [principal_id, after_id, limit]
    )
  end

  defp catalogue_items(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn
      [thing_id, profile_ref, document, resource_revision], {:ok, items} ->
        with {:ok, %Thing{id: ^thing_id, profile_ref: ^profile_ref}} <-
               Registry.decode_thing(document),
             true <- is_integer(resource_revision) and resource_revision >= 0,
             {:ok, declaration} <- JSON.decode(document) do
          item = Map.put(declaration, "resource_revision", resource_revision)
          {:cont, {:ok, [item | items]}}
        else
          _ -> {:halt, {:error, :corrupt_enrollment}}
        end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp valid_snapshot_request(watermark, after_key, page_size) do
    valid_watermark =
      is_nil(watermark) or
        (is_integer(watermark) and watermark >= 0 and watermark <= @max_i64)

    valid_after =
      is_nil(after_key) or
        (is_map(after_key) and map_size(after_key) == 2 and
           Id.valid?(after_key["thing_id"]) and Id.valid?(after_key["capability_key"]))

    if valid_watermark and valid_after and is_integer(page_size) and page_size >= 1 and
         page_size <= 100 and (is_nil(after_key) or not is_nil(watermark)),
       do: :ok,
       else: {:error, :invalid_snapshot_request}
  end

  defp snapshot_watermark(nil, _revision), do: :ok
  defp snapshot_watermark(revision, revision), do: :ok
  defp snapshot_watermark(_watermark, _revision), do: {:error, :resnapshot_required}

  defp snapshot_rows(db, principal_id, after_key, limit) do
    {thing_id, capability_key} =
      case after_key do
        nil ->
          {"", ""}

        %{"thing_id" => thing_id, "capability_key" => capability_key} ->
          {thing_id, capability_key}
      end

    query(
      db,
      "SELECT c.thing_id, c.capability_key, c.profile_ref, c.evidence_ref, c.source_epoch, c.source_sequence, c.boot_epoch, c.source_time_utc_ms, c.received_time_utc_ms, c.received_monotonic_ms, c.quality, c.trust, c.value_kind, c.value_a, c.value_b, c.revision FROM observation_current c JOIN principal_targets g ON g.thing_id = c.thing_id JOIN enrolled_things t ON t.thing_id = c.thing_id WHERE g.principal_id = ? AND t.status = 'active' AND (c.thing_id > ? OR (c.thing_id = ? AND c.capability_key > ?)) ORDER BY c.thing_id, c.capability_key LIMIT ?",
      [principal_id, thing_id, thing_id, capability_key, limit]
    )
  end

  defp snapshot_items(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn
      [thing_id, capability_key | rest], {:ok, items} ->
        case decode_current(thing_id, capability_key, rest) do
          {:ok, observation, revision} ->
            [profile_ref, evidence_ref | _] = rest
            item = observation_item(observation, revision, profile_ref, evidence_ref)

            {:cont, {:ok, [item | items]}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp observation_item(observation, revision, profile_ref, evidence_ref) do
    %{
      "thing_id" => observation.thing_id,
      "capability_key" => observation.capability_key,
      "profile_ref" => profile_ref,
      "evidence_ref" => evidence_ref,
      "value" => snapshot_value(observation.value),
      "quality" => observation.quality,
      "trust" => observation.trust,
      "source_epoch" => observation.source_epoch,
      "source_sequence" => observation.source_sequence,
      "boot_epoch" => observation.boot_epoch,
      "source_time_utc_ms" => observation.source_time_utc_ms,
      "received_time_utc_ms" => observation.received_time_utc_ms,
      "received_monotonic_ms" => observation.received_monotonic_ms,
      "revision" => revision
    }
  end

  defp snapshot_value(nil), do: nil

  defp snapshot_value(%Value{kind: :boolean, data: value}),
    do: %{"type" => "boolean", "value" => value}

  defp snapshot_value(%Value{kind: :fraction, data: ppm}),
    do: %{"type" => "fraction", "ppm" => ppm}

  defp snapshot_value(%Value{kind: :kelvin, data: kelvin}),
    do: %{"type" => "kelvin", "kelvin" => kelvin}

  defp snapshot_value(%Value{kind: :hsv, data: {hue, saturation}}),
    do: %{"type" => "hsv", "hue_mdeg" => hue, "saturation_ppm" => saturation}

  defp snapshot_value(%Value{kind: :xy, data: {x, y}}),
    do: %{"type" => "xy", "x_ppm" => x, "y_ppm" => y}

  defp snapshot_value(%Value{kind: :smoke_state, data: state}),
    do: %{"type" => "smoke_state", "state" => state}

  defp health_result(state) do
    with {:ok, [[revision]]} <- query(state.db, "SELECT value FROM meta WHERE key = 'revision'"),
         {:ok, [[epoch]]} <-
           query(state.db, "SELECT value FROM meta WHERE key = 'authority_epoch'"),
         {:ok, [[held_count]]} <-
           query(state.db, "SELECT COUNT(*) FROM request_outbox WHERE state = 'held'"),
         {:ok, [[thing_count]]} <-
           query(state.db, "SELECT COUNT(*) FROM enrolled_things WHERE status = 'active'"),
         {:ok, [[principal_count]]} <-
           query(state.db, "SELECT COUNT(*) FROM principals WHERE status = 'active'"),
         true <-
           is_integer(revision) and revision >= 0 and is_integer(epoch) and epoch >= 1 and
             Enum.all?([held_count, thing_count, principal_count], &is_integer/1) do
      {:ok,
       %{
         store_revision: revision,
         authority_epoch: epoch,
         held_requests: held_count,
         active_things: thing_count,
         active_principals: principal_count,
         writable: state.writable,
         dispatch_enabled: false
       }}
    else
      _ -> {:error, :store_unavailable}
    end
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

      {:error, :corrupt_receipt} ->
        {:reply, {:error, :corrupt_receipt}, %{state | writable: false}}

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

  defp narrow_thing_tx(db, thing, document, expected_revision) do
    with {:ok, current, ^expected_revision} <- enrolled_thing(db, thing.id),
         true <- narrower_declaration?(current, thing),
         false <- current == thing,
         {:ok, held} <- held_for_thing(db, thing.id),
         {:ok, revision} <- next_revision(db),
         {:ok, []} <- query(db, "DELETE FROM source_epoch_grants WHERE thing_id = ?", [thing.id]),
         {:ok, []} <- query(db, "DELETE FROM observation_current WHERE thing_id = ?", [thing.id]),
         {:ok, []} <-
           query(
             db,
             "UPDATE enrolled_things SET document = ?, resource_revision = ? WHERE thing_id = ? AND resource_revision = ? AND status = 'active'",
             [document, expected_revision + 1, thing.id, expected_revision]
           ),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         :ok <- authority_event(db, revision, "thing_narrowed", thing.id),
         {:ok, final_revision} <- reject_held_batch(db, held, "declaration_changed") do
      {:commit, {:ok, final_revision}}
    else
      {:ok, _current, _revision} -> {:rollback, {:policy, :stale_resource_revision}}
      {:error, :target_unavailable} -> {:rollback, {:policy, :target_unavailable}}
      false -> {:rollback, {:policy, :declaration_widening}}
      true -> {:rollback, {:policy, :unchanged_declaration}}
      {:error, reason} -> {:rollback, reason}
      _ -> {:rollback, :corrupt_enrollment}
    end
  end

  defp narrower_declaration?(current, next) do
    current.id == next.id and current.role == next.role and
      current.profile_ref == next.profile_ref and
      MapSet.new(Map.keys(current.capabilities)) == MapSet.new(Map.keys(next.capabilities)) and
      Enum.all?(current.capabilities, fn {key, old} ->
        new = Map.fetch!(next.capabilities, key)

        old.thing_id == new.thing_id and old.role == new.role and old.key == new.key and
          old.value_kind == new.value_kind and old.unit == new.unit and
          old.risk_class == new.risk_class and old.profile_ref == new.profile_ref and
          old.extensions == new.extensions and new.freshness_ms <= old.freshness_ms and
          Enum.all?(new.operations, &(&1 in old.operations)) and
          narrower_constraints?(old.constraints, new.constraints)
      end)
  end

  defp narrower_constraints?(
         %{"min" => old_min, "max" => old_max},
         %{"min" => new_min, "max" => new_max}
       ),
       do: new_min >= old_min and new_max <= old_max

  defp narrower_constraints?(old, new), do: old == new

  defp held_for_thing(db, thing_id) do
    query(
      db,
      "SELECT o.principal_id, o.authority_epoch, o.operation_id FROM request_outbox o JOIN request_receipts r ON r.principal_id = o.principal_id AND r.authority_epoch = o.authority_epoch AND r.operation_id = o.operation_id WHERE o.state = 'held' AND r.disposition = 'held' AND r.target_id = ? ORDER BY o.principal_id, o.authority_epoch, o.operation_id",
      [thing_id]
    )
  end

  defp revoke_thing_tx(db, thing_id) do
    case query(db, "SELECT status FROM enrolled_things WHERE thing_id = ?", [thing_id]) do
      {:ok, [["active"]]} ->
        with {:ok, held} <- held_for_thing(db, thing_id),
             {:ok, revision} <- next_revision(db),
             {:ok, []} <-
               query(db, "DELETE FROM source_epoch_grants WHERE thing_id = ?", [thing_id]),
             {:ok, []} <-
               query(db, "UPDATE enrolled_things SET status = 'revoked' WHERE thing_id = ?", [
                 thing_id
               ]),
             :ok <- authority_event(db, revision, "thing_revoked", thing_id),
             {:ok, final_revision} <- reject_held_batch(db, held, "target_revoked") do
          {:commit, {:ok, final_revision}}
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
        with {:ok, held} <-
               query(
                 db,
                 "SELECT principal_id, authority_epoch, operation_id FROM request_outbox WHERE state = 'held' AND principal_id = ? ORDER BY authority_epoch, operation_id",
                 [principal_id]
               ),
             {:ok, revision} <- next_revision(db),
             {:ok, []} <-
               query(db, "UPDATE principals SET status = 'revoked' WHERE principal_id = ?", [
                 principal_id
               ]),
             :ok <- authority_event(db, revision, "principal_revoked", principal_id),
             {:ok, final_revision} <- reject_held_batch(db, held, "principal_revoked") do
          {:commit, {:ok, final_revision}}
        else
          {:error, reason} -> {:rollback, reason}
        end

      {:ok, _} ->
        {:rollback, {:policy, :principal_unavailable}}

      {:error, reason} ->
        {:rollback, reason}
    end
  end

  defp revoke_target_grant_tx(db, principal_id, thing_id) do
    with {:ok, [["active"]]} <-
           query(db, "SELECT status FROM principals WHERE principal_id = ?", [principal_id]),
         {:ok, [[^thing_id]]} <-
           query(
             db,
             "SELECT thing_id FROM principal_targets WHERE principal_id = ? AND thing_id = ?",
             [principal_id, thing_id]
           ),
         {:ok, held} <-
           query(
             db,
             "SELECT o.principal_id, o.authority_epoch, o.operation_id FROM request_outbox o JOIN request_receipts r ON r.principal_id = o.principal_id AND r.authority_epoch = o.authority_epoch AND r.operation_id = o.operation_id WHERE o.state = 'held' AND r.disposition = 'held' AND o.principal_id = ? AND r.target_id = ? ORDER BY o.authority_epoch, o.operation_id",
             [principal_id, thing_id]
           ),
         {:ok, revision} <- next_revision(db),
         {:ok, []} <-
           query(
             db,
             "DELETE FROM principal_targets WHERE principal_id = ? AND thing_id = ?",
             [principal_id, thing_id]
           ),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         :ok <-
           authority_event(db, revision, "target_grant_revoked", "#{principal_id}/#{thing_id}"),
         {:ok, final_revision} <- reject_held_batch(db, held, "target_grant_revoked") do
      {:commit, {:ok, final_revision}}
    else
      {:ok, _} -> {:rollback, {:policy, :target_grant_unavailable}}
      {:error, reason} -> {:rollback, reason}
      _ -> {:rollback, :corrupt_principal}
    end
  end

  defp rotate_principal_credential_tx(db, principal_id, hash, credential) do
    with {:ok, [["active"]]} <-
           query(db, "SELECT status FROM principals WHERE principal_id = ?", [principal_id]),
         {:ok, held} <-
           query(
             db,
             "SELECT principal_id, authority_epoch, operation_id FROM request_outbox WHERE state = 'held' AND principal_id = ? ORDER BY authority_epoch, operation_id",
             [principal_id]
           ),
         {:ok, revision} <- next_revision(db),
         {:ok, []} <-
           query(
             db,
             "UPDATE principals SET credential_hash = ? WHERE principal_id = ? AND status = 'active'",
             [hash, principal_id]
           ),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         :ok <- authority_event(db, revision, "principal_credential_rotated", principal_id),
         {:ok, final_revision} <- reject_held_batch(db, held, "credential_rotated") do
      {:commit, {:ok, credential, final_revision}}
    else
      {:ok, _} -> {:rollback, {:policy, :principal_unavailable}}
      {:error, reason} -> {:rollback, reason}
      _ -> {:rollback, :corrupt_principal}
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

  defp authorize_source_epoch_tx(
         db,
         thing_id,
         capability_key,
         old_epoch,
         new_epoch,
         current_revision
       ) do
    with {:ok, thing, _resource_revision} <- enrolled_thing(db, thing_id),
         {:ok, _capability} <- Thing.capability(thing, capability_key),
         {:ok, rows} <- query(db, @select_current, [thing_id, capability_key]),
         :ok <- current_epoch_matches(rows, old_epoch, current_revision),
         {:ok, existing} <-
           query(
             db,
             "SELECT old_epoch, new_epoch, current_revision, grant_revision FROM source_epoch_grants WHERE thing_id = ? AND capability_key = ?",
             [thing_id, capability_key]
           ) do
      case existing do
        [[^old_epoch, ^new_epoch, ^current_revision, revision]] ->
          {:rollback, {:unchanged, {:ok, revision}}}

        _ ->
          with {:ok, revision} <- next_revision(db),
               {:ok, []} <-
                 query(
                   db,
                   "INSERT INTO source_epoch_grants VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(thing_id, capability_key) DO UPDATE SET old_epoch=excluded.old_epoch, new_epoch=excluded.new_epoch, current_revision=excluded.current_revision, grant_revision=excluded.grant_revision",
                   [thing_id, capability_key, old_epoch, new_epoch, current_revision, revision]
                 ),
               :ok <-
                 authority_event(
                   db,
                   revision,
                   "source_epoch_granted",
                   "#{thing_id}/#{capability_key}"
                 ) do
            {:commit, {:ok, revision}}
          else
            {:error, reason} -> {:rollback, reason}
          end
      end
    else
      :error -> {:rollback, {:policy, :unsupported_capability}}
      {:error, :target_unavailable} -> {:rollback, {:policy, :target_unavailable}}
      {:error, {:policy, _} = policy} -> {:rollback, policy}
      {:error, reason} -> {:rollback, reason}
    end
  end

  defp current_epoch_matches([], _old_epoch, _revision),
    do: {:error, {:policy, :no_current_observation}}

  defp current_epoch_matches([row], old_epoch, revision) do
    if Enum.at(row, 2) == old_epoch and List.last(row) == revision,
      do: :ok,
      else: {:error, {:policy, :stale_source_epoch}}
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

  defp cancel_request_tx(db, hash, authority_epoch, operation_id) do
    with {:ok, principal_id, _permissions} <- authenticate(db, hash),
         {:ok, rows} <- select_request(db, principal_id, authority_epoch, operation_id) do
      case rows do
        [] ->
          {:rollback, {:unchanged, :not_found}}

        [row] ->
          with {:ok, receipt} <- decode_receipt(principal_id, authority_epoch, operation_id, row) do
            if receipt.disposition == :held,
              do: cancel_held_tx(db, receipt),
              else: {:rollback, {:unchanged, {:ok, receipt}}}
          else
            {:error, reason} -> {:rollback, reason}
          end
      end
    else
      {:error, reason} when reason in [:corrupt_principal, :corrupt_receipt] ->
        {:rollback, reason}

      {:error, reason} ->
        {:rollback, {:policy, reason}}
    end
  end

  defp cancel_held_tx(db, receipt) do
    case reject_held(
           db,
           receipt.principal_id,
           receipt.authority_epoch,
           receipt.operation_id,
           "cancelled"
         ) do
      {:ok, revision} ->
        {:commit,
         {:ok, %{receipt | disposition: :rejected, reason: "cancelled", revision: revision}}}

      {:error, reason} ->
        {:rollback, reason}
    end
  end

  defp reject_held_batch(db, held, reason) do
    with {:ok, [[revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'") do
      Enum.reduce_while(held, {:ok, revision}, fn
        [principal_id, authority_epoch, operation_id], {:ok, _revision} ->
          case reject_held(db, principal_id, authority_epoch, operation_id, reason) do
            {:ok, next} -> {:cont, {:ok, next}}
            {:error, error} -> {:halt, {:error, error}}
          end

        _, _ ->
          {:halt, {:error, :corrupt_receipt}}
      end)
    end
  end

  defp reject_held(db, principal_id, authority_epoch, operation_id, reason) do
    with {:ok, revision} <- next_revision(db),
         {:ok, []} <-
           query(
             db,
             "DELETE FROM request_outbox WHERE principal_id = ? AND authority_epoch = ? AND operation_id = ? AND state = 'held'",
             [principal_id, authority_epoch, operation_id]
           ),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         {:ok, []} <-
           query(
             db,
             "UPDATE request_receipts SET disposition = 'rejected', reason = ?, revision = ? WHERE principal_id = ? AND authority_epoch = ? AND operation_id = ? AND disposition = 'held'",
             [reason, revision, principal_id, authority_epoch, operation_id]
           ),
         {:ok, [[1]]} <- query(db, "SELECT changes()"),
         {:ok, []} <-
           query(db, "INSERT INTO request_journal VALUES (?, ?, ?, ?, 'rejected', ?)", [
             revision,
             principal_id,
             authority_epoch,
             operation_id,
             reason
           ]),
         {:ok, []} <- query(db, "UPDATE meta SET value = ? WHERE key = 'revision'", [revision]) do
      {:ok, revision}
    else
      {:error, error} -> {:error, error}
      _ -> {:error, :corrupt_receipt}
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
         {:ok, [[revision]]} <- query(db, "SELECT value FROM meta WHERE key = 'revision'"),
         {:ok, {disposition, reason}} <-
           request_decision(db, principal_id, store_epoch, mutation, thing, context) do
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

  defp request_decision(_db, _principal_id, store_epoch, mutation, _thing, _context)
       when store_epoch != mutation.authority_epoch,
       do: {:ok, {"rejected", "stale_authority_epoch"}}

  defp request_decision(db, principal_id, _store_epoch, mutation, thing, context) do
    case Policy.check(mutation, thing, context) do
      :ok -> held_capacity(db, principal_id)
      {:error, reason} -> {:ok, {"rejected", Atom.to_string(reason)}}
    end
  end

  defp held_capacity(db, principal_id) do
    with {:ok, [[principal_count]]} <-
           query(db, "SELECT COUNT(*) FROM request_outbox WHERE principal_id = ?", [principal_id]),
         {:ok, [[global_count]]} <- query(db, "SELECT COUNT(*) FROM request_outbox") do
      if principal_count < 32 and global_count < 1_024,
        do: {:ok, {"held", nil}},
        else: {:ok, {"rejected", "pending_capacity"}}
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
    with {:ok, thing, _resource_revision} <- enrolled_thing(db, observation.thing_id),
         {:ok, declared} <- Thing.capability(thing, observation.capability_key),
         true <- declared == capability,
         {:ok, rows} <-
           query(db, @select_current, [observation.thing_id, observation.capability_key]),
         :ok <- check_previous(db, rows, observation, capability),
         {:commit, result} <- insert_record(db, observation, capability),
         :ok <- maybe_consume_source_epoch_grant(db, rows, observation) do
      {:commit, result}
    else
      :error -> {:rollback, {:policy, :unsupported_capability}}
      false -> {:rollback, {:policy, :capability_mismatch}}
      {:error, :target_unavailable} -> {:rollback, {:policy, :target_unavailable}}
      {:duplicate, revision} -> {:rollback, {:duplicate, revision}}
      {:reject, reason} -> {:rollback, {:policy, reason}}
      {:rollback, reason} -> {:rollback, reason}
      {:error, reason} -> {:rollback, reason}
    end
  end

  defp valid_record_batch(thing, observations)
       when is_list(observations) and length(observations) in 1..32 do
    with {:ok, _document} <- Registry.encode_thing(thing),
         true <-
           Enum.all?(observations, fn
             %Observation{thing_id: id} -> id == thing.id
             _ -> false
           end),
         true <-
           observations
           |> Enum.map(& &1.capability_key)
           |> then(&(length(&1) == length(Enum.uniq(&1)))),
         true <- one_report_event?(observations) do
      Enum.reduce_while(observations, {:ok, []}, fn observation, {:ok, pairs} ->
        case Thing.capability(thing, observation.capability_key) do
          {:ok, capability} ->
            if Observation.valid?(observation, capability) do
              {:cont, {:ok, [{observation, capability} | pairs]}}
            else
              {:halt, {:error, :invalid_observation_batch}}
            end

          :error ->
            {:halt, {:error, :invalid_observation_batch}}
        end
      end)
      |> case do
        {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
        error -> error
      end
    else
      _ -> {:error, :invalid_observation_batch}
    end
  end

  defp valid_record_batch(_thing, _observations), do: {:error, :invalid_observation_batch}

  defp one_report_event?([first | rest]) do
    identity = report_event_identity(first)
    Enum.all?(rest, &(report_event_identity(&1) == identity))
  end

  defp report_event_identity(observation) do
    {observation.source_epoch, observation.source_sequence, observation.boot_epoch,
     observation.source_time_utc_ms, observation.received_time_utc_ms,
     observation.received_monotonic_ms, observation.quality, observation.trust}
  end

  defp record_batch_tx(db, pairs) do
    Enum.reduce_while(pairs, {[], 0, 0}, fn {observation, capability},
                                            {revisions, new_count, duplicate_count} ->
      case record_tx(db, observation, capability) do
        {:commit, {:ok, revision}} ->
          {:cont, {[revision | revisions], new_count + 1, duplicate_count}}

        {:rollback, {:duplicate, revision}} ->
          {:cont, {[revision | revisions], new_count, duplicate_count + 1}}

        {:rollback, reason} ->
          {:halt, {:rollback, reason}}
      end
    end)
    |> case do
      {revisions, new_count, 0} when new_count > 0 ->
        {:commit, {:ok, Enum.reverse(revisions)}}

      {revisions, 0, duplicate_count} when duplicate_count > 0 ->
        {:rollback, {:unchanged, {:duplicate, Enum.reverse(revisions)}}}

      {_revisions, _new_count, _duplicate_count} ->
        {:rollback, {:policy, :partial_batch_replay}}

      {:rollback, reason} ->
        {:rollback, reason}
    end
  end

  defp check_previous(_db, [], _observation, _capability), do: :ok

  defp check_previous(db, [row], observation, capability) do
    [profile_ref, evidence_ref, source_epoch, source_sequence | _rest] = row

    cond do
      profile_ref != capability.profile_ref or evidence_ref != capability.evidence_ref ->
        {:reject, :profile_changed}

      source_epoch != observation.source_epoch ->
        source_epoch_granted?(db, row, observation)

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

  defp source_epoch_granted?(db, row, observation) do
    source_epoch = Enum.at(row, 2)
    current_revision = List.last(row)

    case query(
           db,
           "SELECT grant_revision FROM source_epoch_grants WHERE thing_id = ? AND capability_key = ? AND old_epoch = ? AND new_epoch = ? AND current_revision = ?",
           [
             observation.thing_id,
             observation.capability_key,
             source_epoch,
             observation.source_epoch,
             current_revision
           ]
         ) do
      {:ok, [[grant_revision]]} when is_integer(grant_revision) -> :ok
      {:ok, _} -> {:reject, :source_epoch_changed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_consume_source_epoch_grant(_db, [], _observation), do: :ok

  defp maybe_consume_source_epoch_grant(db, [row], observation) do
    if Enum.at(row, 2) == observation.source_epoch do
      :ok
    else
      with {:ok, []} <-
             query(
               db,
               "DELETE FROM source_epoch_grants WHERE thing_id = ? AND capability_key = ? AND old_epoch = ? AND new_epoch = ? AND current_revision = ?",
               [
                 observation.thing_id,
                 observation.capability_key,
                 Enum.at(row, 2),
                 observation.source_epoch,
                 List.last(row)
               ]
             ),
           {:ok, [[1]]} <- query(db, "SELECT changes()") do
        :ok
      else
        _ -> {:error, :corrupt_source_epoch_grant}
      end
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
         true <-
           valid_persisted_observation?(
             thing_id,
             capability_key,
             source_epoch,
             source_sequence,
             boot_epoch,
             source_time,
             received_time,
             received_mono,
             quality,
             trust,
             value,
             revision
           ) do
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

  defp valid_persisted_observation?(
         thing_id,
         capability_key,
         source_epoch,
         source_sequence,
         boot_epoch,
         source_time,
         received_time,
         received_mono,
         quality,
         trust,
         value,
         revision
       ) do
    Id.valid?(thing_id) and Id.valid?(capability_key) and Id.valid?(source_epoch) and
      Id.valid?(boot_epoch) and valid_stored_integer?(source_sequence) and
      (is_nil(source_time) or valid_stored_integer?(source_time)) and
      valid_stored_integer?(received_time) and valid_stored_integer?(received_mono) and
      valid_stored_integer?(revision) and quality in ["reported", "unknown"] and
      trust in [
        "unauthenticated_local",
        "authenticated_device",
        "bridge_attested",
        "synthetic_lab"
      ] and
      ((quality == "unknown" and is_nil(value)) or
         (quality == "reported" and match?(%Value{}, value) and Value.valid?(value)))
  end

  defp valid_stored_integer?(value),
    do: is_integer(value) and value >= 0 and value <= @max_i64

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
             :ok <- Sqlite3.execute(db, @source_epoch_schema),
             :ok <- Sqlite3.execute(db, "PRAGMA user_version=4") do
          validate_schema(db)
        else
          other -> {:error, {:schema_failed, other}}
        end

      {:ok, [[1]]} ->
        with :ok <- validate_observation_schema(db),
             :ok <- Sqlite3.execute(db, @request_schema),
             :ok <- Sqlite3.execute(db, @authority_schema),
             :ok <- Sqlite3.execute(db, @source_epoch_schema),
             :ok <- Sqlite3.execute(db, "PRAGMA user_version=4") do
          validate_schema(db)
        else
          other -> {:error, {:schema_failed, other}}
        end

      {:ok, [[2]]} ->
        with :ok <- validate_request_schema(db),
             :ok <- Sqlite3.execute(db, @authority_schema),
             :ok <- Sqlite3.execute(db, @source_epoch_schema),
             :ok <- Sqlite3.execute(db, "PRAGMA user_version=4") do
          validate_schema(db)
        else
          other -> {:error, {:schema_failed, other}}
        end

      {:ok, [[3]]} ->
        with :ok <- Sqlite3.execute(db, @source_epoch_schema),
             :ok <- Sqlite3.execute(db, "PRAGMA user_version=4") do
          validate_schema(db)
        else
          other -> {:error, {:schema_failed, other}}
        end

      {:ok, [[4]]} ->
        validate_schema(db)

      {:ok, [[_other]]} ->
        {:error, :unsupported_schema_version}

      other ->
        {:error, {:schema_failed, other}}
    end
  end

  @doc "Read-only Store consistency check for an already version-matched SQLite snapshot."
  @spec validate_snapshot(Sqlite3.db()) :: :ok | {:error, atom() | tuple()}
  def validate_snapshot(db), do: validate_schema(db)

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
         {:ok, [[orphan_held]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM request_receipts r WHERE r.disposition = 'held' AND NOT EXISTS (SELECT 1 FROM request_outbox o WHERE o.principal_id = r.principal_id AND o.authority_epoch = r.authority_epoch AND o.operation_id = r.operation_id AND o.state = 'held')"
           ),
         {:ok, [[orphan_outbox]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM request_outbox o JOIN request_receipts r ON r.principal_id = o.principal_id AND r.authority_epoch = o.authority_epoch AND r.operation_id = o.operation_id WHERE r.disposition != 'held'"
           ),
         {:ok, [[_enrolled_count]]} <- query(db, "SELECT COUNT(*) FROM enrolled_things"),
         {:ok, [[_principal_count]]} <- query(db, "SELECT COUNT(*) FROM principals"),
         {:ok, [[_source_epoch_grant_count]]} <-
           query(db, "SELECT COUNT(*) FROM source_epoch_grants"),
         {:ok, [[invalid_source_epoch_grants]]} <-
           query(
             db,
             "SELECT COUNT(*) FROM source_epoch_grants g LEFT JOIN enrolled_things t ON t.thing_id = g.thing_id WHERE g.old_epoch = g.new_epoch OR g.current_revision < 0 OR g.grant_revision <= g.current_revision OR g.grant_revision > ? OR t.status IS NULL OR t.status != 'active'",
             [revision]
           ),
         {:ok, [[epoch]]} <- query(db, "SELECT value FROM meta WHERE key = 'authority_epoch'"),
         {:ok, []} <- query(db, "PRAGMA foreign_key_check"),
         true <-
           is_integer(epoch) and epoch >= 1 and is_integer(revision) and
             revision == Enum.max([observation_revision, request_revision, authority_revision]) and
             latest_receipt <= revision and latest_current <= revision and orphan_held == 0 and
             orphan_outbox == 0 and invalid_source_epoch_grants == 0 do
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
