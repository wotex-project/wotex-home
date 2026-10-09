defmodule Woh.Tool.LinuxInstallStage do
  @moduledoc false
  import Bitwise
  alias Woh.Tool.LinuxInstallFiles

  @max_manifest 2_097_152
  @max_payload 1_073_741_824
  @max_tree 4_194_304
  @stat_keys ~w(type inode major_device minor_device uid gid links mode size mtime ctime)a

  # Read-only observation is portable. Native mutation separately requires
  # root, the retained lock and the exact installation/stage namespace. A
  # snapshot grants no ownership, Store permission or release-switch authority.
  # The independently verified source permits only byte-for-byte prefixes left
  # by an interrupted exclusive bootstrap copy, not arbitrary changed bytes.
  def snapshot(stage, marker, manifest, pin, source \\ nil) do
    with true <- is_binary(marker) and byte_size(marker) in 1..65_536,
         {:ok, declared} <- decode_manifest(manifest, pin),
         {:ok, info} <- File.lstat(stage),
         true <- info.type == :directory and (info.mode &&& 0o7777) == 0o700,
         names <- File.ls!(stage) |> Enum.sort(),
         true <- names in [["stage.json"], ["release", "stage.json"]] do
      context = %{
        declared: declared,
        marker: marker,
        source: source,
        uid: info.uid,
        gid: info.gid,
        device: {info.major_device, info.minor_device}
      }

      state = %{rows: [], bytes: 0, files: 0, directories: 0, complete: MapSet.new()}
      result = inspect_node(stage, ".", context, state)
      frame = IO.iodata_to_binary(["WOTEX_HOME_INSTALL_STAGE\t1\n", Enum.reverse(result.rows)])
      ensure!(byte_size(frame) <= @max_tree)
      ensure!(same?(info, File.lstat!(stage)))

      {:ok,
       %{
         sha256: LinuxInstallFiles.digest(frame),
         files: result.files,
         directories: result.directories,
         bytes: result.bytes,
         complete: MapSet.size(result.complete) == map_size(declared.files)
       }}
    else
      _ -> {:error, :invalid_update_stage}
    end
  rescue
    _ -> {:error, :invalid_update_stage}
  catch
    :invalid_update_stage -> {:error, :invalid_update_stage}
  end

  def decode_manifest(bytes, pin) when is_binary(bytes) and byte_size(bytes) <= @max_manifest do
    with true <- hex?(pin, 64) and LinuxInstallFiles.digest(bytes) == pin,
         [header | lines] <- String.split(bytes, "\n"),
         ["WOTEX_HOME_BOOTSTRAP", "1", revision] <- String.split(header, "\t"),
         true <- hex?(revision, 40),
         ["" | reversed] <- Enum.reverse(lines),
         rows <- Enum.reverse(reversed),
         true <- length(rows) in 1..10_000 do
      {files, total, paths} =
        Enum.reduce(rows, {%{}, 0, []}, fn row, {files, total, paths} ->
          [sha, mode_text, size_text, path] = String.split(row, "\t")
          ensure!(hex?(sha, 64) and path?(path))
          ensure!(Regex.match?(~r/\A[0-7]{1,4}\z/, mode_text))
          {mode, ""} = Integer.parse(mode_text, 8)
          ensure!(Integer.to_string(mode, 8) == mode_text and (mode &&& 0o7022) == 0)
          ensure!(Regex.match?(~r/\A(?:0|[1-9][0-9]{0,9})\z/, size_text))
          size = String.to_integer(size_text)
          ensure!(total + size <= @max_payload and not Map.has_key?(files, path))

          {Map.put(files, path, %{sha256: sha, mode: mode, size: size}), total + size,
           [path | paths]}
        end)

      ensure!(Enum.reverse(paths) == Enum.sort(paths))
      ensure!(Map.has_key?(files, "release-inventory.json"))

      directories =
        for path <- Map.keys(files),
            directory <- parent_paths(path),
            into: MapSet.new(["."]),
            do: directory

      # File/directory prefix conflicts cannot describe a payload tree.
      ensure!(Enum.all?(Map.keys(files), &(not MapSet.member?(directories, &1))))
      {:ok, %{files: files, directories: directories, bytes: total, source_revision: revision}}
    else
      _ -> {:error, :invalid_update_stage}
    end
  rescue
    _ -> {:error, :invalid_update_stage}
  catch
    :invalid_update_stage -> {:error, :invalid_update_stage}
  end

  def decode_manifest(_, _), do: {:error, :invalid_update_stage}

  defp inspect_node(path, relative, context, state) do
    ensure!(byte_size(relative) <= 1024 and length(Path.split(relative)) <= 65)
    info = File.lstat!(path)

    ensure!(
      info.uid == context.uid and info.gid == context.gid and
        {info.major_device, info.minor_device} == context.device and (info.mode &&& 0o7022) == 0
    )

    case info.type do
      :directory ->
        ensure!((info.mode &&& 0o7777) in [0o700, 0o755])
        ensure!(directory?(relative, context.declared.directories))
        ensure!(state.directories < 20_000)
        row = ["D\t", Integer.to_string(info.mode &&& 0o7777, 8), "\t", relative, "\n"]
        next = %{state | directories: state.directories + 1, rows: [row | state.rows]}
        names = File.ls!(path) |> Enum.sort()

        result =
          Enum.reduce(names, next, fn name, accumulated ->
            ensure!(Regex.match?(~r/\A[A-Za-z0-9_+@.-]+\z/, name) and name not in [".", ".."])
            child = if relative == ".", do: name, else: relative <> "/" <> name
            inspect_node(Path.join(path, name), child, context, accumulated)
          end)

        ensure!(same?(info, File.lstat!(path)))
        result

      :regular ->
        ensure!(
          info.links == 1 and state.files < 20_000 and
            state.bytes + info.size <= 2_147_483_648
        )

        sha = file_digest(path)
        ensure!(same?(info, File.lstat!(path)))
        complete = validate_file(path, relative, info, sha, context, state.complete)

        row = [
          "F\t",
          Integer.to_string(info.mode &&& 0o7777, 8),
          "\t",
          Integer.to_string(info.size),
          "\t",
          sha,
          "\t",
          relative,
          "\n"
        ]

        %{
          state
          | files: state.files + 1,
            bytes: state.bytes + info.size,
            rows: [row | state.rows],
            complete: complete
        }

      _ ->
        throw(:invalid_update_stage)
    end
  end

  defp validate_file(path, "stage.json", info, sha, context, complete) do
    ensure!(
      (info.mode &&& 0o7777) == 0o600 and info.size == byte_size(context.marker) and
        sha == LinuxInstallFiles.digest(context.marker) and File.read!(path) == context.marker
    )

    complete
  end

  defp validate_file(_path, "release/" <> relative, info, sha, context, complete) do
    declared = Map.fetch!(context.declared.files, relative)

    if info.size == declared.size and (info.mode &&& 0o7777) == declared.mode and
         sha == declared.sha256 do
      MapSet.put(complete, relative)
    else
      ensure!(
        is_binary(context.source) and (info.mode &&& 0o7777) == 0o600 and
          info.size <= declared.size
      )

      source = Path.join(context.source, relative)
      before = File.lstat!(source)

      ensure!(
        before.type == :regular and before.links == 1 and before.uid == context.uid and
          before.gid == context.gid and before.size == declared.size and
          (before.mode &&& 0o7777) == declared.mode
      )

      {whole, prefix} = prefix_digests(source, info.size)
      ensure!(whole == declared.sha256 and prefix == sha and same?(before, File.lstat!(source)))
      complete
    end
  end

  defp validate_file(_, _, _, _, _, _), do: throw(:invalid_update_stage)

  defp directory?(".", _), do: true
  defp directory?("release", _), do: true
  defp directory?("release/" <> path, declared), do: MapSet.member?(declared, path)
  defp directory?(_, _), do: false

  defp prefix_digests(path, size) do
    {whole, prefix, _} =
      File.stream!(path, 65_536)
      |> Enum.reduce(
        {:crypto.hash_init(:sha256), :crypto.hash_init(:sha256), size},
        fn chunk, {whole, prefix, left} ->
          take = min(left, byte_size(chunk))

          {:crypto.hash_update(whole, chunk),
           :crypto.hash_update(prefix, binary_part(chunk, 0, take)), left - take}
        end
      )

    {finish(whole), finish(prefix)}
  end

  defp file_digest(path),
    do:
      File.stream!(path, 65_536)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> finish()

  defp finish(hash), do: hash |> :crypto.hash_final() |> Base.encode16(case: :lower)
  defp same?(a, b), do: Map.take(a, @stat_keys) == Map.take(b, @stat_keys)

  defp path?(path),
    do:
      byte_size(path) in 1..512 and
        Regex.match?(~r/\A[A-Za-z0-9_+@.\/-]+\z/, path) and Path.type(path) == :relative and
        not String.starts_with?(path, "-") and
        not Enum.any?(String.split(path, "/"), &(&1 in ["", ".", ".."]))

  defp parent_paths(path),
    do:
      path
      |> Path.split()
      |> Enum.drop(-1)
      |> Enum.scan(fn part, parent -> parent <> "/" <> part end)

  defp hex?(value, size),
    do:
      is_binary(value) and byte_size(value) == size and
        Regex.match?(~r/\A[0-9a-f]+\z/, value)

  defp ensure!(true), do: :ok
  defp ensure!(_), do: throw(:invalid_update_stage)
end
