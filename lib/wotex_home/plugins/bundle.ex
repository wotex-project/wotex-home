defmodule WotexHome.Plugins.Bundle do
  @moduledoc """
  Trusted local staging of immutable, unqualified component bytes.

  This is development custody, not profile admission or an active registry.
  Published digest directories are never overwritten. The worker receives the
  bounded bytes returned by `read/2`, never a path. Host-account compromise and
  production publisher/recovery policy are separate boundaries.
  """

  import Bitwise

  @max_component 524_288
  @world "wotex:home-profile/profile@0.1.0"
  @wit_path Path.expand("../../../native/components/wit/profile.wit", __DIR__)
  @external_resource @wit_path
  @wit_digest :crypto.hash(:sha256, File.read!(@wit_path)) |> Base.encode16(case: :lower)
  @keys ~w(component_sha256 format wit_sha256 world)

  def wit_digest, do: @wit_digest
  def world, do: @world
  def max_component, do: @max_component

  @doc "Stages a local portable binary without qualifying or activating it."
  def install(root, source) when is_binary(root) and is_binary(source) do
    with :ok <- private_root(root),
         {:ok, bytes} <- bounded_file(source, @max_component),
         true <- component_binary?(bytes) do
      publish(root, bytes)
    else
      _ -> {:error, :invalid_bundle}
    end
  end

  def install(_, _), do: {:error, :invalid_bundle}

  @doc "Revalidates the installed manifest and the exact bounded component bytes."
  def read(root, digest) do
    with true <-
           is_binary(digest) and byte_size(digest) == 64 and
             Regex.match?(~r/\A[0-9a-f]{64}\z/, digest),
         :ok <- private_root(root),
         directory = Path.join(root, digest),
         :ok <- private_directory(directory),
         {:ok, manifest_bytes} <- bounded_file(Path.join(directory, "manifest.json"), 1024),
         {:ok, manifest} <- manifest(manifest_bytes),
         true <- manifest == metadata(digest),
         {:ok, bytes} <- bounded_file(Path.join(directory, "component.wasm"), @max_component),
         true <- component_binary?(bytes) and hash(bytes) == digest do
      {:ok, %{digest: digest, wit_digest: @wit_digest, bytes: bytes}}
    else
      _ -> {:error, :invalid_bundle}
    end
  end

  defp publish(root, bytes) do
    digest = hash(bytes)
    destination = Path.join(root, digest)

    case File.lstat(destination) do
      {:error, :enoent} ->
        stage = Path.join(root, ".stage-" <> Base.url_encode64(:crypto.strong_rand_bytes(16)))

        result =
          with :ok <- File.mkdir(stage),
               :ok <- File.chmod(stage, 0o700),
               :ok <- write_private(Path.join(stage, "component.wasm"), bytes),
               :ok <-
                 write_private(Path.join(stage, "manifest.json"), JSON.encode!(metadata(digest))),
               :ok <- File.rename(stage, destination),
               {:ok, _} <- read(root, digest) do
            {:ok, digest}
          else
            _ -> existing(root, digest)
          end

        File.rm_rf(stage)
        result

      _ ->
        existing(root, digest)
    end
  end

  defp existing(root, digest) do
    case read(root, digest) do
      {:ok, _} -> {:ok, digest}
      _ -> {:error, :invalid_bundle}
    end
  end

  defp write_private(path, bytes) do
    with :ok <- File.write(path, bytes, [:exclusive]), do: File.chmod(path, 0o600)
  end

  defp metadata(digest),
    do: %{
      "format" => 1,
      "world" => @world,
      "wit_sha256" => @wit_digest,
      "component_sha256" => digest
    }

  defp manifest(bytes) do
    case JSON.decode(bytes, nil,
           object_push: fn key, value, pairs ->
             if Enum.any?(pairs, fn {existing, _} -> existing == key end),
               do: raise(ArgumentError, "duplicate member")

             [{key, value} | pairs]
           end
         ) do
      {value, nil, ""} when is_map(value) ->
        if Enum.sort(Map.keys(value)) == @keys,
          do: {:ok, value},
          else: {:error, :invalid_bundle}

      _ ->
        {:error, :invalid_bundle}
    end
  rescue
    ArgumentError -> {:error, :invalid_bundle}
  end

  defp private_root(root) when is_binary(root) do
    if Path.type(root) == :absolute,
      do: private_directory(root),
      else: {:error, :invalid_bundle}
  end

  defp private_root(_), do: {:error, :invalid_bundle}

  defp private_directory(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory, mode: mode}} when band(mode, 0o777) == 0o700 -> :ok
      _ -> {:error, :invalid_bundle}
    end
  end

  defp bounded_file(path, maximum) do
    with {:ok, %{type: :regular, size: size}} <- File.lstat(path),
         true <- size in 1..maximum,
         {:ok, file} <- File.open(path, [:read, :binary, :raw]) do
      try do
        case IO.binread(file, maximum + 1) do
          bytes when is_binary(bytes) and byte_size(bytes) > 0 and byte_size(bytes) <= maximum ->
            {:ok, bytes}

          _ ->
            {:error, :invalid_bundle}
        end
      after
        File.close(file)
      end
    else
      _ -> {:error, :invalid_bundle}
    end
  end

  defp component_binary?(<<0, 97, 115, 109, 13, 0, 1, 0, _::binary>>), do: true
  defp component_binary?(_), do: false
  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
