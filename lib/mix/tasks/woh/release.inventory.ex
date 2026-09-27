defmodule Woh.Tool.ReleaseInventory do
  @moduledoc false

  import Bitwise

  alias Woh.Tool.{Hash, Json}

  defmodule Error do
    @moduledoc false
    defexception [:message]
  end

  @manifest "release-inventory.json"
  @max_files 10_000
  @max_bytes 1_073_741_824
  @max_manifest_bytes 2_000_000

  def manifest, do: @manifest

  def entries(root, excluded \\ [@manifest]) do
    root = Path.expand(root)
    require_directory!(root)
    {files, _bytes, entries} = scan!(root, root, MapSet.new(excluded), {0, 0, []})
    ensure!(files > 0, "empty release")
    {:ok, Enum.sort_by(entries, & &1["path"])}
  rescue
    error in Error -> {:error, error.message}
    error in File.Error -> {:error, "cannot inspect release: #{Exception.message(error)}"}
  end

  def create(root, revision) do
    with true <- valid_revision?(revision),
         {:ok, files} <- entries(root) do
      root = Path.expand(root)
      manifest = Path.join(root, @manifest)
      temporary = manifest <> ".tmp"

      try do
        File.write!(temporary, canonical_json(files, revision), [:exclusive])
        File.rename!(temporary, manifest)
        {:ok, length(files)}
      rescue
        error in File.Error ->
          {:error, "cannot write release inventory: #{Exception.message(error)}"}
      after
        File.rm(temporary)
      end
    else
      false -> {:error, "invalid source revision"}
      {:error, reason} -> {:error, reason}
    end
  end

  def verify(root) do
    root = Path.expand(root)

    with :ok <- directory_result(root),
         {:ok, data} <- Json.read(Path.join(root, @manifest), @max_manifest_bytes),
         true <- valid_manifest?(data),
         {:ok, files} <- entries(root),
         true <- data["files"] == files do
      {:ok, length(files)}
    else
      false -> {:error, "invalid release inventory or release differs from inventory"}
      {:error, reason} -> {:error, reason}
    end
  end

  def source_revision(project) do
    with {"", 0} <-
           System.cmd("git", ["status", "--porcelain", "--untracked-files=normal"],
             cd: project,
             stderr_to_stdout: true
           ),
         {revision, 0} <-
           System.cmd("git", ["rev-parse", "HEAD"],
             cd: project,
             stderr_to_stdout: true
           ),
         revision = String.trim(revision),
         true <- valid_revision?(revision) do
      {:ok, revision}
    else
      {_, 0} -> {:error, "source tree is dirty; commit before inventory creation"}
      {_, status} -> {:error, "git failed with status #{status}"}
      false -> {:error, "invalid source revision"}
    end
  end

  defp scan!(directory, root, excluded, state) do
    directory
    |> File.ls!()
    |> Enum.sort()
    |> Enum.reduce(state, fn name, {count, bytes, entries} = state ->
      path = Path.join(directory, name)
      relative = Path.relative_to(path, root)
      info = File.lstat!(path)

      case info.type do
        :directory ->
          scan!(path, root, excluded, state)

        :regular ->
          if MapSet.member?(excluded, relative) do
            state
          else
            count = count + 1
            bytes = bytes + info.size

            ensure!(
              count <= @max_files and bytes <= @max_bytes,
              "release inventory limit exceeded"
            )

            entry = %{
              "path" => relative,
              "size" => info.size,
              "mode" => info.mode &&& 0o777,
              "sha256" => Hash.sha256(path)
            }

            {count, bytes, [entry | entries]}
          end

        :symlink ->
          fail!("symlink in release: #{relative}")

        _ ->
          fail!("nonregular file in release: #{relative}")
      end
    end)
  end

  def canonical_json(files, revision) do
    encoded_files =
      Enum.map_join(files, ",", fn entry ->
        "{\"mode\":#{entry["mode"]},\"path\":#{JSON.encode!(entry["path"])}," <>
          "\"sha256\":#{JSON.encode!(entry["sha256"])},\"size\":#{entry["size"]}}"
      end)

    "{\"files\":[#{encoded_files}],\"schema_version\":1," <>
      "\"source_revision\":#{JSON.encode!(revision)}}\n"
  end

  defp valid_manifest?(data) do
    is_map(data) and
      MapSet.new(Map.keys(data)) == MapSet.new(~w(files schema_version source_revision)) and
      data["schema_version"] == 1 and valid_revision?(data["source_revision"]) and
      is_list(data["files"]) and data["files"] != []
  end

  defp valid_revision?(revision),
    do: is_binary(revision) and Regex.match?(~r/\A[0-9a-f]{40}\z/, revision)

  defp directory_result(root) do
    try do
      require_directory!(root)
      :ok
    rescue
      error in Error -> {:error, error.message}
    end
  end

  defp require_directory!(root) do
    ensure!(
      match?({:ok, %File.Stat{type: :directory}}, File.lstat(root)),
      "release root must be a real directory"
    )
  end

  defp ensure!(true, _message), do: :ok
  defp ensure!(false, message), do: fail!(message)
  defp fail!(message), do: raise(Error, message)
end

defmodule Mix.Tasks.Woh.Release.Inventory do
  @moduledoc """
  Creates or verifies a file inventory for an assembled OTP release.

  Run `mix woh.release.inventory create RELEASE_ROOT` from a clean committed
  tree after the component and SPDX reports are complete. The inventory binds
  every regular release file, including those reports, to the source revision
  with size, mode and SHA-256. Use `verify` with the same release root to check
  for added, removed or changed files. This unsigned report is an integrity
  input, not proof of artifact authenticity or license clearance.
  """

  @shortdoc "Create or verify a release file inventory"
  @requirements ["loadpaths"]
  use Mix.Task

  @impl Mix.Task
  def run(["create", root]) do
    with {:ok, revision} <- Woh.Tool.ReleaseInventory.source_revision(File.cwd!()),
         {:ok, count} <- Woh.Tool.ReleaseInventory.create(root, revision) do
      Mix.shell().info("inventoried #{count} release files at #{revision}")
    else
      {:error, reason} -> Mix.raise("release inventory error: #{reason}")
    end
  end

  def run(["verify", root]) do
    case Woh.Tool.ReleaseInventory.verify(root) do
      {:ok, count} -> Mix.shell().info("verified #{count} release files")
      {:error, reason} -> Mix.raise("release inventory error: #{reason}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.release.inventory create|verify RELEASE_ROOT")
end
