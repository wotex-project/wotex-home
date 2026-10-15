defmodule WotexHome.TestSupport.MQTTFixture do
  @moduledoc false

  alias Wotex.Profiles.{Binding, Capture, Compiler, Profile}
  alias WotexHome.Profiles.{ProducerIdentity, ReaderSelection}

  def fixture(name), do: JSON.decode!(File.read!("test/fixtures/profiles/#{name}.json"))

  def configuration(port) do
    v = fixture("temperature")
    limits = v["reader_limits"]

    binding =
      v["bindings"]
      |> hd()
      |> Map.delete("sha256")
      |> Map.put("id", "urn:example:binding:mqtt")
      |> Map.put("selector_schema", Wotex.Binding.MQTT.JSONProjection.selector_schema())
      |> Map.put("operations", ["observeproperty"])

    {:ok, sha} = Binding.digest(binding, limits)
    binding = Map.put(binding, "sha256", sha)
    {:ok, reference} = Binding.reference(binding, limits)
    capture = v["capture"] |> Map.delete("digest") |> Map.put("binding", reference)
    {:ok, digest} = Capture.digest(capture, binding, limits)
    capture = Map.put(capture, "digest", digest)

    channel =
      v["profile"]["channels"]
      |> hd()
      |> Map.put("operations", ["observeproperty"])
      |> Map.put("selector", %{"topic" => "test/temperature", "path" => ["value"]})

    profile = v["profile"] |> Map.put("binding", reference) |> Map.put("channels", [channel])
    {:ok, ref} = Profile.reference(profile, limits)
    envelope = Map.put(v["envelope"], "profile", ref)
    {:ok, producer} = ProducerIdentity.current()

    installed = %{
      "bindings" => [binding],
      "contracts" => v["contracts"],
      "home_contracts" => v["home_contracts"],
      "producer" => producer
    }

    {:ok, reader} = ReaderSelection.new(installed, capture, limits)

    closure =
      Map.take(installed, ~w(bindings contracts)) |> Map.put("definitions", v["definitions"])

    {:ok, projection} = Compiler.compile(profile, closure, capture, limits)
    source = fixture("external-source-selections")["temperature"]["inputs"]

    config = %{
      reader: reader,
      projection: projection,
      source:
        source["source"]
        |> Map.delete("source_epoch")
        |> Map.put("trust", "unauthenticated_local"),
      channels: source["channels"],
      connection: %{
        address: {127, 0, 0, 1},
        local_address: {127, 0, 0, 1},
        port: port,
        tls: nil,
        credentials: fn -> :none end
      }
    }

    {config,
     %{
       v
       | "bindings" => [binding],
         "capture" => capture,
         "profile" => profile,
         "envelope" => envelope
     }}
  end

  # Independent MQTT 3.1.1 peer: literal CONNECT/SUBACK/PUBLISH wire bytes.
  def multi_configuration(port) do
    {config, v} = configuration(port)
    first = hd(v["profile"]["channels"])

    second =
      first
      |> Map.put("id", "second")
      |> put_in(["affordance", "name"], "other")
      |> put_in(["selector", "path"], ["other"])

    profile = Map.put(v["profile"], "channels", [first, second])
    {:ok, ref} = Profile.reference(profile, v["reader_limits"])

    envelope =
      v["envelope"]
      |> Map.put("profile", ref)
      |> update_in(["home_contracts"], fn [c] -> [c, Map.put(c, "channel_id", "second")] end)

    {:ok, projection} =
      Compiler.compile(
        profile,
        config.projection.inputs["closure"],
        v["capture"],
        v["reader_limits"]
      )

    policy =
      hd(config.channels)
      |> Map.put("channel_id", "second")
      |> put_in(["policy", "capability_key"], "second")

    {%{config | projection: projection, channels: config.channels ++ [policy]},
     %{v | "profile" => profile, "envelope" => envelope}}
  end

  def broker(owner, options \\ []) do
    transport = if options[:tls], do: :ssl, else: :gen_tcp
    opts = [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}] ++ (options[:tls] || [])
    {:ok, listener} = apply(transport, :listen, [0, opts])
    {:ok, {_, port}} = apply(if(transport == :ssl, do: :ssl, else: :inet), :sockname, [listener])

    pid =
      spawn(fn ->
        result =
          if transport == :ssl do
            with {:ok, socket} <- :ssl.transport_accept(listener, 6_000),
                 {:ok, socket} <- :ssl.handshake(socket, 4_000),
                 do: {:ok, socket}
          else
            :gen_tcp.accept(listener, 6_000)
          end

        apply(transport, :close, [listener])

        case result do
          {:ok, socket} ->
            case packet(transport, socket) do
              {:ok, 0x10, connect} ->
                send(owner, {:mqtt_connect, self(), connect})
                :ok = apply(transport, :send, [socket, <<0x20, 2, options[:session] || 0, 0>>])

                case packet(transport, socket) do
                  {:ok, 0x82, <<id::16, subscription::binary>>} ->
                    send(owner, {:mqtt_subscribe, self(), subscription})

                    :ok =
                      apply(transport, :send, [socket, <<0x90, 3, id::16, options[:grant] || 1>>])

                    loop(transport, socket, owner)

                  _ ->
                    apply(transport, :close, [socket])
                end

              _ ->
                send(owner, {:mqtt_no_connect, self()})
                apply(transport, :close, [socket])
            end

          _ ->
            send(owner, {:mqtt_no_connect, self()})
        end
      end)

    {pid, port}
  end

  defp loop(transport, socket, owner) do
    receive do
      {:send, bytes} ->
        send(owner, {:mqtt_sent, self(), apply(transport, :send, [socket, bytes])})
        loop(transport, socket, owner)

      :close ->
        apply(transport, :close, [socket])

      :probe ->
        send(owner, {:mqtt_probe, self(), apply(transport, :recv, [socket, 0, 100])})
        loop(transport, socket, owner)
    after
      15_000 -> apply(transport, :close, [socket])
    end
  end

  def publish(payload, flags \\ 0, topic \\ "test/temperature") do
    body = <<byte_size(topic)::16, topic::binary, payload::binary>>
    IO.iodata_to_binary([<<0x30 + flags>>, remaining(byte_size(body)), body])
  end

  defp remaining(n) when n < 128, do: <<n>>
  defp remaining(n), do: [<<rem(n, 128) + 128>>, remaining(div(n, 128))]

  defp packet(transport, socket) do
    with {:ok, <<header>>} <- apply(transport, :recv, [socket, 1, 4_000]),
         {:ok, size} <- length_field(transport, socket, 0, 1),
         {:ok, body} <- apply(transport, :recv, [socket, size, 4_000]),
         do: {:ok, header, body}
  end

  defp length_field(transport, socket, n, mult) when mult <= 2_097_152 do
    with {:ok, <<byte>>} <- apply(transport, :recv, [socket, 1, 4_000]) do
      n = n + rem(byte, 128) * mult
      if byte < 128, do: {:ok, n}, else: length_field(transport, socket, n, mult * 128)
    end
  end
end
