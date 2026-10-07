defmodule WotexHome.Durable.Backup do
  @moduledoc """
  Bounded, encrypted, consistent SQLite export and quarantined restore staging.

  The caller supplies a fresh 32-byte key through a trusted local boundary.
  This module never persists or returns that key. It does not restore authority
  or radio credentials. A staged copy cannot start as a Home controller.

  `export/3` takes a consistent Store snapshot and writes an encrypted archive.
  `verify/2` checks the archive before any restore work. `stage_restore/3`
  places a checked database in quarantine for operator review; activation and
  credential reprovisioning are separate procedures.
  """

  alias Exqlite.Sqlite3
  alias WotexHome.Durable.Store
  alias WotexHome.Durable.Store.ProfileWriter
  alias WotexHome.Durable.ProfileRestore
  alias WotexHome.Profiles.{Archive, Custody}

  @magic "WOHBK1\0"
  @profile_magic "WOHBK2\0"
  @max_plain_bytes 33_554_432
  @schema_version 21
  @max_claim_refs 4_096
  @claim_ref ~r/\Aqualification:[0-9a-f]{64}\z/
  @required_tables ~w(meta observation_current journal request_receipts request_outbox request_journal enrolled_things principals principal_targets authority_journal source_epoch_grants request_execution enrollment_bindings enrollment_review_history profile_qualifications operator_override_leases operator_override_operations rule_candidate_reviews request_causal_roots invariant_policy_operations rule_admissions rule_activations request_rule_origins host_maintenance_operations)
  @v18_tables @required_tables
  @profile_tables ~w(portable_profiles profile_operations profile_selection_history profile_current profile_observation_pins profile_request_pins profile_rule_pins profile_qualification_pins)
  @v19_tables @v18_tables ++ @profile_tables
  @v20_tables @v19_tables ++ ["profile_qualification_history"]
  @v21_tables @v20_tables ++ ~w(controller_identity controller_retirements)
  @v17_tables @v18_tables -- ["host_maintenance_operations"]
  @v16_tables @v17_tables -- ~w(rule_admissions rule_activations request_rule_origins)
  @v15_tables @v16_tables -- ["invariant_policy_operations"]
  @v13_tables @v15_tables -- ["request_causal_roots"]
  @v11_tables ~w(meta observation_current journal request_receipts request_outbox request_journal enrolled_things principals principal_targets authority_journal source_epoch_grants request_execution enrollment_bindings enrollment_review_history profile_qualifications operator_override_leases operator_override_operations)
  @v10_tables ~w(meta observation_current journal request_receipts request_outbox request_journal enrolled_things principals principal_targets authority_journal source_epoch_grants request_execution enrollment_bindings enrollment_review_history profile_qualifications operator_override_leases)
  @v9_tables ~w(meta observation_current journal request_receipts request_outbox request_journal enrolled_things principals principal_targets authority_journal source_epoch_grants request_execution enrollment_bindings enrollment_review_history profile_qualifications)
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

  @doc "Store-owner-only inclusive export; every retained exact profile byte is mandatory."
  def export_profiles(db, destination, key, custody)
      when is_binary(destination) and is_binary(key) and byte_size(key) == 32 do
    with true <- Path.type(destination) == :absolute,
         :ok <- within_limit(db),
         {:ok, directory} <- private_temporary_directory(destination) do
      try do
        snapshot = Path.join(directory, "snapshot.sqlite")

        with {:ok, []} <- query(db, "VACUUM INTO ?", [snapshot]),
             {:ok, stat} <- File.lstat(snapshot),
             true <- stat.type == :regular and stat.size <= @max_plain_bytes,
             {:ok, database} <- File.read(snapshot),
             {:ok, copy} <- Sqlite3.open(":memory:") do
          try do
            with :ok <- Sqlite3.deserialize(copy, "main", database),
                 :ok <- Store.validate_snapshot(copy),
                 {:ok, [[revision, epoch]]} <-
                   query(
                     copy,
                     "SELECT (SELECT value FROM meta WHERE key='revision'), (SELECT value FROM meta WHERE key='authority_epoch')"
                   ),
                 true <- valid_identity?(revision, epoch),
                 {:ok, dependencies} <- external_dependencies(copy),
                 {:ok, objects} <- custody_objects(custody, dependencies.profile_artifacts),
                 {:ok, plain} <- Archive.encode(database, objects),
                 payload = encrypt(@profile_magic, revision, epoch, plain, key),
                 :ok <- write_new(destination, payload) do
              {:ok,
               %{
                 store_revision: revision,
                 authority_epoch: epoch,
                 bytes: byte_size(payload),
                 portable_profile_objects: length(objects)
               }}
            else
              {:error, reason} when is_atom(reason) -> {:error, reason}
              _ -> {:error, :backup_unavailable}
            end
          after
            Sqlite3.close(copy)
          end
        else
          _ -> {:error, :backup_unavailable}
        end
      after
        File.rm_rf(directory)
      end
    else
      false -> {:error, :invalid_backup_request}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :backup_unavailable}
    end
  end

  def export_profiles(_, _, _, _), do: {:error, :invalid_backup_request}

  defp custody_objects(_custody, []), do: {:ok, []}

  defp custody_objects(custody, expected) do
    Custody.export_many(custody, expected)
  catch
    :exit, _ -> {:error, :profile_artifact_unavailable}
  end

  @spec verify(String.t(), binary()) :: {:ok, map()} | {:error, atom()}
  def verify(path, key) when is_binary(path) and is_binary(key) and byte_size(key) == 32 do
    with_verified_db(path, key, fn _db, revision, epoch, dependencies, _objects ->
      {:ok, %{store_revision: revision, authority_epoch: epoch, dependencies: dependencies}}
    end)
  end

  def verify(_path, _key), do: {:error, :invalid_backup}

  @doc "Authenticated inclusive archive must retain the complete original retirement receipt."
  def verify_retired_source(path, key, receipt)
      when is_binary(path) and is_binary(key) and byte_size(key) == 32 do
    with {:ok, document} <- WotexHome.Recovery.ControllerCodec.encode("retirement", receipt) do
      with_verified_db(path, key, fn db, revision, epoch, dependencies, objects ->
        with true <- is_list(objects),
             {:ok, %{state: "retired"}} <- WotexHome.Durable.Store.ControllerWriter.identity(db),
             {:ok, [[^document]]} <-
               query(db, "SELECT receipt_document FROM controller_retirements WHERE revision=?", [
                 receipt["revision"]
               ]) do
          {:ok,
           %{
             store_revision: revision,
             authority_epoch: epoch,
             archive_digest: dependencies.archive_digest,
             bytes: dependencies.archive_bytes,
             portable_profile_objects: length(objects)
           }}
        else
          _ -> {:error, :retired_archive_mismatch}
        end
      end)
    end
  end

  def verify_retired_source(_, _, _), do: {:error, :invalid_backup}

  @doc "Trusted inert transfer basis from the exact authenticated inclusive retired snapshot."
  def retired_transfer_basis(path, key)
      when is_binary(path) and is_binary(key) and byte_size(key) == 32 do
    with_verified_db(path, key, fn db, revision, epoch, dependencies, objects ->
      with true <- is_list(objects),
           {:ok, receipt} <- WotexHome.Durable.Store.ControllerWriter.source_receipt(db),
           {:ok, maintenance} <- WotexHome.Durable.Store.MaintenanceWriter.require_active(db),
           {:ok, [[generation]]} <-
             query(db, "SELECT value FROM meta WHERE key='rule_generation'"),
           true <- is_integer(generation) and generation in 1..9_223_372_036_854_775_806,
           {:ok, domains} <- WotexHome.Durable.Store.RecoveryDomains.derive(db, :source) do
        {:ok,
         %{
           retirement_receipt: receipt,
           source_maintenance_revision: maintenance,
           source_rule_generation: generation,
           archive_digest: dependencies.archive_digest,
           snapshot_digest: dependencies.snapshot_digest,
           logical_snapshot_digest: domains.logical_snapshot_digest,
           domains: domains,
           store_revision: revision,
           authority_epoch: epoch,
           profile_artifacts: dependencies.profile_artifacts,
           portable_profile_objects: length(objects)
         }}
      else
        _ -> {:error, :retired_archive_required}
      end
    end)
  end

  def retired_transfer_basis(_, _), do: {:error, :invalid_backup}

  @doc "Write a validated archive as a new 0600 SQLite file that Store refuses to start."
  @spec stage_restore(String.t(), binary(), String.t()) :: {:ok, map()} | {:error, atom()}
  def stage_restore(path, key, destination)
      when is_binary(path) and is_binary(key) and byte_size(key) == 32 and
             is_binary(destination) do
    with true <- Path.type(destination) == :absolute and path != destination,
         {:ok, stat} <- File.lstat(Path.dirname(destination)),
         true <- stat.type == :directory and Bitwise.band(stat.mode, 0o777) == 0o700 do
      with_verified_db(path, key, fn db, revision, epoch, dependencies, objects ->
        with true <- is_nil(objects),
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
          false -> {:error, :profile_restore_required}
          {:error, :backup_exists} -> {:error, :restore_exists}
          _ -> {:error, :restore_unavailable}
        end
      end)
    else
      _ -> {:error, :invalid_restore_request}
    end
  end

  def stage_restore(_path, _key, _destination), do: {:error, :invalid_restore_request}

  @doc "Stage a complete inclusive archive in a new private directory; never restore authority."
  def stage_profile_restore(path, key, destination)
      when is_binary(path) and is_binary(key) and byte_size(key) == 32 and is_binary(destination) do
    with_verified_db(path, key, fn db, revision, epoch, dependencies, objects ->
      with true <- not is_nil(objects) or dependencies.profile_artifacts == [],
           {:ok, []} <- query(db, "INSERT INTO meta(key,value) VALUES ('restore_quarantine',1)"),
           {:ok, database} <- Sqlite3.serialize(db, "main"),
           true <- byte_size(database) <= @max_plain_bytes,
           :ok <- ProfileRestore.stage(destination, database, objects || []) do
        {:ok,
         %{
           store_revision: revision,
           authority_epoch: epoch,
           dependencies: dependencies,
           quarantined: true,
           bytes: byte_size(database),
           portable_profile_objects: length(objects || [])
         }}
      else
        false -> {:error, :profile_bytes_missing}
        {:error, reason} when is_atom(reason) -> {:error, reason}
        _ -> {:error, :restore_unavailable}
      end
    end)
  end

  def stage_profile_restore(_, _, _), do: {:error, :invalid_restore_request}

  defp external_dependencies(db) do
    with {:ok, [[version]]} <- query(db, "PRAGMA user_version"),
         {:ok, refs} <- qualification_refs(db, version),
         {:ok, qualified_count} <- qualified_count(db, version, refs),
         {:ok, override_rows} <- override_rows(db, version),
         {:ok, override_operation_rows} <- override_operation_rows(db, version),
         {:ok, candidate_rows} <- candidate_rows(db, version),
         {:ok, invariant_rows} <- invariant_rows(db, version),
         {:ok, admissions, activations} <- rule_rows(db, version),
         {:ok, maintenance_rows, maintenance_active} <- maintenance_rows(db, version),
         {:ok, profiles} <- profile_dependencies(db, version) do
      {claim_refs, other_refs} = Enum.split_with(refs, &(&1 =~ @claim_ref))

      {:ok,
       Map.merge(
         %{
           qualified_profile_rows: qualified_count,
           retained_qualification_rows: length(refs),
           qualification_history_reactivates_on_restore: false,
           claim_package_refs: Enum.uniq(claim_refs),
           non_claim_qualification_rows: length(other_refs),
           reviewer_keys_required: claim_refs != [],
           raw_qualification_artifacts_included: false,
           operator_override_rows: override_rows,
           operator_override_operation_rows: override_operation_rows,
           operator_overrides_reactivate_on_restore: false,
           rule_candidate_review_rows: candidate_rows,
           candidate_history_reactivates_rules: false,
           invariant_policy_operation_rows: invariant_rows,
           invariant_reports_reactivate_on_restore: false,
           rule_admission_rows: admissions,
           rule_activation_rows: activations,
           rule_history_reactivates_on_restore: false,
           host_maintenance_operation_rows: maintenance_rows,
           host_maintenance_active: maintenance_active,
           device_credentials_and_counters: "external"
         },
         profiles
       )}
    else
      _ -> {:error, :invalid_backup}
    end
  end

  defp qualified_count(db, version, _refs) when version in 20..21 do
    case query(db, "SELECT COUNT(*) FROM profile_qualifications WHERE status='qualified'") do
      {:ok, [[count]]} when count in 0..4096 -> {:ok, count}
      _ -> {:error, :invalid_backup}
    end
  end

  defp qualified_count(_db, _version, refs), do: {:ok, length(refs)}

  defp profile_dependencies(_db, version) when version in 4..18,
    do:
      {:ok,
       %{
         profile_artifacts: [],
         profile_operation_rows: 0,
         profile_selection_rows: 0,
         portable_profile_bytes_included: false,
         profile_history_reactivates_on_restore: false
       }}

  defp profile_dependencies(db, version) when version in 19..21,
    do: ProfileWriter.dependencies(db)

  defp qualification_refs(_db, version) when version in 4..7, do: {:ok, []}

  defp qualification_refs(db, version) when version in 8..19 do
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

  defp qualification_refs(db, version) when version in 20..21 do
    with {:ok, rows} <-
           query(
             db,
             "SELECT evidence_ref FROM profile_qualification_history ORDER BY revision LIMIT 4097"
           ),
         true <- length(rows) <= @max_claim_refs,
         true <- Enum.all?(rows, &match?([ref] when is_binary(ref), &1)) do
      {:ok, Enum.map(rows, &hd/1)}
    else
      _ -> {:error, :invalid_backup}
    end
  end

  defp qualification_refs(_, _), do: {:error, :invalid_backup}

  defp override_rows(_db, version) when version in 4..9, do: {:ok, 0}

  defp override_rows(db, version) when version in 10..21 do
    case query(db, "SELECT COUNT(*) FROM operator_override_leases") do
      {:ok, [[count]]} when is_integer(count) and count in 0..4_096 -> {:ok, count}
      _ -> {:error, :invalid_backup}
    end
  end

  defp override_rows(_, _), do: {:error, :invalid_backup}

  defp override_operation_rows(_db, version) when version in 4..10, do: {:ok, 0}

  defp override_operation_rows(db, version) when version in 11..21 do
    case query(db, "SELECT COUNT(*) FROM operator_override_operations") do
      {:ok, [[count]]} when is_integer(count) and count in 0..65_536 -> {:ok, count}
      _ -> {:error, :invalid_backup}
    end
  end

  defp override_operation_rows(_, _), do: {:error, :invalid_backup}

  defp candidate_rows(_db, version) when version in 4..11, do: {:ok, 0}

  defp candidate_rows(db, version) when version in 12..21 do
    case query(db, "SELECT COUNT(*) FROM rule_candidate_reviews") do
      {:ok, [[count]]} when is_integer(count) and count in 0..1_024 -> {:ok, count}
      _ -> {:error, :invalid_backup}
    end
  end

  defp candidate_rows(_, _), do: {:error, :invalid_backup}

  defp invariant_rows(_db, version) when version in 4..15, do: {:ok, 0}

  defp invariant_rows(db, version) when version in 16..21 do
    case query(db, "SELECT COUNT(*) FROM invariant_policy_operations") do
      {:ok, [[count]]} when is_integer(count) and count in 0..1_024 -> {:ok, count}
      _ -> {:error, :invalid_backup}
    end
  end

  defp invariant_rows(_, _), do: {:error, :invalid_backup}

  defp rule_rows(_db, version) when version in 4..16, do: {:ok, 0, 0}

  defp rule_rows(db, version) when version in 17..21 do
    with {:ok, [[admissions]]} <- query(db, "SELECT COUNT(*) FROM rule_admissions"),
         {:ok, [[activations]]} <- query(db, "SELECT COUNT(*) FROM rule_activations"),
         true <- admissions in 0..1024 and activations in 0..1024 do
      {:ok, admissions, activations}
    else
      _ -> {:error, :invalid_backup}
    end
  end

  defp maintenance_rows(_db, version) when version in 4..17, do: {:ok, 0, false}

  defp maintenance_rows(db, version) when version in 18..21 do
    with {:ok, [[count]]} <- query(db, "SELECT COUNT(*) FROM host_maintenance_operations"),
         {:ok, [[active]]} <- query(db, "SELECT value FROM meta WHERE key='maintenance_revision'"),
         true <- count in 0..1024 and is_integer(active) and active >= 0 do
      {:ok, count, active > 0}
    else
      _ -> {:error, :invalid_backup}
    end
  end

  defp with_verified_db(path, key, fun) do
    with {:ok, bytes} <- read_archive(path),
         {:ok, revision, epoch, plain, objects} <- decrypt(bytes, key),
         {:ok, db} <- Sqlite3.open(":memory:") do
      try do
        with :ok <- Sqlite3.deserialize(db, "main", plain),
             {:ok, [[schema_version]]} <- query(db, "PRAGMA user_version"),
             {:ok, table_rows} <-
               query(
                 db,
                 "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT GLOB 'sqlite_*'"
               ),
             true <-
               schema_version in 4..@schema_version and
                 required_tables?(table_rows, schema_version),
             {:ok, [["ok"]]} <- query(db, "PRAGMA integrity_check(1)"),
             {:ok, []} <- query(db, "SELECT 1 FROM pragma_foreign_key_check LIMIT 1"),
             :ok <- Store.validate_snapshot(db),
             {:ok, [[^revision, ^epoch]]} <-
               query(
                 db,
                 "SELECT (SELECT value FROM meta WHERE key = 'revision'), (SELECT value FROM meta WHERE key = 'authority_epoch')"
               ),
             {:ok, dependencies} <- external_dependencies(db),
             :ok <- validate_objects(dependencies.profile_artifacts, objects) do
          dependencies =
            if is_nil(objects),
              do: dependencies,
              else:
                Map.merge(dependencies, %{
                  portable_profile_bytes_included: true,
                  portable_profile_object_count: length(objects)
                })

          dependencies =
            Map.merge(dependencies, %{
              archive_digest: WotexHome.Profiles.Artifact.digest(bytes),
              snapshot_digest: WotexHome.Profiles.Artifact.digest(plain),
              archive_bytes: byte_size(bytes)
            })

          fun.(db, revision, epoch, dependencies, objects)
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

  defp validate_objects(_, nil), do: :ok
  defp validate_objects(expected, objects), do: Archive.validate(expected, objects)

  defp read_archive(path) do
    with {:ok, before} <- File.lstat(path),
         true <- before.type == :regular and before.size in 1..(Archive.max_bytes() + 60),
         {:ok, file} <- File.open(path, [:read, :binary, :raw]) do
      try do
        with {:ok, info} <- :file.read_file_info(file, time: :universal),
             true <- file_identity(before) == file_identity(File.Stat.from_record(info)),
             bytes when is_binary(bytes) and byte_size(bytes) == before.size <-
               IO.binread(file, Archive.max_bytes() + 61),
             {:ok, after_info} <- :file.read_file_info(file, time: :universal),
             {:ok, named} <- File.lstat(path),
             true <- file_identity(before) == file_identity(File.Stat.from_record(after_info)),
             true <- file_identity(before) == file_identity(named) do
          {:ok, bytes}
        else
          _ -> {:error, :invalid_backup}
        end
      after
        File.close(file)
      end
    else
      _ -> {:error, :invalid_backup}
    end
  end

  defp file_identity(stat),
    do:
      {stat.type, stat.inode, stat.major_device, stat.minor_device, stat.uid, stat.mode,
       stat.size, stat.mtime, stat.ctime}

  defp export_from_snapshot(db, directory, destination, key, revision, epoch) do
    snapshot_path = Path.join(directory, "snapshot.sqlite")

    with {:ok, []} <- query(db, "VACUUM INTO ?", [snapshot_path]),
         {:ok, stat} <- File.stat(snapshot_path),
         true <- stat.type == :regular and stat.size <= @max_plain_bytes,
         {:ok, plain} <- File.read(snapshot_path) do
      payload = encrypt(@magic, revision, epoch, plain, key)

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

  defp encrypt(magic, revision, epoch, plain, key) do
    nonce = :crypto.strong_rand_bytes(12)

    header =
      <<magic::binary, revision::unsigned-big-64, epoch::unsigned-big-64, nonce::binary-size(12),
        byte_size(plain)::unsigned-big-32>>

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, plain, header, true)

    <<header::binary, ciphertext::binary, tag::binary-size(16)>>
  end

  defp decrypt(
         <<@profile_magic::binary, revision::unsigned-big-64, epoch::unsigned-big-64,
           nonce::binary-size(12), size::unsigned-big-32, rest::binary>> = bytes,
         key
       )
       when size <= 35_664_134 and byte_size(rest) == size + 16 do
    <<ciphertext::binary-size(^size), tag::binary-size(16)>> = rest
    header = binary_part(bytes, 0, byte_size(bytes) - byte_size(rest))

    with plain when is_binary(plain) <-
           :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, ciphertext, header, tag, false),
         {:ok, database, objects} <- Archive.decode(plain) do
      {:ok, revision, epoch, database, objects}
    else
      _ -> {:error, :invalid_backup}
    end
  end

  defp decrypt(
         <<@magic::binary, revision::unsigned-big-64, epoch::unsigned-big-64,
           nonce::binary-size(12), size::unsigned-big-32, rest::binary>> = bytes,
         key
       )
       when size <= @max_plain_bytes and byte_size(rest) == size + 16 do
    <<ciphertext::binary-size(^size), tag::binary-size(16)>> = rest
    header_size = byte_size(bytes) - byte_size(rest)
    header = binary_part(bytes, 0, header_size)

    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, ciphertext, header, tag, false) do
      plain when is_binary(plain) -> {:ok, revision, epoch, plain, nil}
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
        version when version in [8, 9] -> @v9_tables
        10 -> @v10_tables
        11 -> @v11_tables
        version when version in [12, 13] -> @v13_tables
        version when version in [14, 15] -> @v15_tables
        16 -> @v16_tables
        17 -> @v17_tables
        18 -> @v18_tables
        19 -> @v19_tables
        20 -> @v20_tables
        21 -> @v21_tables
      end

    names == MapSet.new(required)
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
