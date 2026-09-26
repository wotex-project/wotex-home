defmodule WotexHome.Durable.Backup do
  @moduledoc """
  Bounded, encrypted, consistent SQLite export and read-only verification.

  The caller supplies a fresh 32-byte key through a trusted local boundary.
  This module never persists or returns that key. It does not restore authority
  or radio credentials, so a verified archive is not a takeover permission.
  """

  alias Exqlite.Sqlite3

  @magic "WOHBK1\0"
  @max_plain_bytes 33_554_432

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
    with {:ok, stat} <- File.stat(path),
         true <- stat.type == :regular and stat.size <= @max_plain_bytes + 60,
         {:ok, bytes} <- File.read(path),
         {:ok, revision, epoch, plain} <- decrypt(bytes, key),
         {:ok, db} <- Sqlite3.open(":memory:") do
      try do
        with :ok <- Sqlite3.deserialize(db, "main", plain),
             {:ok, [["ok"]]} <- query(db, "PRAGMA quick_check"),
             {:ok, [[^revision, ^epoch]]} <-
               query(
                 db,
                 "SELECT (SELECT value FROM meta WHERE key = 'revision'), (SELECT value FROM meta WHERE key = 'authority_epoch')"
               ) do
          {:ok, %{store_revision: revision, authority_epoch: epoch}}
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

  def verify(_path, _key), do: {:error, :invalid_backup}

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
