defmodule Woh.Tool.LifxRegistry do
  @moduledoc false
  require Bitwise

  alias Woh.Tool.Command

  @source_revision "8adbe485db11621639f693f3a1510603f029c902"
  @expected_sha256 "09f6b87367ea3a974cd4be9e7a562db73e1776d012854fb487b00ac9be520360"
  @max_bytes 1_048_576
  @url "https://raw.githubusercontent.com/LIFX/products/#{@source_revision}/products.json"

  # The local download remains private. Only its independently copied public
  # metadata in fresh release staging becomes readable by the service user.
  # Never widen an issued payload, a linked file, or unrelated release inputs.
  def prepare_release(release) do
    root = Path.expand(release)

    with {:ok, %File.Stat{type: :directory, uid: owner}} <- File.lstat(root),
         true <- unissued?(root),
         [home] <- Path.wildcard(Path.join(root, "lib/wotex_home-*")),
         true <-
           Enum.all?(
             [root, Path.join(root, "lib"), home, Path.join(home, "priv")],
             &owned_directory?(&1, owner)
           ) do
      directory = Path.join(home, "priv/lifx")

      case File.lstat(directory) do
        {:error, :enoent} ->
          {:ok, :absent}

        {:ok, _} ->
          if owned_directory?(directory, owner),
            do: prepare_packaged_registry(Path.join(directory, "products.json"), owner),
            else: {:error, "release LIFX directory is unsafe"}

        _ ->
          {:error, "cannot inspect release LIFX directory"}
      end
    else
      _ -> {:error, "expected fresh owned Home release staging"}
    end
  rescue
    _ in File.Error -> {:error, "cannot prepare packaged LIFX registry"}
  end

  defp unissued?(root) do
    Enum.all?(~w(release-inventory.json release-components.json release.spdx.json), fn name ->
      File.lstat(Path.join(root, name)) == {:error, :enoent}
    end)
  end

  defp owned_directory?(path, owner) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory, uid: ^owner, mode: mode}} ->
        Bitwise.band(mode, 0o7022) == 0

      _ ->
        false
    end
  end

  defp prepare_packaged_registry(path, owner) do
    case File.lstat(path) do
      {:error, :enoent} ->
        {:ok, :absent}

      {:ok, %File.Stat{type: :regular, uid: ^owner, links: 1, mode: mode}}
      when Bitwise.band(mode, 0o7000) == 0 ->
        with {:ok, _} <- WotexHome.Lifx.ProductRegistry.load_pinned(path),
             :ok <- File.chmod(path, 0o644),
             {:ok, _} <- WotexHome.Lifx.ProductRegistry.load_pinned(path) do
          {:ok, :prepared}
        else
          _ -> {:error, "packaged LIFX registry differs from the pinned artifact"}
        end

      _ ->
        {:error, "packaged LIFX registry is unavailable or linked"}
    end
  end

  def provision(destination, fetcher \\ &download/0, expected_sha256 \\ @expected_sha256) do
    case File.lstat(destination) do
      {:ok, %File.Stat{type: :regular, size: size}} when size > 0 and size <= @max_bytes ->
        case File.read(destination) do
          {:ok, bytes} ->
            if valid?(bytes, expected_sha256),
              do: {:ok, :verified},
              else: {:error, "existing local registry does not match the pinned artifact"}

          {:error, reason} ->
            {:error, "cannot read local registry: #{inspect(reason)}"}
        end

      {:ok, _} ->
        {:error, "existing local registry does not match the pinned artifact"}

      {:error, :enoent} ->
        fetch_and_install(destination, fetcher, expected_sha256)

      {:error, reason} ->
        {:error, "cannot inspect local registry: #{inspect(reason)}"}
    end
  end

  defp fetch_and_install(destination, fetcher, expected_sha256) do
    with {:ok, bytes} <- fetcher.(),
         true <- valid?(bytes, expected_sha256),
         :ok <- File.mkdir_p(Path.dirname(destination)),
         :ok <- install(destination, bytes) do
      {:ok, :provisioned}
    else
      false -> {:error, "downloaded LIFX registry exceeds the limit or has the wrong SHA-256"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp valid?(bytes, expected_sha256) when is_binary(bytes) do
    byte_size(bytes) > 0 and byte_size(bytes) <= @max_bytes and
      Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == expected_sha256
  end

  defp valid?(_, _), do: false

  defp download do
    case Command.run(
           "curl",
           [
             "--disable",
             "--fail",
             "--silent",
             "--show-error",
             "--location",
             "--max-redirs",
             "3",
             "--max-time",
             "20",
             "--max-filesize",
             Integer.to_string(@max_bytes),
             "--user-agent",
             "wotex-home-artifact/1",
             "--",
             @url
           ],
           @max_bytes + 1,
           25_000
         ) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, "cannot download pinned LIFX registry: #{reason}"}
    end
  end

  defp install(destination, bytes) do
    temporary =
      Path.join(
        Path.dirname(destination),
        ".products-#{Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)}"
      )

    try do
      with {:ok, :ok} <-
             File.open(temporary, [:write, :exclusive, :binary], fn io ->
               File.chmod!(temporary, 0o600)
               IO.binwrite(io, bytes)
               :file.sync(io)
             end),
           :ok <- File.ln(temporary, destination) do
        :ok
      else
        {:error, :eexist} -> {:error, "registry destination appeared during provisioning"}
        {:error, reason} -> {:error, "cannot install local registry: #{inspect(reason)}"}
      end
    after
      File.rm(temporary)
    end
  end
end

defmodule Mix.Tasks.Woh.Lifx.Registry.Fetch do
  @moduledoc """
  Stages the pinned LIFX product metadata for local development.

  Run `mix woh.lifx.registry.fetch` before building a development release that
  needs product names and feature metadata. The task checks an existing local
  file or fetches LIFX's pinned `products.json` revision over HTTPS, bounds its
  size, verifies its SHA-256 and installs it without replacing another file.
  The artifact stays ignored by Git. A clean checkout has no product registry.
  """

  @shortdoc "Fetch the pinned LIFX product registry"
  @requirements ["loadpaths"]
  use Mix.Task

  @impl Mix.Task
  def run([]) do
    destination = Path.expand("priv/lifx/products.json")

    case Woh.Tool.LifxRegistry.provision(destination) do
      {:ok, :verified} -> Mix.shell().info("verified local LIFX registry: #{destination}")
      {:ok, :provisioned} -> Mix.shell().info("provisioned pinned LIFX registry: #{destination}")
      {:error, reason} -> Mix.raise("LIFX registry provisioning failed: #{reason}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.lifx.registry.fetch")
end
