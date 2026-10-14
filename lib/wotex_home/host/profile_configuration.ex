defmodule WotexHome.Host.ProfileConfiguration do
  @moduledoc "Sealed immutable local authoring policy; no capture, publisher or device authority."
  alias WotexHome.Host.ProfileInstallation
  alias WotexHome.Profiles.{AuthoringContract, AuthoringProducer, EnvelopeCodec}
  alias WotexHome.Recovery.PrivateFile
  @format "wotex-home.profile-authoring-installation@1"
  @filename "profile-authoring-v1.json"
  @maximum 262_144

  defmodule Snapshot do
    @moduledoc false
    @enforce_keys [:path, :configuration, :seal, :sha256]
    @derive {Inspect, only: [:sha256]}
    defstruct @enforce_keys
  end

  def filename, do: @filename

  def decode(bytes) when is_binary(bytes) and byte_size(bytes) in 1..@maximum do
    options = [
      max_bytes: @maximum,
      max_depth: 8,
      max_nodes: 4096,
      max_collection_size: 1024,
      max_string_bytes: 4096
    ]

    with {:ok, data} <-
           AuthoringProducer.call(
             Wotex.JSON,
             :decode,
             [bytes, options],
             :invalid_profile_configuration
           ),
         true <- EnvelopeCodec.keys?(data, ~w(authoring_limits format installed)),
         true <- data["format"] == @format,
         configuration = %{
           mode: :authoring,
           installed: data["installed"],
           authoring_limits: data["authoring_limits"]
         },
         {:ok, prepared} <- ProfileInstallation.prepare(configuration) do
      {:ok, configuration, prepared}
    else
      false -> {:error, :invalid_profile_configuration}
      {:error, _} = error -> error
      _ -> {:error, :invalid_profile_configuration}
    end
  end

  def decode(bytes) when is_binary(bytes) and byte_size(bytes) > @maximum,
    do: {:error, :authoring_limit}

  def decode(_), do: {:error, :invalid_profile_configuration}

  def load(directory) when is_binary(directory) do
    if directory?(directory), do: load_private(directory), else: unavailable()
  end

  def load(_), do: unavailable()

  defp load_private(directory) do
    path = Path.join(directory, @filename)

    case File.lstat(path) do
      {:error, :enoent} ->
        {:ok, :absent}

      {:ok, _} ->
        with {:ok, bytes, seal} <- PrivateFile.read_sealed(path, @maximum),
             {:ok, configuration, _} <- decode(bytes) do
          {:ok,
           %Snapshot{
             path: path,
             configuration: configuration,
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

  def check(:absent, directory) do
    case File.lstat(Path.join(directory, @filename)) do
      {:error, :enoent} -> :ok
      _ -> changed()
    end
  end

  def check(%Snapshot{} = snapshot, directory) do
    with true <- snapshot.path == Path.join(directory, @filename),
         {:ok, bytes, seal} <- PrivateFile.read_sealed(snapshot.path, @maximum),
         true <- seal == snapshot.seal and AuthoringProducer.sha(bytes) == snapshot.sha256,
         {:ok, configuration, _} <- decode(bytes),
         true <- configuration == snapshot.configuration do
      :ok
    else
      _ -> changed()
    end
  end

  def check(_, _), do: changed()

  def publish(directory, source, sync \\ &:file.sync/1)

  def publish(directory, source, sync)
      when is_binary(directory) and is_binary(source) and is_function(sync, 1) do
    with true <- directory?(directory),
         {:ok, bytes, source_seal} <- PrivateFile.read_sealed(source, @maximum),
         {:ok, _, prepared} <- decode(bytes),
         {:ok, ^bytes, ^source_seal} <- PrivateFile.read_sealed(source, @maximum),
         {:ok, summary} <- AuthoringContract.to_map(prepared.authoring),
         :ok <- publish_bytes(Path.join(directory, @filename), bytes, sync) do
      {:ok,
       %{
         sha256: AuthoringProducer.sha(bytes),
         bindings: length(prepared.authoring.inputs["installed"]["bindings"]),
         contract_sha256: summary["contract_sha256"]
       }}
    else
      {:error, :private_custody_unavailable} -> unavailable()
      {:error, _} = error -> error
      _ -> unavailable()
    end
  end

  def publish(_, _, _), do: unavailable()

  defp directory?(directory),
    do:
      byte_size(directory) in 1..1024 and Path.type(directory) == :absolute and
        Path.expand(directory) == directory and not String.contains?(directory, <<0>>)

  defp publish_bytes(path, bytes, sync) do
    case PrivateFile.write(path, bytes, @maximum, sync) do
      {:error, :private_custody_exists} ->
        case PrivateFile.read(path, @maximum) do
          {:ok, ^bytes} -> :ok
          {:ok, _} -> {:error, :profile_configuration_exists}
          _ -> unavailable()
        end

      other ->
        other
    end
  end

  defp changed, do: {:error, :profile_configuration_changed}
  defp unavailable, do: {:error, :profile_configuration_unavailable}
end
