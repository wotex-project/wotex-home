defmodule WotexHome.Host.GenerationConfiguration do
  @moduledoc """
  Loads and publishes immutable private generator export-policy data.

  `load/1` selects generation-policies-v1.json beneath a canonical private
  data root, returning a sealed snapshot or explicit absence. `check/2` rechecks
  that exact selection before Host starts children. Documents contain at most
  32 actor-scoped policies within a one-MiB bounded closed JSON representation.

  `publish/3` validates a private source and publishes without replacement.
  An identical retry returns digest/count metadata; different existing bytes
  refuse. Publication starts no Home application, Store or provider and grants
  no current export permission. The file contains no credentials or adapter
  PIDs and remains outside database/profile recovery archives.
  """

  alias WotexHome.Profiles.{AuthoringProducer, EnvelopeCodec, GenerationPolicy}
  alias WotexHome.Recovery.PrivateFile
  import Bitwise

  @format "wotex-home.generation-policies@1"
  @filename "generation-policies-v1.json"
  @maximum 1_048_576

  defmodule Snapshot do
    @moduledoc false

    @enforce_keys [:path, :policies, :seal, :sha256]
    @derive {Inspect, only: [:sha256]}
    defstruct @enforce_keys
  end

  defmodule Absence do
    @moduledoc false

    @enforce_keys [:directory, :witnesses]
    @derive {Inspect, only: []}
    defstruct @enforce_keys
  end

  @doc "Returns the fixed private startup-policy filename."
  def filename, do: @filename

  @doc "Decodes the closed document into checked ordered policies without source reads."
  def decode(bytes) when is_binary(bytes) and byte_size(bytes) in 1..@maximum do
    options = [
      max_bytes: @maximum,
      max_depth: 8,
      max_nodes: 32768,
      max_collection_size: 256,
      max_string_bytes: 4096
    ]

    with {:ok, data} <-
           AuthoringProducer.call(
             Wotex.JSON,
             :decode,
             [bytes, options],
             :invalid_generation_configuration
           ),
         true <- EnvelopeCodec.keys?(data, ~w(format policies)) and data["format"] == @format,
         :ok <- bounded(data["policies"], 32),
         {:ok, policies} <- policies(data["policies"]),
         :ok <- GenerationPolicy.installation(policies),
         do: {:ok, policies},
         else: (
           {:error, :authoring_limit} = error -> error
           {:error, :profiles_producer_unavailable} = error -> error
           _ -> invalid()
         )
  end

  def decode(bytes) when is_binary(bytes) and byte_size(bytes) > @maximum,
    do: {:error, :authoring_limit}

  def decode(_), do: invalid()

  @doc "Reads one sealed startup selection, with missing policy explicitly absent."
  def load(directory) when is_binary(directory) do
    if directory?(directory) and private_root?(directory),
      do: load_private(directory),
      else: unavailable()
  end

  def load(_), do: unavailable()

  defp load_private(directory) do
    path = Path.join(directory, @filename)

    case File.lstat(path) do
      {:error, :enoent} ->
        with {:ok, witnesses} <- root_witnesses(directory),
             do: {:ok, %Absence{directory: directory, witnesses: witnesses}}

      {:ok, _} ->
        with {:ok, bytes, seal} <- PrivateFile.read_sealed(path, @maximum),
             {:ok, policies} <- decode(bytes) do
          {:ok,
           %Snapshot{
             path: path,
             policies: policies,
             seal: seal,
             sha256: AuthoringProducer.sha(bytes)
           }}
        else
          {:error, :private_custody_unavailable} -> unavailable()
          error -> error
        end

      _ ->
        unavailable()
    end
  end

  @doc "Requires the original sealed policy or continued absence before child startup."
  def check(:absent, directory) do
    if private_root?(directory) and
         match?({:error, :enoent}, File.lstat(Path.join(directory, @filename))),
       do: :ok,
       else: changed()
  end

  def check(%Absence{directory: directory, witnesses: original}, directory) do
    with {:ok, ^original} <- root_witnesses(directory),
         {:error, :enoent} <- File.lstat(Path.join(directory, @filename)) do
      :ok
    else
      _ -> changed()
    end
  end

  def check(%Snapshot{} = snapshot, directory) do
    with true <- snapshot.path == Path.join(directory, @filename),
         {:ok, bytes, seal} <- PrivateFile.read_sealed(snapshot.path, @maximum),
         true <- seal == snapshot.seal and AuthoringProducer.sha(bytes) == snapshot.sha256,
         {:ok, policies} <- decode(bytes),
         true <- policies == snapshot.policies do
      :ok
    else
      _ -> changed()
    end
  end

  def check(_, _), do: changed()

  @doc "Publishes exact private bytes for a later startup and returns only digest/count metadata."
  def publish(directory, source, sync \\ &:file.sync/1)

  def publish(directory, source, sync)
      when is_binary(directory) and is_binary(source) and is_function(sync, 1) do
    with true <- directory?(directory),
         {:ok, bytes, source_seal} <- PrivateFile.read_sealed(source, @maximum),
         {:ok, policies} <- decode(bytes),
         {:ok, ^bytes, ^source_seal} <- PrivateFile.read_sealed(source, @maximum),
         :ok <- publish_bytes(Path.join(directory, @filename), bytes, sync) do
      {:ok,
       %{
         sha256: AuthoringProducer.sha(bytes),
         policies: length(policies),
         principals: policies |> Enum.map(& &1.input["principal_id"]) |> Enum.uniq() |> length(),
         providers: policies |> Enum.map(& &1.provider_sha256) |> Enum.uniq() |> length()
       }}
    else
      {:error, :private_custody_unavailable} -> unavailable()
      {:error, _} = error -> error
      _ -> unavailable()
    end
  end

  def publish(_, _, _), do: unavailable()

  defp policies(input) do
    Enum.reduce_while(input, {:ok, []}, fn value, {:ok, acc} ->
      case GenerationPolicy.new(value) do
        {:ok, policy} -> {:cont, {:ok, [policy | acc]}}
        _ -> {:halt, invalid()}
      end
    end)
    |> case do
      {:ok, result} -> {:ok, Enum.reverse(result)}
      error -> error
    end
  end

  defp directory?(directory),
    do:
      byte_size(directory) in 1..1024 and Path.type(directory) == :absolute and
        Path.expand(directory) == directory and not String.contains?(directory, <<0>>)

  defp private_root?(directory) do
    match?({:ok, _}, root_witnesses(directory))
  end

  defp root_witnesses(directory) do
    with {:ok, %{type: :directory, mode: mode}} <- File.lstat(directory),
         true <- band(mode, 0o777) == 0o700 do
      directory
      |> Path.split()
      |> Enum.scan(&Path.join(&2, &1))
      |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
        case File.lstat(path) do
          {:ok, %{type: :directory} = stat} ->
            witness = {stat.inode, stat.major_device, stat.minor_device, stat.uid, stat.mode}
            {:cont, {:ok, [{path, witness} | acc]}}

          _ ->
            {:halt, unavailable()}
        end
      end)
    else
      _ -> unavailable()
    end
  end

  defp publish_bytes(path, bytes, sync) do
    case PrivateFile.write(path, bytes, @maximum, sync) do
      {:error, :private_custody_exists} ->
        case PrivateFile.read(path, @maximum) do
          {:ok, ^bytes} -> :ok
          {:ok, _} -> {:error, :generation_configuration_exists}
          _ -> unavailable()
        end

      other ->
        other
    end
  end

  defp bounded([], _), do: :ok
  defp bounded([_ | _], 0), do: {:error, :authoring_limit}
  defp bounded([_ | rest], n), do: bounded(rest, n - 1)
  defp bounded(_, _), do: invalid()
  defp invalid, do: {:error, :invalid_generation_configuration}
  defp changed, do: {:error, :generation_configuration_changed}
  defp unavailable, do: {:error, :generation_configuration_unavailable}
end
