defmodule Woh.Tool.ReleaseBootstrap do
  @moduledoc false
  import Bitwise

  alias Woh.Tool.{Hash, Json, ReleaseInventory}

  defmodule Error do
    @moduledoc false
    defexception [:message]
  end

  @max_manifest 2_097_152
  @max_files 10_000
  @max_bytes 1_073_741_824

  def render(release) do
    with {:ok, _} <- ReleaseInventory.verify(release),
         {:ok, saved} <- Json.read(Path.join(release, ReleaseInventory.manifest()), 2_000_000),
         {:ok, entries} <- ReleaseInventory.entries(release, []),
         {:ok, _} <- ReleaseInventory.verify(release) do
      ensure!(valid_revision?(saved["source_revision"]), "invalid bootstrap source revision")
      ensure!(length(entries) <= @max_files, "bootstrap file limit exceeded")

      ensure!(
        Enum.reduce(entries, 0, &(&1["size"] + &2)) <= @max_bytes,
        "bootstrap byte limit exceeded"
      )

      rows =
        Enum.map(entries, fn entry ->
          require_path!(entry["path"])
          mode = entry["mode"]
          ensure!((mode &&& 0o022) == 0, "bootstrap refuses writable-group/other payload")
          info = File.lstat!(Path.join(release, entry["path"]))
          ensure!((info.mode &&& 0o7000) == 0, "bootstrap refuses special file mode bits")

          [
            entry["sha256"],
            "\t",
            Integer.to_string(mode, 8),
            "\t",
            Integer.to_string(entry["size"]),
            "\t",
            entry["path"],
            "\n"
          ]
        end)

      bytes =
        IO.iodata_to_binary(["WOTEX_HOME_BOOTSTRAP\t1\t", saved["source_revision"], "\n", rows])

      ensure!(byte_size(bytes) <= @max_manifest, "bootstrap manifest limit exceeded")
      {:ok, bytes}
    end
  rescue
    error in Error ->
      {:error, error.message}

    error in File.Error ->
      {:error, "cannot inspect bootstrap payload: #{Exception.message(error)}"}
  end

  def create(release, destination) do
    root = Path.expand(release)
    destination = Path.expand(destination)

    ensure!(
      destination != root and not String.starts_with?(destination, root <> "/"),
      "bootstrap manifest must be outside the inventoried payload"
    )

    with {:ok, bytes} <- render(root) do
      File.write!(destination, bytes, [:exclusive])
      File.chmod!(destination, 0o644)
      {:ok, Hash.sha256(destination)}
    end
  rescue
    error in Error ->
      {:error, error.message}

    error in File.Error ->
      {:error, "cannot create bootstrap manifest: #{Exception.message(error)}"}
  end

  def verify(release, manifest, expected_sha256) do
    with true <-
           is_binary(expected_sha256) and Regex.match?(~r/\A[0-9a-f]{64}\z/, expected_sha256),
         {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_manifest <-
           File.lstat(manifest),
         {:ok, bytes} <- render(release),
         true <- File.read!(manifest) == bytes and Hash.sha256(manifest) == expected_sha256 do
      {:ok, expected_sha256}
    else
      _ -> {:error, "bootstrap manifest, pin or payload differs"}
    end
  rescue
    error in File.Error ->
      {:error, "cannot verify bootstrap manifest: #{Exception.message(error)}"}
  end

  defp require_path!(path) do
    ensure!(
      is_binary(path) and byte_size(path) <= 512 and
        Regex.match?(~r/\A[A-Za-z0-9_+@.\/-]+\z/, path) and
        Path.type(path) == :relative and
        not Enum.any?(String.split(path, "/"), &(&1 in ["", ".", ".."])) and
        not String.starts_with?(path, "-"),
      "unsafe bootstrap payload path"
    )
  end

  defp valid_revision?(revision),
    do: is_binary(revision) and Regex.match?(~r/\A[0-9a-f]{40}\z/, revision)

  defp ensure!(true, _reason), do: :ok
  defp ensure!(_, reason), do: raise(Error, message: reason)
end

defmodule Mix.Tasks.Woh.Release.Bootstrap do
  @moduledoc "Create or verify a pinned, external bootstrap manifest for an inventoried release."
  @shortdoc "Bind the release bootstrap inputs"
  @requirements ["loadpaths"]
  use Mix.Task

  @impl Mix.Task
  def run(["create", release, destination]) do
    case Woh.Tool.ReleaseBootstrap.create(release, destination) do
      {:ok, pin} -> Mix.shell().info("bootstrap manifest SHA-256: #{pin}")
      {:error, reason} -> Mix.raise(reason)
    end
  end

  def run(["verify", release, manifest, pin]) do
    case Woh.Tool.ReleaseBootstrap.verify(release, manifest, pin) do
      {:ok, _} -> Mix.shell().info("verified bootstrap manifest and complete release")
      {:error, reason} -> Mix.raise(reason)
    end
  end

  def run(_),
    do:
      Mix.raise(
        "usage: mix woh.release.bootstrap create RELEASE MANIFEST | verify RELEASE MANIFEST SHA256"
      )
end
