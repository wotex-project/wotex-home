Code.require_file("../support/mqtt_fixture.exs", __DIR__)
Code.require_file("../support/controller_tls_fixture.exs", __DIR__)

defmodule WotexHome.MQTTPublisherTest do
  @moduledoc false

  use ExUnit.Case, async: false
  alias WotexHome.{Authority, MQTT.Publisher}
  alias WotexHome.Durable.Store
  alias WotexHome.Profiles.{Custody, ExternalSourceOwner, ExternalReportOwner}
  alias WotexHome.TestSupport.MQTTFixture, as: F
  @store __MODULE__.Store
  @moduletag :requires_socket

  setup do
    root = Path.join(System.tmp_dir!(), "home-mqtt-#{System.unique_integer([:positive])}")
    root = if String.starts_with?(root, "/var/"), do: "/private" <> root, else: root
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp start(c, options \\ []) do
    {broker, port} = F.broker(self(), options)
    on_exit(fn -> Process.exit(broker, :kill) end)
    {config, v} = if options[:multi], do: F.multi_configuration(port), else: F.configuration(port)

    config =
      if options[:connection],
        do: %{config | connection: Map.merge(config.connection, options[:connection])},
        else: config

    publisher = start_supervised!({Publisher, config})
    sources = start_supervised!({ExternalSourceOwner, publisher: publisher})

    reports =
      start_supervised!(
        {ExternalReportOwner, publisher: publisher, source_owner: sources, store_owner: @store}
      )

    custody_root = Path.join(c.root, "profiles")
    File.mkdir!(custody_root)
    File.chmod!(custody_root, 0o700)
    custody = start_supervised!({Custody, root: custody_root, store_owner: @store})

    store =
      start_supervised!(
        {Store,
         name: @store,
         path: Path.join(c.root, "home.sqlite"),
         profile_custody: custody,
         external_reader: config.reader,
         external_source_owner: sources,
         external_report_owner: reports}
      )

    Map.merge(c, %{
      broker: broker,
      config: config,
      v: v,
      publisher: publisher,
      sources: sources,
      reports: reports,
      store: store,
      authority: Authority.new(store: store)
    })
  end

  defp attach(c) do
    assert :ok = Publisher.attach(c.publisher, c.authority, c.sources, c.reports)
    assert_receive {:mqtt_connect, broker, <<0, 4, "MQTT", 4, 2, 0, 30, _::binary>>}
    assert broker == c.broker
    assert_receive {:mqtt_subscribe, ^broker, <<0, 16, "test/temperature", 1>>}
    c
  end

  defp wait(fun, attempts \\ 100)
  defp wait(_, 0), do: flunk("bounded MQTT transition did not complete")

  defp wait(fun, n) do
    case fun.() do
      false ->
        Process.sleep(10)
        wait(fun, n - 1)

      result ->
        result
    end
  end

  defp send_frame(c, payload, flags \\ 0) do
    send(c.broker, {:send, F.publish(payload, flags)})
    assert_receive {:mqtt_sent, _, :ok}
  end

  defp status(c, count) do
    wait(fn ->
      case Publisher.status(c.publisher) do
        {:ok, %{received: ^count, pending_frames: 0} = status} -> status
        _ -> false
      end
    end)
  end

  test "actual broker report reaches the current reviewed Store target with exact units", c do
    c = start(c) |> attach() |> F.select_target()
    send_frame(c, ~s({"value":250}))
    assert %{accepted: 1, refused: 0} = status(c, 1)

    assert {:ok, preview} =
             Authority.external_report_current(
               c.authority,
               c.reader_credential,
               "sensor:external",
               "sample"
             )

    assert preview["freshness"] == "fresh"
    assert preview["value"]["normalized_value"] == %{"type" => "sint", "value" => "25000"}
    send_frame(c, ~s({"value":260}), 1)
    assert %{accepted: 2} = status(c, 2)

    assert {:ok, retained} =
             Authority.external_report_current(
               c.authority,
               c.reader_credential,
               "sensor:external",
               "sample"
             )

    assert retained["freshness"] == "unknown" and retained["reason"] == "retained"
  end

  test "one actual frame projects each configured channel through current selection", c do
    c = start(c, multi: true) |> attach() |> F.select_target()
    :ok = :sys.suspend(c.store)
    send_frame(c, ~s({"value":250,"other":260}))

    reports =
      wait(fn ->
        entries = :sys.get_state(c.reports).entries
        if map_size(entries) == 2, do: Enum.map(Map.values(entries), & &1.report), else: false
      end)

    assert Enum.map(reports, & &1["sequence"]) == ["1", "1"]
    assert reports |> Enum.map(& &1["receipt_time"]) |> Enum.uniq() |> length() == 1
    :ok = :sys.resume(c.store)
    assert %{accepted: 2, refused: 0} = status(c, 1)

    for {channel, expected} <- [{"sample", "25000"}, {"second", "26000"}] do
      assert {:ok, preview} =
               Authority.external_report_current(
                 c.authority,
                 c.reader_credential,
                 "sensor:external",
                 channel
               )

      assert preview["freshness"] == "fresh"
      assert preview["value"]["normalized_value"] == %{"type" => "sint", "value" => expected}
    end
  end

  test "lost worker reply reconciles the same original without another revision or receive time",
       c do
    c = start(c) |> attach() |> F.select_target()
    :ok = :sys.suspend(c.store)
    send_frame(c, ~s({"value":250}))

    worker =
      wait(fn ->
        case :sys.get_state(c.publisher).active do
          nil -> false
          active -> active.worker
        end
      end)

    Process.exit(worker, :kill)

    uncertain =
      wait(fn ->
        case Publisher.status(c.publisher) do
          {:ok, %{phase: :uncertain, uncertain: [original]}} -> original
          _ -> false
        end
      end)

    before = :sys.get_state(c.reports).entries[uncertain["report_id"]]
    assert before.report["receipt_time"]["monotonic_us"] != nil
    :ok = :sys.resume(c.store)
    assert {:ok, _} = Store.health(c.store)
    assert {:ok, first} = Authority.accept_external_report(c.authority, uncertain)
    assert :ok = Publisher.reconcile(c.publisher)
    assert %{accepted: 1, refused: 0} = status(c, 1)
    assert {:ok, ^first} = Authority.accept_external_report(c.authority, uncertain)

    assert :sys.get_state(c.reports).entries[uncertain["report_id"]].summary["report_sha256"] ==
             before.summary["report_sha256"]
  end

  test "four raw callback credits refuse a fifth queued delivery", c do
    c = start(c) |> attach()
    :ok = :sys.suspend(c.publisher)
    send(c.broker, {:send, :binary.copy(F.publish(~s({"value":250})), 5)})
    assert_receive {:mqtt_sent, _, :ok}

    wait(fn ->
      {:messages, msgs} = Process.info(c.publisher, :messages)
      Enum.any?(msgs, &match?({:mqtt_fault, _, _}, &1))
    end)

    monitor = Process.monitor(c.publisher)
    :ok = :sys.resume(c.publisher)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}, 1_000
  end

  test "unsigned receipt ordinal reaches maximum once and retires before wrap", c do
    c = start(c) |> attach()
    send_frame(c, ~s({"value":250}))
    status(c, 1)
    client = :sys.get_state(c.publisher).connection.client
    handler = Keyword.fetch!(:emqtt.info(client), :msg_handler)
    {:env, env} = :erlang.fun_info(handler.publish, :env)

    ordinal =
      Enum.find(env, fn item ->
        try do
          :atomics.get(item, 1) == 1
        rescue
          _ -> false
        end
      end)

    :ok = :atomics.put(ordinal, 1, 18_446_744_073_709_551_614)
    send_frame(c, ~s({"value":250}))
    status(c, 2)

    assert Enum.any?(:sys.get_state(c.reports).entries, fn {_, e} ->
             e.report["sequence"] == "18446744073709551615"
           end)

    monitor = Process.monitor(c.publisher)
    send_frame(c, ~s({"value":250}))
    assert_receive {:DOWN, ^monitor, :process, _, :normal}, 1_000
  end

  test "idle native configuration is closed, current and network-free", c do
    {config, _} = F.configuration(18_883)
    pub = start_supervised!({Publisher, config})
    assert {:ok, %{phase: :idle, received: 0}} = Publisher.status(pub)
    assert {:ok, selection} = Publisher.source(pub)
    assert selection.inputs["source"]["trust"] == "unauthenticated_local"
    assert Publisher.child_spec(config).restart == :temporary
    assert {:error, :mqtt_not_uncertain} = Publisher.reconcile(pub)

    assert {:error, :invalid_mqtt_publisher} =
             Publisher.start_link(Map.put(config, :extra, c.root))

    for changes <- [
          %{address: {8, 8, 8, 8}},
          %{address: "localhost"},
          %{local_address: {192, 168, 211, 253}},
          %{port: 0},
          %{credentials: :none},
          %{tls: %{server_name: "bad..name", cacerts: []}}
        ] do
      assert {:error, :invalid_mqtt_connection} =
               Publisher.start_link(%{config | connection: Map.merge(config.connection, changes)})
    end

    assert {:error, :mqtt_publisher_unavailable} = Publisher.status(:nonexistent_mqtt_publisher)
    refute Code.ensure_loaded?(:quicer)
  end

  test "actual broker deliveries retain independent sequence/continuity/quality traces and clock",
       c do
    c = start(c) |> attach()

    assert {:error, :mqtt_already_attached} =
             Publisher.attach(c.publisher, c.authority, c.sources, c.reports)

    traces = JSON.decode!(File.read!("test/fixtures/mqtt/receipt-traces.json"))["cases"]

    for {trace, n} <- Enum.with_index(traces, 1) do
      payload =
        case trace["name"] do
          "missing" -> "{}"
          "malformed" -> "{"
          _ -> ~s({"value":250})
        end

      flags = if(trace["retain"], do: 1, else: 0) + if(trace["dup"], do: 8, else: 0)
      :ok = :sys.suspend(c.publisher)
      before = System.monotonic_time(:microsecond)
      send_frame(c, payload, flags)

      wait(fn ->
        {:messages, messages} = Process.info(c.publisher, :messages)
        Enum.any?(messages, &match?({:mqtt_frame, _, _, ^n, _, _}, &1))
      end)

      processing = System.monotonic_time(:microsecond)
      :ok = :sys.resume(c.publisher)
      status(c, n)
      entries = :sys.get_state(c.reports).entries

      report =
        entries
        |> Map.values()
        |> Enum.find(&(&1.report["sequence"] == trace["ordinal"]))
        |> Map.fetch!(:report)

      assert report["continuity"] == trace["continuity"]
      assert report["quality"] == trace["quality"]
      assert report["quality_reason"] == trace["reason"]
      assert report["source_time"] == nil
      received = String.to_integer(report["receipt_time"]["monotonic_us"])
      assert received >= before and received <= processing
      assert report["profile_sha256"] == c.config.projection.data["profile_sha256"]
    end

    assert %{accepted: 0, refused: 6} = status(c, 6)
    assert {:ok, %{dispatch_enabled: false}} = Store.health(c.store)
    monitor = Process.monitor(c.publisher)
    send(c.broker, :close)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}, 1_000
    wait(fn -> not Process.alive?(c.sources) and not Process.alive?(c.reports) end)
  end

  test "unexpected topic closes the actual client", c do
    c = start(c) |> attach()
    monitor = Process.monitor(c.publisher)
    send(c.broker, {:send, F.publish("{}", 0, "unsubscribed/topic")})
    assert_receive {:DOWN, ^monitor, :process, _, :normal}, 1_000
  end

  test "source owner loss retires publisher and report custody without reconnect", c do
    c = start(c) |> attach()
    monitor = Process.monitor(c.publisher)
    GenServer.stop(c.sources)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}, 1_000
    wait(fn -> not Process.alive?(c.reports) end)
    send(c.broker, :probe)
    assert_receive {:mqtt_probe, _, {:error, :closed}}, 1_000
  end

  test "raw transport cannot send credentials",
       c do
    c = start(c, connection: %{credentials: fn -> {:password, "canary-user", "canary-pass"} end})

    assert {:error, :mqtt_connection_unavailable} =
             Publisher.attach(c.publisher, c.authority, c.sources, c.reports)

    refute_receive {:mqtt_connect, _, _}
  end

  test "oversized application payload closes the actual client", c do
    c = start(c) |> attach()
    monitor = Process.monitor(c.publisher)
    send(c.broker, {:send, F.publish(:binary.copy("x", 65_537))})
    assert_receive {:DOWN, ^monitor, :process, _, :normal}, 1_000
  end

  test "provider stalls are killed by an independent setup watchdog", c do
    c =
      start(c,
        connection: %{
          credentials: fn ->
            receive do
              :never -> :none
            end
          end
        }
      )

    before = System.monotonic_time(:millisecond)

    assert {:error, :mqtt_publisher_unavailable} =
             Publisher.attach(c.publisher, c.authority, c.sources, c.reports)

    assert (System.monotonic_time(:millisecond) - before) in 4_900..5_900
    refute Process.alive?(c.publisher)
    refute_receive {:mqtt_connect, _, _}
  end

  test "real verified TLS sends credentials only to the accepted broker", c do
    tls =
      WotexHome.TestSupport.ControllerTLSFixture.create(Path.join(c.root, "tls"), "mqtt.example")

    c =
      start(c,
        tls: [
          certfile: String.to_charlist(tls.certificates["valid"]),
          keyfile: String.to_charlist(tls.key)
        ],
        connection: %{
          tls: %{server_name: "mqtt.example", cacerts: [tls.ca]},
          credentials: fn -> {:password, "mqtt-test-user", "MQTT-SECRET-PASSWORD"} end
        }
      )

    assert :ok = Publisher.attach(c.publisher, c.authority, c.sources, c.reports)
    assert_receive {:mqtt_connect, _, connect}
    assert connect =~ "mqtt-test-user" and connect =~ "MQTT-SECRET-PASSWORD"
    send_frame(c, ~s({"value":250}))
    assert %{received: 1, refused: 1} = status(c, 1)
    assert {:ok, status} = Publisher.status(c.publisher)
    refute inspect(status) =~ "mqtt-test-user"
    refute inspect(:sys.get_status(c.publisher)) =~ "MQTT-SECRET-PASSWORD"
  end

  for variant <- ["wrong_name", "unknown_ca", "expired"] do
    @variant variant
    test "TLS #{@variant} refuses before MQTT CONNECT or credentials", c do
      tls =
        WotexHome.TestSupport.ControllerTLSFixture.create(
          Path.join(c.root, "tls"),
          "mqtt.example"
        )

      c =
        start(c,
          tls: [
            certfile: String.to_charlist(tls.certificates[@variant]),
            keyfile: String.to_charlist(tls.key)
          ],
          connection: %{
            tls: %{server_name: "mqtt.example", cacerts: [tls.ca]},
            credentials: fn -> {:password, "mqtt-test-user", "MQTT-SECRET-PASSWORD"} end
          }
        )

      assert {:error, :mqtt_connection_unavailable} =
               Publisher.attach(c.publisher, c.authority, c.sources, c.reports)

      refute_receive {:mqtt_connect, _, _}
    end
  end

  test "verified TLS 1.2 operates with session reuse disabled", c do
    tls =
      WotexHome.TestSupport.ControllerTLSFixture.create(Path.join(c.root, "tls"), "mqtt.example")

    c =
      start(c,
        tls: [
          certfile: String.to_charlist(tls.certificates["valid"]),
          keyfile: String.to_charlist(tls.key),
          versions: [:"tlsv1.2"]
        ],
        connection: %{
          tls: %{server_name: "mqtt.example", cacerts: [tls.ca]},
          credentials: fn -> :none end
        }
      )
      |> attach()

    send_frame(c, ~s({"value":250}))
    assert %{received: 1, refused: 1} = status(c, 1)
  end

  test "actual client diagnostics and crash reports redact secrets while unrelated logging remains",
       c do
    c = start(c) |> attach()
    previous = :logger.get_primary_config().level
    :logger.set_primary_config(:level, :debug)
    on_exit(fn -> :logger.set_primary_config(:level, previous) end)
    client = :sys.get_state(c.publisher).connection.client

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send_frame(c, ~s({"value":"MQTT-PAYLOAD-CANARY"}))
        status(c, 1)
        :logger.warning("unrelated-mqtt-test-marker")
        :sys.terminate(client, {:private_canary, "MQTT-CRASH-CANARY"})
        wait(fn -> not Process.alive?(c.publisher) end)
      end)

    refute log =~ "MQTT-PAYLOAD-CANARY"
    refute log =~ "MQTT-CRASH-CANARY"
    assert log =~ "unrelated-mqtt-test-marker"
  end

  for owner <- [:reports, :store] do
    @lost_owner owner
    test "#{owner} owner loss is terminal", c do
      c = start(c) |> attach()
      monitor = Process.monitor(c.publisher)
      GenServer.stop(Map.fetch!(c, @lost_owner))
      assert_receive {:DOWN, ^monitor, :process, _, :normal}, 1_000
      send(c.broker, :probe)
      assert_receive {:mqtt_probe, _, {:error, :closed}}, 1_000
    end
  end

  test "independent admission watchdog retains originals without renewing expired freshness", c do
    c = start(c) |> attach() |> F.select_target()
    :ok = :sys.suspend(c.store)
    send_frame(c, ~s({"value":250}))
    wait(fn -> :sys.get_state(c.publisher).active != nil end)

    wait(
      fn ->
        case Publisher.status(c.publisher) do
          {:ok, %{phase: :uncertain, uncertain: [_]}} -> true
          _ -> false
        end
      end,
      600
    )

    :ok = :sys.resume(c.store)
    assert :ok = Publisher.reconcile(c.publisher)
    assert %{accepted: 0, refused: 1} = status(c, 1)
  end

  test "conflicting privacy filter refuses startup without replacing another filter", c do
    id = :wotex_home_private_emqtt
    previous = List.keyfind(:logger.get_primary_config().filters, id, 0)
    :logger.remove_primary_filter(id)
    conflict = {fn _, _ -> :ignore end, :other_owner}
    :ok = :logger.add_primary_filter(id, conflict)

    on_exit(fn ->
      :logger.remove_primary_filter(id)
      if previous, do: :logger.add_primary_filter(id, elem(previous, 1))
    end)

    c = start(c)

    assert {:error, :mqtt_logging_unavailable} =
             Publisher.attach(c.publisher, c.authority, c.sources, c.reports)

    assert {^id, ^conflict} = List.keyfind(:logger.get_primary_config().filters, id, 0)
    refute_receive {:mqtt_connect, _, _}
  end

  test "retained MQTT source history keeps exact bytes while other containers retain depth eight",
       c do
    c = start(c)
    {:ok, source} = Publisher.source(c.publisher)
    {:ok, bytes} = WotexHome.Profiles.RetainedSource.encode(source, String.duplicate("b", 32))
    {:ok, retained} = WotexHome.Profiles.RetainedSource.decode(bytes)
    assert retained.sha256 == source.sha256
    assert retained.reader_basis_sha256 == source.data["reader_basis_sha256"]
    too_deep = Enum.reduce(1..9, nil, fn _, v -> [v] end) |> JSON.encode!()
    assert {:error, :external_profile_limit} = WotexHome.Profiles.RetainedJSON.decode(too_deep)
    assert {:ok, _} = WotexHome.Profiles.RetainedJSON.decode(too_deep, 9)
    even_deeper = Enum.reduce(1..10, nil, fn _, v -> [v] end) |> JSON.encode!()

    assert {:error, :external_profile_limit} =
             WotexHome.Profiles.RetainedJSON.decode(even_deeper, 9)
  end

  test "QoS zero SUBACK grant is accepted without weakening source trust", c do
    c = start(c, grant: 0) |> attach()
    send_frame(c, ~s({"value":250}))
    assert %{received: 1, refused: 1} = status(c, 1)
    assert {:ok, selection} = Publisher.source(c.publisher)
    assert selection.data["trust"] == "unauthenticated_local"
  end

  for options <- [[grant: 0x80], [grant: 2], [session: 1]] do
    @refused_options options
    test "broker #{inspect(options)} refuses the connection", c do
      c = start(c, @refused_options)

      assert {:error, :mqtt_connection_unavailable} =
               Publisher.attach(c.publisher, c.authority, c.sources, c.reports)

      refute Process.alive?(c.publisher)
    end
  end

  test "four frame batches include active work and a fifth retires without eviction", c do
    c = start(c) |> attach()
    :ok = :sys.suspend(c.store)

    try do
      for n <- 1..4 do
        send_frame(c, ~s({"value":250}))

        wait(fn ->
          case Publisher.status(c.publisher) do
            {:ok, %{received: ^n, pending_frames: ^n}} -> true
            _ -> false
          end
        end)
      end

      monitor = Process.monitor(c.publisher)
      send_frame(c, ~s({"value":250}))
      assert_receive {:DOWN, ^monitor, :process, _, :normal}, 1_000
    after
      :sys.resume(c.store)
    end
  end

  test "a generic decoded value cannot widen the enclosing report byte limit", c do
    c = start(c) |> attach()
    payload = JSON.encode!(%{"value" => List.duplicate(String.duplicate("v", 4050), 16)})
    {:ok, delivery} = Wotex.Binding.MQTT.Delivery.new(payload, topic: "test/temperature")

    assert {:ok, _, _} =
             Wotex.Binding.MQTT.JSONProjection.project(delivery, %{
               "topic" => "test/temperature",
               "path" => ["value"]
             })

    monitor = Process.monitor(c.publisher)
    send_frame(c, payload)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}, 1_000
  end

  test "parser packet ceiling refuses an oversized wire frame", c do
    c = start(c) |> attach()
    monitor = Process.monitor(c.publisher)
    send(c.broker, {:send, F.publish(:binary.copy("x", 70_001))})
    assert_receive {:DOWN, ^monitor, :process, _, :normal}, 1_000
  end
end
