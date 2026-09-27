defmodule WotexHome.Durable.Backup do
  @moduledoc """
  Bounded, encrypted, consistent SQLite export and quarantined restore staging.

  The caller supplies a fresh 32-byte key through a trusted local boundary.
  This module never persists or returns that key. It does not restore authority
  or radio credentials. A staged copy cannot start as a Home controller.
  """

  alias Exqlite.Sqlite3
  alias WotexHome.Durable.Store

  @magic "WOHBK1\0"
  @max_plain_bytes 33_554_432
  @schema_version 9
  @max_claim_refs 4_096
  @claim_ref ~r/\Aqualification:[0-9a-f]{64}\z/
  @required_tables ~w(meta observation_current journal request_receipts request_outbox request_journal enrolled_things principals principal_targets authority_journal source_epoch_grants request_execution enrollment_bindings enrollment_review_history profile_qualifications)
  @v7_tables ~w(meta observation_current journal request_receipts request_outbox request_journal enrolled_things principals principal_targets authority_journal source_epoch_grants request_execution enrollment_bindings enrollment_review_history)
  @v6_tables ~w(meta observation_current journal request_receipts request_outbox request_journal enrolled_things principals principal_targets authority_journal source_epoch_grants request_execution enrollment_bindings)
  @v5_tables ~w(meta observation_current journal request_receipts request_outbox request_journal enrolled_things principals principal_targets authority_journal source_epoch_grants request_execution)
  @legacy_tables ~w(meta observation_current journal request_receipts request_outbox request_journal enrolled_things principals principal_targets authority_journal source_epoch_grants)

  @spec export(Sqlite3.db(), String.t(), binary()) :: {:ok, map()} | {:error, atom()}
  def export(db, destination, key)
      when is_binary(destination) and is_binary(key) and byte_size(key) == 32 do
    with true <- Path.type(destination) == :absolute,
         {:ok, [[revision, epoch]]} <-
           query(
             db,
             "SELECT (SELECT value FROM meta WHERE key = 'revision'), (SELECT value FROM meta WHERE key = 'authority_epoch')"
           ),
         true <- valid_identity?(revision, epoch),
         :ok <- within_limit(db),
         {:ok, temporary_directory} <- private_temporary_directory(destination) do
      try do
        export_from_snapshot(db, temporary_directory, destination, key, revision, epoch)
      after
        _ = File.rm_rf(temporary_directory)
      end
    else
      false -> {:error, :invalid_backup_request}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :backup_unavailable}
    end
  end

  def export(_db, _destination, _key), do: {:error, :invalid_backup_request}

  @spec verify(String.t(), binary()) :: {:ok, map()} | {:error, atom()}
  def verify(path, key) when is_binary(path) and is_binary(key) and byte_size(key) == 32 do
    with_verified_db(path, key, fn db, revision, epoch ->
      with {:ok, dependencies} <- external_dependencies(db) do
        {:ok, %{store_revision: revision, authority_epoch: epoch, dependencies: dependencies}}
      end
    end)
  end

  def verify(_path, _key), do: {:error, :invalid_backup}

  @doc "Write a validated archive as a new 0600 SQLite file that Store refuses to start."
  @spec stage_restore(String.t(), binary(), String.t()) :: {:ok, map()} | {:error, atom()}
  def stage_restore(path, key, destination)
      when is_binary(path) and is_binary(key) and byte_size(key) == 32 and
             is_binary(destination) do
    with true <- Path.type(destination) == :absolute and path != destination,
         {:ok, stat} <- File.lstat(Path.dirname(destination)),
         true <- stat.type == :directory and Bitwise.band(stat.mode, 0o777) == 0o700 do
      with_verified_db(path, key, fn db, revision, epoch ->
        with {:ok, dependencies} <- external_dependencies(db),
             {:ok, []} <-
               query(db, "INSERT INTO meta(key, value) VALUES ('restore_quarantine', 1)"),
             {:ok, staged} <- Sqlite3.serialize(db, "main"),
             true <- byte_size(staged) <= @max_plain_bytes,
             :ok <- write_new(destination, staged) do
          {:ok,
           %{
             store_revision: revision,
             authority_epoch: epoch,
             dependencies: dependencies,
             quarantined: true,
             bytes: byte_size(staged)
           }}
        else
          {:error, :backup_exists} -> {:error, :restore_exists}
          _ -> {:error, :restore_unavailable}
        end
      end)
    else
      _ -> {:error, :invalid_restore_request}
    end
  end

  def stage_restore(_path, _key, _destination), do: {:error, :invalid_restore_request}

  defp external_dependencies(db) do
    with {:ok, [[version]]} <- query(db, "PRAGMA user_version"),
         {:ok, refs} <- qualification_refs(db, version) do
      {claim_refs, other_refs} = Enum.split_with(refs, &(&1 =~ @claim_ref))

      {:ok,
       %{
         qualified_profile_rows: length(refs),
         claim_package_refs: Enum.uniq(claim_refs),
         non_claim_qualification_rows: length(other_refs),
         reviewer_keys_required: claim_refs != [],
         raw_qualification_artifacts_included: false,
         device_credentials_and_counters: "external"
       }}
    else
      _ -> {:error, :invalid_backup}
    end
  end

  defp qualification_refs(_db, version) when version in 4..7, do: {:ok, []}

  defp qualification_refs(db, version) when version in 8..9 do
    with {:ok, rows} <-
           query(
             db,
             "SELECT evidence_ref FROM profile_qualifications WHERE status = 'qualified' ORDER BY evidence_ref LIMIT ?",
             [@max_claim_refs + 1]
           ),
         true <- length(rows) <= @max_claim_refs,
         true <- Enum.all?(rows, &match?([ref] when is_binary(ref), &1)) do
      {:ok, Enum.map(rows, &hd/1)}
    else
      _ -> {:error, :invalid_backup}
    end
  end

  defp qualification_refs(_, _), do: {:error, :invalid_backup}

  defp with_verified_db(path, key, fun) do
    with {:ok, stat} <- File.lstat(path),
         true <- stat.type == :regular and stat.size <= @max_plain_bytes + 60,
         {:ok, bytes} <- File.read(path),
         {:ok, revision, epoch, plain} <- decrypt(bytes, key),
         {:ok, db} <- Sqlite3.open(":memory:") do
      try do
        with :ok <- Sqlite3.deserialize(db, "main", plain),
             {:ok, [[schema_version]]} <- query(db, "PRAGMA user_version"),
             {:ok, table_rows} <-
               query(db, "SELECT name FROM sqlite_master WHERE type = 'table'"),
             true <-
               schema_version in [4, 5, 6, 7, 8, @schema_version] and
                 required_tables?(table_rows, schema_version),
             {:ok, [["ok"]]} <- query(db, "PRAGMA integrity_check(1)"),
             {:ok, []} <- query(db, "SELECT 1 FROM pragma_foreign_key_check LIMIT 1"),
             :ok <- Store.validate_snapshot(db),
             {:ok, [[^revision, ^epoch]]} <-
               query(
                 db,
                 "SELECT (SELECT value FROM meta WHERE key = 'revision'), (SELECT value FROM meta WHERE key = 'authority_epoch')"
               ) do
          fun.(db, revision, epoch)
        else
          _ -> {:error, :invalid_backup}
        end
      after
        _ = Sqlite3.close(db)
      end
    else
      _ -> {:error, :invalid_backup}
    end
  end

  defp export_from_snapshot(db, directory, destination, key, revision, epoch) do
    snapshot_path = Path.join(directory, "snapshot.sqlite")

    with {:ok, []} <- query(db, "VACUUM INTO ?", [snapshot_path]),
         {:ok, stat} <- File.stat(snapshot_path),
         true <- stat.type == :regular and stat.size <= @max_plain_bytes,
         {:ok, plain} <- File.read(snapshot_path) do
      nonce = :crypto.strong_rand_bytes(12)

      header =
        <<@magic::binary, revision::unsigned-big-64, epoch::unsigned-big-64,
          nonce::binary-size(12), byte_size(plain)::unsigned-big-32>>

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, plain, header, true)

      payload = <<header::binary, ciphertext::binary, tag::binary-size(16)>>

      case write_new(destination, payload) do
        :ok ->
          {:ok, %{store_revision: revision, authority_epoch: epoch, bytes: byte_size(payload)}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      false -> {:error, :backup_too_large}
      _ -> {:error, :backup_unavailable}
    end
  end

  defp decrypt(
         <<@magic::binary, revision::unsigned-big-64, epoch::unsigned-big-64,
           nonce::binary-size(12), size::unsigned-big-32, rest::binary>> = bytes,
         key
       )
       when size <= @max_plain_bytes and byte_size(rest) == size + 16 do
    <<ciphertext::binary-size(size), tag::binary-size(16)>> = rest
    header_size = byte_size(bytes) - byte_size(rest)
    header = binary_part(bytes, 0, header_size)

    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, ciphertext, header, tag, false) do
      plain when is_binary(plain) -> {:ok, revision, epoch, plain}
      _ -> {:error, :invalid_backup}
    end
  end

  defp decrypt(_bytes, _key), do: {:error, :invalid_backup}

  defp within_limit(db) do
    with {:ok, [[pages]]} <- query(db, "PRAGMA page_count"),
         {:ok, [[page_size]]} <- query(db, "PRAGMA page_size"),
         true <- is_integer(pages) and is_integer(page_size) and pages >= 0 and page_size > 0 do
      if pages * page_size <= @max_plain_bytes,
        do: :ok,
        else: {:error, :backup_too_large}
    else
      _ -> {:error, :backup_unavailable}
    end
  end

  defp private_temporary_directory(destination) do
    directory =
      Path.join(
        Path.dirname(destination),
        ".wotex-backup-#{Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}"
      )

    case File.mkdir(directory) do
      :ok ->
        case File.chmod(directory, 0o700) do
          :ok ->
            {:ok, directory}

          _ ->
            _ = File.rm_rf(directory)
            {:error, :backup_unavailable}
        end

      _ ->
        {:error, :backup_unavailable}
    end
  end

  defp write_new(destination, payload) do
    case File.open(destination, [:write, :binary, :exclusive]) do
      {:ok, file} ->
        result =
          with :ok <- File.chmod(destination, 0o600),
               :ok <- IO.binwrite(file, payload),
               :ok <- :file.sync(file) do
            :ok
          else
            _ -> {:error, :backup_unavailable}
          end

        _ = File.close(file)
        if result != :ok, do: File.rm(destination)
        result

      {:error, :eexist} ->
        {:error, :backup_exists}

      _ ->
        {:error, :backup_unavailable}
    end
  end

  defp valid_identity?(revision, epoch),
    do: is_integer(revision) and revision >= 0 and is_integer(epoch) and epoch >= 1

  defp required_tables?(rows, schema_version) do
    names = MapSet.new(Enum.map(rows, fn [name] -> name end))

    required =
      case schema_version do
        4 -> @legacy_tables
        5 -> @v5_tables
        6 -> @v6_tables
        7 -> @v7_tables
        version when version in [8, 9] -> @required_tables
      end

    Enum.all?(required, &MapSet.member?(names, &1))
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
