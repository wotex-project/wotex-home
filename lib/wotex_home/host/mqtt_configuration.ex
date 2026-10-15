defmodule WotexHome.Host.MQTTConfiguration do
  @moduledoc """
  Selects one sealed private MQTT source for an ordinary Host startup.

  `filename/0` names `mqtt-source-v1.json`. `decode/2` accepts its closed
  1 to 524,288-byte JSON document and a selected authoring configuration. It has
  exactly `format`, `profile`, `definitions`, `capture`, `source`, `channels`
  and `connection`, with format `wotex-home.mqtt-source@1`. The actual installed
  producer rebuilds the reader and compiles the profile/definition closure
  against the exact capture, bindings, Home contracts and reader limits.
  `WotexHome.MQTT.Configuration` then checks channels and the local connection.
  Success is `{:ok, prepared}` with the reconstructed profile, publisher inputs
  and authentication choice. Capture remains a host assertion; TLS verifies
  the broker, not the sensor.

  `load/2` returns `{:ok, snapshot}` for an immutable mode-0400 source file under
  the canonical private root, or `{:ok, absence}` with an ancestor witness when
  the fixed file is missing. A present source requires private authoring policy;
  it cannot fall back to authoring-only startup on invalid MQTT data. Password
  mode requires TLS and a separately sealed `WotexHome.MQTT.Credential`
  reference. Anonymous mode reads no credential file. The prepared publisher
  receives a resolver capturing the sealed reference, not a retained password.
  Missing authoring policy returns `{:error, :mqtt_profile_configuration_required}`;
  malformed and unavailable source data return `:invalid_mqtt_configuration` or
  `:mqtt_configuration_unavailable` in error tuples.

  `check/3` returns `:ok` only when the selected file seal, raw-byte hash and
  credential remain unchanged, or the witnessed absence still holds. Drift
  returns `:mqtt_configuration_changed` or `:mqtt_credential_changed` in an
  error tuple. No load or check opens a broker or selects a target.

  `publish/3` requires an existing private root, installed authoring policy and
  an explicit private source. It validates and rechecks before non-replacing,
  synchronized publication, returning `{:ok, %{sha256: digest, channels: count}}`.
  Exact-byte retry succeeds; different destination bytes return
  `{:error, :mqtt_configuration_exists}`. Invalid, unavailable and missing-policy
  refusals retain fixed configuration, credential or producer errors rather than
  file bodies or foreign failure terms.

  Install authoring and required credentials first, MQTT source policy last,
  then start `WotexHome.Host`. Selection is immutable for one Host incarnation;
  these files are neither hot-reloaded nor restored from Store/profile backups.
  """

  alias WotexHome.Host.{ProfileConfiguration, ProfileInstallation}
  alias WotexHome.MQTT.{Configuration, Credential}
  alias WotexHome.Profiles.{AuthoringProducer, EnvelopeCodec, ReaderSelection}
  alias WotexHome.Recovery.PrivateFile
  @filename "mqtt-source-v1.json"
  @maximum 524_288

  defmodule Snapshot do
    @moduledoc false

    @enforce_keys [:seal, :sha256, :prepared, :credential]
    @derive {Inspect, only: [:sha256]}
    defstruct @enforce_keys
  end

  defmodule Absence do
    @moduledoc false

    @enforce_keys [:directory, :witness]
    @derive {Inspect, only: []}
    defstruct @enforce_keys
  end

  def filename, do: @filename

  def decode(bytes, authoring) when is_binary(bytes) and byte_size(bytes) in 1..@maximum do
    with {:ok, data} <-
           AuthoringProducer.call(
             Wotex.JSON,
             :decode,
             [
               bytes,
               [
                 max_bytes: @maximum,
                 max_depth: 10,
                 max_nodes: 32768,
                 max_collection_size: 256,
                 max_string_bytes: 21848
               ]
             ],
             :invalid_mqtt_configuration
           ),
         true <-
           EnvelopeCodec.keys?(
             data,
             ~w(capture channels connection definitions format profile source)
           ),
         true <- data["format"] == "wotex-home.mqtt-source@1",
         {:ok, installation} <- ProfileInstallation.prepare(authoring),
         true <- installation != nil and authoring.mode == :authoring,
         installed = installation.authoring.inputs["installed"],
         limits = authoring.authoring_limits["reader"],
         {:ok, reader} <- ReaderSelection.new(installed, data["capture"], limits),
         closure =
           Map.put(
             Map.take(installed, ~w(bindings contracts)),
             "definitions",
             data["definitions"]
           ),
         {:ok, projection} <-
           Wotex.Profiles.Compiler.compile(data["profile"], closure, data["capture"], limits),
         {:ok, connection, authentication} <- connection(data["connection"]),
         config = %{
           reader: reader,
           projection: projection,
           source: data["source"],
           channels: data["channels"],
           connection: Map.put(connection, :credentials, fn -> :none end)
         },
         {:ok, _} <- Configuration.check(config, String.duplicate("0", 32)) do
      {:ok,
       %{
         profile: %{installation | reader: reader, capture: data["capture"]},
         publisher: %{config | connection: connection},
         authentication: authentication
       }}
    else
      {:error, :profiles_producer_unavailable} = error -> error
      _ -> invalid()
    end
  rescue
    _ -> invalid()
  catch
    _, _ -> invalid()
  end

  def decode(_, _), do: invalid()

  def load(root, authoring) do
    with {:ok, witness} <- PrivateFile.directory_witness(root) do
      case File.lstat(Path.join(root, @filename)) do
        {:error, :enoent} -> {:ok, %Absence{directory: root, witness: witness}}
        {:ok, _} -> load_present(root, authoring)
        _ -> unavailable()
      end
    else
      _ -> unavailable()
    end
  end

  defp load_present(_, nil), do: {:error, :mqtt_profile_configuration_required}

  defp load_present(root, authoring) do
    with {:ok, bytes, seal} <- PrivateFile.read_sealed(Path.join(root, @filename), @maximum),
         {:ok, prepared} <- decode(bytes, authoring),
         {:ok, credential} <- credential(root, prepared.authentication) do
      prepared = bind_provider(prepared, credential)

      {:ok,
       %Snapshot{
         seal: seal,
         sha256: AuthoringProducer.sha(bytes),
         prepared: prepared,
         credential: credential
       }}
    else
      {:error, :private_custody_unavailable} -> unavailable()
      error -> error
    end
  end

  def check(%Absence{directory: root, witness: witness}, root, _) do
    with {:ok, ^witness} <- PrivateFile.directory_witness(root),
         {:error, :enoent} <- File.lstat(Path.join(root, @filename)),
         do: :ok,
         else: (_ -> changed())
  end

  def check(:absent, root, _) do
    with {:ok, _} <- PrivateFile.directory_witness(root),
         {:error, :enoent} <- File.lstat(Path.join(root, @filename)),
         do: :ok,
         else: (_ -> changed())
  end

  def check(%Snapshot{} = snapshot, root, authoring) do
    with %PrivateFile.Seal{} <- snapshot.seal,
         true <- is_binary(root),
         true <- snapshot.seal.path == Path.join(root, @filename),
         {:ok, bytes, seal} <- PrivateFile.read_sealed(snapshot.seal.path, @maximum),
         true <- seal == snapshot.seal and AuthoringProducer.sha(bytes) == snapshot.sha256,
         {:ok, prepared} <- decode(bytes, authoring),
         true <- bind_provider(prepared, snapshot.credential) == snapshot.prepared,
         :ok <- credential_basis(snapshot.credential, root, prepared.authentication),
         do: :ok,
         else: (
           {:error, :mqtt_credential_changed} = error -> error
           _ -> changed()
         )
  end

  def check(_, _, _), do: changed()

  def publish(root, source, sync \\ &:file.sync/1) do
    with {:ok, _} <- PrivateFile.directory_witness(root),
         {:ok, %ProfileConfiguration.Snapshot{} = profile} <- ProfileConfiguration.load(root),
         {:ok, bytes, seal} <- PrivateFile.read_sealed(source, @maximum),
         {:ok, prepared} <- decode(bytes, profile.configuration),
         {:ok, credential} <- credential(root, prepared.authentication),
         :ok <- check_credential(credential),
         {:ok, ^bytes, ^seal} <- PrivateFile.read_sealed(source, @maximum),
         :ok <- ProfileConfiguration.check(profile, root),
         :ok <- write(Path.join(root, @filename), bytes, sync) do
      {:ok,
       %{sha256: AuthoringProducer.sha(bytes), channels: length(prepared.publisher.channels)}}
    else
      {:ok, :absent} -> {:error, :mqtt_profile_configuration_required}
      {:error, :private_custody_unavailable} -> unavailable()
      {:error, _} = error -> error
      _ -> unavailable()
    end
  end

  defp connection(c) do
    with true <- EnvelopeCodec.keys?(c, ~w(address authentication local_address port tls)),
         true <- c["authentication"] in ~w(none password),
         true <- c["authentication"] == "none" or c["tls"] != nil,
         {:ok, tls} <- tls(c["tls"]),
         {:ok, address} <- address(c["address"]),
         {:ok, local} <- address(c["local_address"]) do
      {:ok, %{address: address, local_address: local, port: c["port"], tls: tls},
       c["authentication"]}
    else
      _ -> invalid()
    end
  end

  defp address([a, b, c, d]) when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255,
    do: {:ok, {a, b, c, d}}

  defp address(_), do: invalid()
  defp tls(nil), do: {:ok, nil}

  defp tls(value) do
    with true <- EnvelopeCodec.keys?(value, ~w(cacerts server_name)),
         certs when is_list(certs) and length(certs) in 1..8 <- value["cacerts"],
         {:ok, certs} <-
           Enum.reduce_while(certs, {:ok, []}, fn encoded, {:ok, acc} ->
             case Base.decode64(encoded) do
               {:ok, der} ->
                 if Base.encode64(der) == encoded,
                   do: {:cont, {:ok, acc ++ [der]}},
                   else: {:halt, invalid()}

               _ ->
                 {:halt, invalid()}
             end
           end),
         do: {:ok, %{server_name: value["server_name"], cacerts: certs}},
         else: (_ -> invalid())
  end

  defp credential(_, "none"), do: {:ok, :none}
  defp credential(root, "password"), do: Credential.load(root)

  defp bind_provider(prepared, credential),
    do: put_in(prepared, [:publisher, :connection, :credentials], provider(credential))

  defp provider(:none), do: fn -> :none end
  defp provider(credential), do: fn -> Credential.resolve(credential) end
  defp credential_basis(:none, _, "none"), do: :ok

  defp credential_basis(
         %Credential{seal: %PrivateFile.Seal{path: path}} = reference,
         root,
         "password"
       ) do
    if path == Path.join(root, Credential.filename()),
      do: Credential.check(reference),
      else: {:error, :mqtt_credential_changed}
  end

  defp credential_basis(_, _, _), do: {:error, :mqtt_credential_changed}
  defp check_credential(:none), do: :ok
  defp check_credential(reference), do: Credential.check(reference)

  defp write(path, bytes, sync) do
    case PrivateFile.write(path, bytes, @maximum, sync) do
      {:error, :private_custody_exists} ->
        case PrivateFile.read(path, @maximum) do
          {:ok, ^bytes} -> :ok
          {:ok, _} -> {:error, :mqtt_configuration_exists}
          _ -> unavailable()
        end

      result ->
        result
    end
  end

  defp invalid, do: {:error, :invalid_mqtt_configuration}
  defp unavailable, do: {:error, :mqtt_configuration_unavailable}
  defp changed, do: {:error, :mqtt_configuration_changed}
end
