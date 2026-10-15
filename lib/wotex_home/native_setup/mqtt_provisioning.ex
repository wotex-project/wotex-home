defmodule WotexHome.NativeSetup.MQTTProvisioning do
  @moduledoc """
  Prepares and publishes sealed native MQTT policy without starting Home.

  `prepare/3` takes an existing private Home root and explicit authoring/MQTT
  source paths. It reconstructs both installed-producer contracts, rechecks the
  original file and root witnesses, and refuses conflicting destinations. It
  writes nothing, acquires no Host gate, opens no Store and contacts no broker.
  Paths must be canonical absolute UTF-8 paths of 1..1,024 bytes, without NUL;
  source files must satisfy `WotexHome.Recovery.PrivateFile` custody checks.
  Authoring and MQTT source reads are bounded to 262,144 and 524,288 bytes.

  Success is `{:ok, summary}` with `:authoring_sha256`, `:source_sha256`,
  `:basis_sha256`, `:root_sha256`, `:channels` and `:authentication`. Digests are
  lowercase hex64; channels is 1..32 and authentication is `"none"`, `"password"`
  or `"keychain"`. Only the file digests, channel count and authentication mode
  are presentation data. Basis/root digests are private same-release
  correspondence witnesses, not producer identities or authority grants.

  Pass exactly the four digest fields from that summary as the expected map to
  `publish/4`. `publish/5` additionally accepts the immutable writers' sync
  callback; the default is `&:file.sync/1`. Publication rechecks the root and holds
  `WotexHome.Durable.HostLock` on the separate `home.sqlite.owner.sqlite` sidecar,
  without opening `home.sqlite`. It first confirms an identical sealed installed
  pair, so confirmation can succeed without the original source files. Otherwise
  it rechecks the original sources and publishes authoring first, MQTT last.
  Different destination bytes are never overwritten.

  The two immutable publications are not one transaction. After the first writer
  may have run, a failure returns `{:error, :native_mqtt_publication_uncertain}`;
  partially installed authoring policy is not rolled back. Retain the original
  preparation for an explicit identical retry. There is no automatic retry,
  Host restart, password-file conversion or alternate Keychain account selection.
  A lost or late reply after a possible write must also remain uncertain to the
  caller, even when no closed error was received.

  Preparation and publication return `{:ok, summary}` or `{:error, reason}`.
  Closed reasons are
  `:invalid_native_mqtt_provisioning`, `:native_mqtt_source_changed`,
  `:native_mqtt_publication_conflict`, `:native_mqtt_host_running`,
  `:native_mqtt_publication_uncertain` and
  `:native_mqtt_provisioning_unavailable`.

  `main/0` is the fixed one-request foreground release entry. It requires
  `WOTEX_HOME_DATA_DIR`, prepares stdio/Logger and starts required dependencies
  without starting Home. Its worker uses one 15-second monotonic deadline and
  4-byte big-endian frames with 1..4,096-byte canonical JSON bodies. `request/1`
  parses a body; `response/2` encodes a checked operation result. Logger goes to
  stderr and diagnostics omit paths, source bodies and foreign errors.

  This module supplies the release-side protocol, not a native setup UI. A native
  caller must enforce its actual signed-bundle identity, original launch-to-reply
  deadline, selection/session fencing and uncertainty handling. A successful
  response establishes no signing evidence, current-target grant or physical
  qualification.
  """

  alias WotexHome.Durable.HostLock
  alias WotexHome.Host.{MQTTConfiguration, ProfileConfiguration}
  alias WotexHome.NativeSetup.CoreHost
  alias WotexHome.Profiles.AuthoringProducer
  alias WotexHome.Recovery.PrivateFile
  @format "wotex-home.native-mqtt-provision@1"
  @reasons ~w(invalid_native_mqtt_provisioning native_mqtt_source_changed native_mqtt_publication_conflict native_mqtt_host_running native_mqtt_publication_uncertain native_mqtt_provisioning_unavailable)a

  def prepare(root, authoring, source) do
    with {:ok, state} <- inputs(root, authoring, source),
         :ok <- destinations(root, state.summary),
         :ok <- current(state),
         do: {:ok, state.summary},
         else: (error -> closed(error))
  rescue
    _ -> unavailable()
  catch
    _, _ -> unavailable()
  end

  def publish(root, authoring, source, expected, sync \\ &:file.sync/1) do
    publish_guarded(root, authoring, source, expected, sync, fn -> true end)
  end

  defp publish_guarded(root, authoring, source, expected, sync, fresh) do
    with true <- valid_expected?(expected),
         true <- fresh.(),
         {:ok, root_sha} <- root_digest(root),
         true <- root_sha == expected.root_sha256,
         {:ok, lock} <- acquire(root) do
      try do
        case installed(root, expected) do
          {:ok, summary} -> {:ok, summary}
          :incomplete -> publish_original(root, authoring, source, expected, sync, fresh)
          error -> closed(error)
        end
      after
        HostLock.release(lock)
      end
    else
      false -> changed()
      error -> closed(error)
    end
  rescue
    _ -> unavailable()
  catch
    _, _ -> unavailable()
  end

  defp publish_original(root, authoring, source, expected, sync, fresh) do
    with {:ok, state} <- inputs(root, authoring, source),
         true <- Map.take(state.summary, Map.keys(expected)) == expected,
         :ok <- destinations(root, expected),
         :ok <- current(state),
         true <- fresh.() do
      # From this boundary onward even a fixed failure may leave the first
      # immutable policy present. Retry confirms existing files before sources.
      try do
        with {:ok, _} <- ProfileConfiguration.publish(root, authoring, sync),
             :ok <- current(state),
             true <- fresh.(),
             {:ok, _} <- MQTTConfiguration.publish(root, source, sync),
             {:ok, summary} <- installed(root, expected),
             do: {:ok, summary},
             else: (_ -> uncertain())
      rescue
        _ -> uncertain()
      catch
        _, _ -> uncertain()
      end
    else
      false -> changed()
      error -> closed(error)
    end
  end

  defp inputs(root, authoring, source) do
    with true <- path?(authoring) and path?(source),
         {:ok, root_sha} <- root_digest(root),
         {:ok, a, a_seal} <- PrivateFile.read_sealed(authoring, 262_144),
         {:ok, configuration, _} <- ProfileConfiguration.decode(a),
         {:ok, s, s_seal} <- PrivateFile.read_sealed(source, 524_288),
         {:ok, prepared} <- MQTTConfiguration.decode(s, configuration) do
      a_sha = AuthoringProducer.sha(a)
      s_sha = AuthoringProducer.sha(s)
      basis = digest({"wotex-home.native-mqtt-basis@1", root_sha, a_seal, s_seal, a_sha, s_sha})

      summary = %{
        authoring_sha256: a_sha,
        source_sha256: s_sha,
        basis_sha256: basis,
        root_sha256: root_sha,
        channels: length(prepared.publisher.channels),
        authentication: prepared.authentication
      }

      {:ok, %{root: root, authoring: a_seal, source: s_seal, summary: summary}}
    else
      {:error, :private_custody_unavailable} -> unavailable()
      {:error, :native_mqtt_provisioning_unavailable} = error -> error
      _ -> invalid()
    end
  end

  defp current(state) do
    a_seal = state.authoring
    s_seal = state.source

    with :ok <- PrivateFile.check(state.authoring),
         :ok <- PrivateFile.check(state.source),
         {:ok, root_sha} <- root_digest(state.root),
         true <- root_sha == state.summary.root_sha256,
         {:ok, a, ^a_seal} <- PrivateFile.read_sealed(state.authoring.path, 262_144),
         {:ok, s, ^s_seal} <- PrivateFile.read_sealed(state.source.path, 524_288),
         true <- AuthoringProducer.sha(a) == state.summary.authoring_sha256,
         true <- AuthoringProducer.sha(s) == state.summary.source_sha256,
         do: :ok,
         else: (_ -> changed())
  end

  defp installed(root, expected) do
    with :ok <- destinations(root, expected),
         {:ok, state} <-
           inputs(
             root,
             Path.join(root, ProfileConfiguration.filename()),
             Path.join(root, MQTTConfiguration.filename())
           ),
         :ok <- current(state),
         true <- state.summary.root_sha256 == expected.root_sha256 do
      {:ok, %{state.summary | basis_sha256: expected.basis_sha256}}
    else
      {:error, :native_mqtt_publication_conflict} = error ->
        error

      _ ->
        if Enum.any?([ProfileConfiguration.filename(), MQTTConfiguration.filename()], fn name ->
             File.lstat(Path.join(root, name)) == {:error, :enoent}
           end), do: :incomplete, else: unavailable()
    end
  end

  defp destinations(root, expected) do
    Enum.reduce_while(
      [
        {ProfileConfiguration.filename(), expected.authoring_sha256, 262_144},
        {MQTTConfiguration.filename(), expected.source_sha256, 524_288}
      ],
      :ok,
      fn {name, sha, maximum}, _ ->
        path = Path.join(root, name)

        case File.lstat(path) do
          {:error, :enoent} ->
            {:cont, :ok}

          {:ok, _} ->
            case PrivateFile.read_sealed(path, maximum) do
              {:ok, bytes, _} ->
                if AuthoringProducer.sha(bytes) == sha,
                  do: {:cont, :ok},
                  else: {:halt, conflict()}

              _ ->
                {:halt, unavailable()}
            end

          _ ->
            {:halt, unavailable()}
        end
      end
    )
  end

  defp acquire(root) do
    case HostLock.acquire(Path.join(root, "home.sqlite")) do
      {:ok, lock} -> {:ok, lock}
      {:error, :already_running} -> {:error, :native_mqtt_host_running}
      _ -> unavailable()
    end
  end

  defp root_digest(root) do
    with true <- path?(root),
         {:ok, witness} <- PrivateFile.directory_witness(root),
         do: {:ok, digest({"wotex-home.native-mqtt-root@1", witness})},
         else: (_ -> unavailable())
  end

  defp digest(term), do: AuthoringProducer.sha(:erlang.term_to_binary(term, [:deterministic]))

  defp path?(path),
    do:
      is_binary(path) and byte_size(path) in 1..1024 and String.valid?(path) and
        Path.type(path) == :absolute and Path.expand(path) == path and
        not String.contains?(path, <<0>>)

  defp sha?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp valid_expected?(value),
    do:
      is_map(value) and not is_struct(value) and
        Enum.sort(Map.keys(value)) ==
          Enum.sort(~w(authoring_sha256 source_sha256 basis_sha256 root_sha256)a) and
        Enum.all?(Map.values(value), &sha?/1)

  def request(bytes) when is_binary(bytes) and byte_size(bytes) in 1..4096 do
    with {:ok, values} <-
           AuthoringProducer.call(
             Wotex.JSON,
             :decode,
             [
               bytes,
               [
                 max_bytes: 4096,
                 max_depth: 2,
                 max_nodes: 9,
                 max_collection_size: 8,
                 max_string_bytes: 1024
               ]
             ],
             :invalid_native_mqtt_provisioning
           ),
         true <- JSON.encode!(values) == bytes do
      case values do
        [@format, "prepare", a, s] ->
          if path?(a) and path?(s), do: {:ok, {:prepare, a, s}}, else: invalid()

        [@format, "publish", a, s, a_sha, s_sha, basis, root] ->
          expected = %{
            authoring_sha256: a_sha,
            source_sha256: s_sha,
            basis_sha256: basis,
            root_sha256: root
          }

          if path?(a) and path?(s) and valid_expected?(expected),
            do: {:ok, {:publish, a, s, expected}},
            else: invalid()

        _ ->
          invalid()
      end
    else
      _ -> invalid()
    end
  end

  def request(_), do: invalid()

  def response(kind, {:ok, summary}) when kind in ~w(prepared published),
    do:
      JSON.encode!([
        @format,
        kind,
        summary.authoring_sha256,
        summary.source_sha256,
        summary.basis_sha256,
        summary.root_sha256,
        summary.channels,
        summary.authentication
      ])

  def response(_, {:error, reason}) when reason in @reasons,
    do: JSON.encode!([@format, "error", Atom.to_string(reason)])

  def main do
    if CoreHost.running_home?() do
      unavailable()
    else
      deadline = System.monotonic_time(:millisecond) + 15_000

      status =
        with :ok <- CoreHost.prepare_foreground(),
             :ok <- CoreHost.start_dependencies(),
             root when is_binary(root) <- System.get_env("WOTEX_HOME_DATA_DIR"),
             do: exchange(root, deadline),
             else: (_ -> 1)

      if status != 0, do: IO.puts(:stderr, "native MQTT provisioning unavailable")
      System.stop(status)
    end
  end

  defp exchange(root, deadline) do
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        status =
          try do
            with <<size::32>> when size in 1..4096 <- IO.binread(:stdio, 4),
                 bytes when is_binary(bytes) and byte_size(bytes) == size <-
                   IO.binread(:stdio, size),
                 {:ok, operation} <- request(bytes) do
              {kind, result} =
                case operation do
                  {:prepare, a, s} ->
                    {"prepared", prepare(root, a, s)}

                  {:publish, a, s, expected} ->
                    {"published",
                     publish_guarded(root, a, s, expected, &:file.sync/1, fn ->
                       System.monotonic_time(:millisecond) < deadline
                     end)}
                end

              body = response(kind, result)
              if IO.binwrite(:stdio, <<byte_size(body)::32, body::binary>>) == :ok, do: 0, else: 1
            else
              _ ->
                body = response("error", invalid())
                _ = IO.binwrite(:stdio, <<byte_size(body)::32, body::binary>>)
                1
            end
          rescue
            _ -> 1
          catch
            _, _ -> 1
          end

        send(parent, {:provisioned, self(), status})
      end)

    receive do
      {:provisioned, ^pid, status} ->
        Process.demonitor(monitor, [:flush])
        status

      {:DOWN, ^monitor, :process, ^pid, _} ->
        1
    after
      max(0, deadline - System.monotonic_time(:millisecond)) ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
        1
    end
  end

  defp closed({:error, reason} = error) when reason in @reasons, do: error
  defp closed(_), do: unavailable()
  defp changed, do: {:error, :native_mqtt_source_changed}
  defp invalid, do: {:error, :invalid_native_mqtt_provisioning}
  defp unavailable, do: {:error, :native_mqtt_provisioning_unavailable}
  defp conflict, do: {:error, :native_mqtt_publication_conflict}
  defp uncertain, do: {:error, :native_mqtt_publication_uncertain}
end
