defmodule WotexHome.MQTT.Connection do
  @moduledoc """
  Opens the publisher's single bounded EMQTT TCP or verified TLS connection.

  `WotexHome.MQTT.Publisher` calls `open/4` after source/report custody exists,
  supplying the connection configuration, checked exact Topic Names, publisher
  PID and private correlation token. Success returns `{:ok, connection}` with
  the linked client and private credit state. Startup failures return
  `{:error, :mqtt_connection_unavailable}`; a privacy-filter refusal returns
  `{:error, :mqtt_logging_unavailable}`.

  The zero-arity credential provider runs after `WotexHome.MQTT.LogFilter`
  installation. It returns `:none` or `{:password, username, password}`;
  password authentication requires TLS, a 1 to 128-byte UTF-8 username and a
  1 to 4,096-byte password. TLS verifies the peer chain and configured hostname
  with the supplied CA certificates. TLS session reuse and tickets are disabled
  so a new publisher verifies its own policy. No credential enters delivery messages.

  The client uses MQTT 3.1.1 with a clean session and no reconnect. Subscription
  requests use QoS 1; each grant must be QoS 0 or 1, and a resumed session refuses.
  Client connect/acknowledgement timeouts are three seconds; the publisher also
  bounds attachment as a whole.

  Callbacks stamp boot-monotonic microseconds and an unsigned 64-bit host receipt
  ordinal before enqueueing bytes and protocol metadata. A four-credit gate
  bounds raw deliveries, each at most 65,536 payload bytes on a selected topic.
  Invalid metadata, exhausted ordinals, overload or disconnect retires use.
  JSON interpretation and durable admission belong to the publisher and
  authority boundary. This client publishes no outbound device command; its
  receipt ordinal is neither a device sequence nor device authentication.
  """

  alias WotexHome.MQTT.{Configuration, LogFilter}
  @maximum 18_446_744_073_709_551_615

  @doc "Opens and subscribes once; the calling publisher owns and links the actual client."
  def open(config, topics, publisher, token) do
    with :ok <- Configuration.connection(config),
         :ok <- LogFilter.install(),
         {:ok, auth} <- credentials(config),
         credits = :atomics.new(1, signed: false),
         ordinal = :atomics.new(1, signed: false),
         handler = handler(publisher, token, credits, ordinal, topics),
         {:ok, client} <- :emqtt.start_link(options(config, publisher, handler, auth)) do
      result =
        with {:ok, _} <- :emqtt.connect(client),
             true <- Keyword.get(:emqtt.info(client), :session_present) in [0, false],
             {:ok, _, grants} <- :emqtt.subscribe(client, Enum.map(topics, &{&1, 1})),
             true <- length(grants) == length(topics) and Enum.all?(grants, &(&1 in [0, 1])) do
          {:ok, %{client: client, credits: credits, token: token}}
        else
          _ -> {:error, :mqtt_connection_unavailable}
        end

      if match?({:error, _}, result), do: Process.exit(client, :kill)
      result
    else
      {:error, :mqtt_logging_unavailable} = error -> error
      _ -> {:error, :mqtt_connection_unavailable}
    end
  rescue
    _ -> {:error, :mqtt_connection_unavailable}
  catch
    _, _ -> {:error, :mqtt_connection_unavailable}
  end

  @doc false
  def release(%{credits: credits}), do: :atomics.sub(credits, 1, 1)

  defp credentials(c) do
    case c.credentials.() do
      :none ->
        {:ok, []}

      {:password, user, pass}
      when not is_nil(c.tls) and is_binary(user) and is_binary(pass) and
             byte_size(user) in 1..128 and byte_size(pass) in 1..4096 ->
        if String.valid?(user), do: {:ok, [username: user, password: pass]}, else: :invalid

      _ ->
        :invalid
    end
  end

  defp options(c, publisher, handler, auth) do
    [
      host: c.address,
      port: c.port,
      owner: publisher,
      proto_ver: :v4,
      clean_start: true,
      reconnect: false,
      keepalive: 30,
      connect_timeout: 3,
      ack_timeout: 3,
      max_inflight: 1,
      properties: %{:"Maximum-Packet-Size" => 70_000},
      msg_handler: handler,
      tcp_opts: [ip: c.local_address, nodelay: true]
    ] ++ tls(c.tls) ++ auth
  end

  defp tls(nil), do: []

  defp tls(tls) do
    [
      ssl: true,
      ssl_opts: [
        verify: :verify_peer,
        reuse_sessions: false,
        session_tickets: :disabled,
        log_level: :none,
        cacerts: tls.cacerts,
        server_name_indication: String.to_charlist(tls.server_name),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]
  end

  defp handler(publisher, token, credits, ordinal, topics) do
    %{
      connected: fn _ -> :ok end,
      pubrel: fn _ -> :ok end,
      disconnected: fn _ ->
        send(publisher, {:mqtt_fault, token, self()})
        :ok
      end,
      publish: fn msg ->
        received = System.monotonic_time(:microsecond)

        with true <- valid?(msg, topics),
             true <- :atomics.add_get(credits, 1, 1) <= 4,
             n when is_integer(n) <- next(ordinal) do
          send(
            publisher,
            {:mqtt_frame, token, self(), n, received,
             Map.take(msg, [:payload, :topic, :qos, :retain, :dup])}
          )

          :ok
        else
          _ ->
            send(publisher, {:mqtt_fault, token, self()})
            exit(:mqtt_delivery_refused)
        end
      end
    }
  end

  defp valid?(
         %{
           payload: payload,
           topic: topic,
           qos: qos,
           retain: retain,
           dup: dup,
           client_pid: client
         },
         topics
       ) do
    is_binary(payload) and byte_size(payload) <= 65_536 and topic in topics and
      qos in [0, 1, 2] and is_boolean(retain) and is_boolean(dup) and client == self()
  end

  defp valid?(_, _), do: false

  defp next(counter) do
    n = :atomics.get(counter, 1)

    if n < @maximum do
      case :atomics.compare_exchange(counter, 1, n, n + 1) do
        :ok -> n + 1
        _ -> next(counter)
      end
    else
      :exhausted
    end
  end
end
