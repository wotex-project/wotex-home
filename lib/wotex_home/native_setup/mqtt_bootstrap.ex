defmodule WotexHome.NativeSetup.MQTTBootstrap do
  @moduledoc """
  Exchanges one source-scoped broker credential on the native parent's pipes.

  `run/2` first uses `WotexHome.Host.MQTTConfiguration.native_request/1` to
  reconstruct the actual sealed source policy before Store startup. Keychain
  policy requests only that source's raw digest; absent, anonymous and password
  policy exchange the explicit `none` record. The default device is stdio
  on the original private parent channel, not a listener or public API route.

  One guarded five-second exchange covers request writing and reply reading
  after selection. Frames have a four-byte unsigned big-endian length; replies
  contain 1 to 8,192 bytes of exact canonical compact JSON. The credential reply
  must repeat the original digest and satisfy `WotexHome.MQTT.Credential`
  validation. Timeout, malformed framing or mismatched replies return
  `{:error, :invalid_native_mqtt_bootstrap}` without retry.

  Success is `{:ok, nil}` for a `none` exchange or `{:ok, capability}` from
  `WotexHome.MQTT.NativeCredential` for a source-bound pair. Owner startup can
  return `{:error, :mqtt_native_credential_unavailable}`. `request/1` encodes the
  trusted selection; `reply/2` validates a body and returns `{:ok, nil}` or
  `{:ok, credential}`. The decoded credential is secret, not status metadata.

  The guardian retires outstanding exchange work if its caller dies. This
  Elixir protocol neither reads Keychain nor verifies a signed native parent;
  actual signing and Keychain checks belong to that parent's protected startup
  path. A valid reply alone establishes no installed or physical qualification.
  """

  alias WotexHome.Host.MQTTConfiguration
  alias WotexHome.MQTT.{Credential, NativeCredential}
  alias WotexHome.Profiles.AuthoringProducer
  @format "wotex-home.native-mqtt-bootstrap@1"

  def request(nil), do: JSON.encode!([@format, "none"])
  def request(%{sha256: sha}), do: JSON.encode!([@format, "credential", sha])

  def reply(bytes, nil) do
    if bytes == request(nil), do: {:ok, nil}, else: invalid()
  end

  def reply(bytes, %{sha256: sha}) when is_binary(bytes) and byte_size(bytes) in 1..8192 do
    with {:ok, [@format, "credential", ^sha, user, password]} <-
           AuthoringProducer.call(
             Wotex.JSON,
             :decode,
             [
               bytes,
               [
                 max_bytes: 8192,
                 max_depth: 2,
                 max_nodes: 6,
                 max_collection_size: 5,
                 max_string_bytes: 5464
               ]
             ],
             :invalid_native_mqtt_bootstrap
           ),
         true <- JSON.encode!([@format, "credential", sha, user, password]) == bytes,
         {:ok, pair} <-
           Credential.decode(
             JSON.encode!(%{
               "format" => "wotex-home.mqtt-credential@1",
               "username" => user,
               "password_base64" => password
             })
           ),
         do: {:ok, pair},
         else: (_ -> invalid())
  end

  def reply(_, _), do: invalid()

  def run(root, device \\ :stdio) do
    with {:ok, selected} <- MQTTConfiguration.native_request(root),
         body = request(selected),
         {:ok, bytes, deadline} <- exchange(device, body),
         {:ok, credential} <- reply(bytes, selected),
         true <- now() < deadline do
      if selected == nil,
        do: {:ok, nil},
        else: NativeCredential.start_link(selected.sha256, selected.seal, credential)
    else
      _ -> invalid()
    end
  rescue
    _ -> invalid()
  catch
    _, _ -> invalid()
  end

  defp exchange(device, body) do
    parent = self()
    ref = make_ref()
    deadline = now() + 5_000

    {pid, monitor} =
      spawn_monitor(fn ->
        guardian = self()
        caller = Process.monitor(parent)

        {worker, work} =
          spawn_monitor(fn ->
            result =
              try do
                with :ok <- IO.binwrite(device, <<byte_size(body)::32, body::binary>>),
                     <<size::32>> when size in 1..8192 <- IO.binread(device, 4),
                     bytes when is_binary(bytes) and byte_size(bytes) == size <-
                       IO.binread(device, size),
                     do: {:ok, bytes},
                     else: (_ -> invalid())
              rescue
                _ -> invalid()
              catch
                _, _ -> invalid()
              end

            send(guardian, {ref, result})
          end)

        receive do
          {^ref, result} -> send(parent, {ref, result})
          {:DOWN, ^work, :process, ^worker, _} -> send(parent, {ref, invalid()})
          {:DOWN, ^caller, :process, ^parent, _} -> :ok
        after
          max(0, deadline - now()) -> send(parent, {ref, invalid()})
        end

        Process.exit(worker, :kill)
      end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])

        case result do
          {:ok, bytes} -> if now() < deadline, do: {:ok, bytes, deadline}, else: invalid()
          _ -> invalid()
        end

      {:DOWN, ^monitor, :process, ^pid, _} ->
        invalid()
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
  defp invalid, do: {:error, :invalid_native_mqtt_bootstrap}
end
