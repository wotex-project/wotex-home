Code.require_file("../support/mqtt_fixture.exs", __DIR__)
Code.require_file("../support/controller_tls_fixture.exs", __DIR__)

defmodule WotexHome.PrivateMQTTInstallationTest do
  @moduledoc false

  use ExUnit.Case, async: false
  import Bitwise
  alias WotexHome.{Host, Authority}
  alias WotexHome.Durable.Store
  alias WotexHome.Host.{ProfileConfiguration, MQTTConfiguration, MQTTInstallation}
  alias WotexHome.MQTT.{Credential, Publisher}
  alias WotexHome.Profiles.ExternalSourceOwner
  alias WotexHome.TestSupport.MQTTFixture, as: F
  @moduletag :requires_socket

  setup do
    root =
      Path.join(
        if(:os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()),
        "home-installed-mqtt-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp write(root, name, bytes) do
    path = Path.join(root, name)
    File.write!(path, bytes)
    File.chmod!(path, 0o400)
    path
  end

  defp prepare(c, broker_options \\ []) do
    {broker, port} = F.broker(self(), broker_options)
    on_exit(fn -> Process.exit(broker, :kill) end)
    {native, fixture} = F.configuration(port)

    profile = %{
      mode: :authoring,
      installed: Map.delete(native.reader.inputs["installed"], "producer"),
      authoring_limits: F.fixture("authoring-mechanics")["temperature"]["limits"]
    }

    document = %{
      "format" => "wotex-home.mqtt-source@1",
      "profile" => fixture["profile"],
      "definitions" => fixture["definitions"],
      "capture" => fixture["capture"],
      "source" => native.source,
      "channels" => native.channels,
      "connection" => %{
        "address" => [127, 0, 0, 1],
        "local_address" => [127, 0, 0, 1],
        "port" => port,
        "tls" => nil,
        "authentication" => "none"
      }
    }

    Map.merge(c, %{
      broker: broker,
      native: native,
      fixture: fixture,
      profile: profile,
      document: document
    })
  end

  defp install(c) do
    authoring = %{
      "format" => "wotex-home.profile-authoring-installation@1",
      "installed" => c.profile.installed,
      "authoring_limits" => c.profile.authoring_limits
    }

    source = write(c.root, "authoring-input.json", JSON.encode!(authoring))
    assert {:ok, _} = ProfileConfiguration.publish(c.root, source)
    source = write(c.root, "mqtt-input.json", JSON.encode!(c.document))
    assert {:ok, _} = MQTTConfiguration.publish(c.root, source)
    c
  end

  defp start_host(c, options \\ []) do
    assert {:ok, host} = Host.start_link([data_dir: c.root] ++ options)
    Process.unlink(host)
    on_exit(fn -> if Process.alive?(host), do: Supervisor.stop(host) end)

    %{
      host: host,
      store: Host.store(),
      sources: Host.external_sources(),
      reports: Host.external_reports()
    }
  end

  defp wait(fun, n \\ 150)
  defp wait(_, 0), do: flunk("installed MQTT transition did not complete")

  defp wait(fun, n) do
    case fun.() do
      false ->
        Process.sleep(10)
        wait(fun, n - 1)

      result ->
        result
    end
  end

  test "closed source document reconstructs the exact current reader/projection without a connection",
       c do
    c = prepare(c)
    assert {:ok, prepared} = MQTTConfiguration.decode(JSON.encode!(c.document), c.profile)
    assert prepared.profile.reader == c.native.reader
    assert prepared.publisher.projection == c.native.projection
    refute Map.has_key?(prepared.publisher.connection, :credentials)
    refute_receive {:mqtt_connect, _, _}

    for changed <- [
          Map.put(c.document, "extra", true),
          Map.delete(c.document, "capture"),
          put_in(c.document, ["connection", "address"], "localhost"),
          put_in(c.document, ["connection", "address"], [8, 8, 8, 8]),
          put_in(c.document, ["connection", "port"], true),
          put_in(c.document, ["connection", "authentication"], "password"),
          put_in(c.document, ["source", "trust"], "authenticated_device")
        ] do
      assert {:error, :invalid_mqtt_configuration} =
               MQTTConfiguration.decode(JSON.encode!(changed), c.profile)
    end

    assert {:error, :invalid_mqtt_configuration} =
             MQTTConfiguration.decode(~s({"format":1,"format":2}), c.profile)

    assert {:error, :invalid_mqtt_configuration} =
             MQTTConfiguration.decode(String.duplicate("x", 524_289), c.profile)
  end

  test "credential publication and resolution are sealed, exact, redacted and bounded", c do
    data = %{
      "format" => "wotex-home.mqtt-credential@1",
      "username" => "private-user-canary",
      "password_base64" => Base.encode64("private-password-canary")
    }

    source = write(c.root, "credential-input.json", JSON.encode!(data))
    assert {:ok, %{installed: true}} = Credential.publish(c.root, source)
    assert {:ok, %{installed: true}} = Credential.publish(c.root, source)
    assert {:ok, reference} = Credential.load(c.root)

    assert {:password, "private-user-canary", "private-password-canary"} =
             Credential.resolve(reference)

    refute inspect(reference) =~ "private-"

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.Woh.Mqtt.Credential.Install.run([c.root, source])
      end)

    assert String.trim(output) == ~s({"installed":true})
    refute output =~ reference.sha256

    changed =
      write(c.root, "changed-credential.json", JSON.encode!(Map.put(data, "username", "other")))

    assert {:error, :mqtt_credential_exists} = Credential.publish(c.root, changed)
    target = Path.join(c.root, Credential.filename())
    File.chmod!(target, 0o600)
    File.write!(target, JSON.encode!(Map.put(data, "username", "other")))
    File.chmod!(target, 0o400)
    assert {:error, :mqtt_credential_changed} = Credential.resolve(reference)

    for bad <- [
          Map.put(data, "extra", true),
          Map.put(data, "username", <<0>>),
          Map.put(data, "password_base64", "YQ"),
          Map.put(data, "password_base64", Base.encode64(String.duplicate("p", 4097)))
        ] do
      assert {:error, :invalid_mqtt_credential} = Credential.decode(JSON.encode!(bad))
    end
  end

  test "private publication preserves exact bytes and snapshot identity across retries/conflicts",
       c do
    c = prepare(c) |> install()
    source = Path.join(c.root, "mqtt-input.json")
    assert {:ok, summary} = MQTTConfiguration.publish(c.root, source)
    assert summary.channels == 1
    target = Path.join(c.root, MQTTConfiguration.filename())
    assert File.read!(target) == File.read!(source)
    assert band(File.stat!(target).mode, 0o777) == 0o400
    assert {:ok, snapshot} = MQTTConfiguration.load(c.root, c.profile)
    assert :ok = MQTTConfiguration.check(snapshot, c.root, c.profile)
    forged = put_in(snapshot.prepared.publisher.connection.port, 1)

    assert {:error, :mqtt_configuration_changed} =
             MQTTConfiguration.check(forged, c.root, c.profile)

    refute inspect(snapshot) =~ "source:independent"
    refute inspect(snapshot) =~ "test/temperature"
    changed = put_in(c.document, ["source", "source_generation"], 2)
    other = write(c.root, "changed-input.json", JSON.encode!(changed))
    assert {:error, :mqtt_configuration_exists} = MQTTConfiguration.publish(c.root, other)
    File.chmod!(target, 0o600)
    File.write!(target, JSON.encode!(changed))
    File.chmod!(target, 0o400)

    assert {:error, :mqtt_configuration_changed} =
             MQTTConfiguration.check(snapshot, c.root, c.profile)
  end

  test "ordinary Host creates one connection and live custody with no implicit target", c do
    c = prepare(c) |> install()
    h = start_host(c)
    assert_receive {:mqtt_connect, broker, _}
    assert broker == c.broker
    assert_receive {:mqtt_subscribe, ^broker, _}
    assert is_pid(h.sources) and is_pid(h.reports)
    assert {:ok, %{"sources" => [source]}} = ExternalSourceOwner.catalogue(h.sources)
    assert source["source_ref"] == c.native.source["source_ref"]
    assert {:ok, %{dispatch_enabled: false}} = Store.health(h.store)
    send(c.broker, {:send, F.publish(~s({"value":250}))})
    assert_receive {:mqtt_sent, ^broker, :ok}
    composition = :sys.get_state(MQTTInstallation)

    wait(fn ->
      case Publisher.status(composition.publisher) do
        {:ok, %{received: 1, refused: 1, pending_frames: 0}} -> true
        _ -> false
      end
    end)

    assert Authority.owner(Host.authority()) == h.store
    monitor = Process.monitor(composition.publisher)
    GenServer.stop(h.sources)
    assert_receive {:DOWN, ^monitor, :process, _, reason}, 1_000
    assert reason in [:normal, :killed]
    wait(fn -> Process.whereis(MQTTInstallation) == nil end)
    send(c.broker, :probe)
    assert_receive {:mqtt_probe, ^broker, {:error, :closed}}
  end

  test "Store restart never recreates the temporary publisher or reconnects", c do
    c = prepare(c) |> install()
    h = start_host(c)
    assert_receive {:mqtt_connect, _, _}
    before = :sys.get_state(MQTTInstallation)
    assert :ok = GenServer.stop(h.store)
    wait(fn -> is_pid(Host.store()) and Host.store() != h.store end)
    assert Process.alive?(h.host)
    assert Process.whereis(MQTTInstallation) == nil
    refute Process.alive?(before.publisher)
    assert Host.external_sources() == nil
    assert Host.external_reports() == nil
    assert {:ok, %{dispatch_enabled: false}} = Store.health(Host.store())
    refute_receive {:mqtt_connect, _, _}
  end

  test "bad present source refuses before Store/socket while explicit native nil skips it", c do
    c = prepare(c)
    write(c.root, MQTTConfiguration.filename(), "{")
    assert {:error, :mqtt_profile_configuration_required} = Host.start_link(data_dir: c.root)

    authoring = %{
      "format" => "wotex-home.profile-authoring-installation@1",
      "installed" => c.profile.installed,
      "authoring_limits" => c.profile.authoring_limits
    }

    write(c.root, ProfileConfiguration.filename(), JSON.encode!(authoring))
    assert {:error, :invalid_mqtt_configuration} = Host.start_link(data_dir: c.root)
    refute File.exists?(Path.join(c.root, "home.sqlite"))
    refute File.exists?(Path.join(c.root, "ipc"))
    h = start_host(c, profile_installation: nil)
    assert Host.external_sources() == nil
    assert Process.alive?(h.host)
    refute_receive {:mqtt_connect, _, _}
  end

  test "witnessed absence and publication sync failure cannot activate changed files", c do
    c = prepare(c)
    assert {:ok, absent} = MQTTConfiguration.load(c.root, c.profile)
    assert :ok = MQTTConfiguration.check(absent, c.root, c.profile)
    write(c.root, MQTTConfiguration.filename(), JSON.encode!(c.document))

    assert {:error, :mqtt_configuration_changed} =
             MQTTConfiguration.check(absent, c.root, c.profile)

    File.rm!(Path.join(c.root, MQTTConfiguration.filename()))

    source =
      write(
        c.root,
        "credential-input.json",
        JSON.encode!(%{
          "format" => "wotex-home.mqtt-credential@1",
          "username" => "user",
          "password_base64" => "cA=="
        })
      )

    assert {:error, :mqtt_credential_unavailable} =
             Credential.publish(c.root, source, fn _ -> {:error, :eio} end)

    refute File.exists?(Path.join(c.root, Credential.filename()))
    refute File.exists?(Path.join(c.root, "home.sqlite"))
  end

  test "file-provisioned Host admits exact reports only after actual reviewed Store selection",
       c do
    c = prepare(c) |> install()
    h = start_host(c)
    assert_receive {:mqtt_connect, broker, _}
    owned = :sys.get_state(MQTTInstallation)

    selected =
      F.select_target(%{
        store: h.store,
        sources: h.sources,
        publisher: owned.publisher,
        authority: Host.authority(),
        v: c.fixture,
        config: c.native
      })

    send(broker, {:send, F.publish(~s({"value":250}))})
    assert_receive {:mqtt_sent, ^broker, :ok}

    wait(fn ->
      case Publisher.status(owned.publisher) do
        {:ok, %{accepted: 1, pending_frames: 0}} -> true
        _ -> false
      end
    end)

    assert {:ok, preview} =
             Authority.external_report_current(
               Host.authority(),
               selected.reader_credential,
               "sensor:external",
               "sample"
             )

    assert preview["freshness"] == "fresh"
    assert preview["value"]["normalized_value"] == %{"type" => "sint", "value" => "25000"}
  end

  test "password files are independently sealed and the actual TLS broker receives credentials",
       c do
    tls =
      WotexHome.TestSupport.ControllerTLSFixture.create(Path.join(c.root, "tls"), "mqtt.example")

    c =
      prepare(c,
        tls: [
          certfile: String.to_charlist(tls.certificates["valid"]),
          keyfile: String.to_charlist(tls.key)
        ]
      )

    document =
      c.document
      |> put_in(["connection", "authentication"], "password")
      |> put_in(["connection", "tls"], %{
        "server_name" => "mqtt.example",
        "cacerts" => [Base.encode64(tls.ca)]
      })

    cred = %{
      "format" => "wotex-home.mqtt-credential@1",
      "username" => "installed-user-canary",
      "password_base64" => Base.encode64("installed-password-canary")
    }

    source = write(c.root, "credential-input.json", JSON.encode!(cred))

    write(
      c.root,
      ProfileConfiguration.filename(),
      JSON.encode!(%{
        "format" => "wotex-home.profile-authoring-installation@1",
        "installed" => c.profile.installed,
        "authoring_limits" => c.profile.authoring_limits
      })
    )

    write(c.root, MQTTConfiguration.filename(), JSON.encode!(document))
    assert {:error, :mqtt_credential_unavailable} = Host.start_link(data_dir: c.root)
    refute File.exists?(Path.join(c.root, "home.sqlite"))
    assert {:ok, _} = Credential.publish(c.root, source)
    c = install(%{c | document: document})
    assert {:ok, snapshot} = MQTTConfiguration.load(c.root, c.profile)
    assert :ok = MQTTConfiguration.check(snapshot, c.root, c.profile)
    h = start_host(c)
    assert_receive {:mqtt_connect, _, connect}
    assert connect =~ "installed-user-canary" and connect =~ "installed-password-canary"
    refute inspect(:sys.get_status(MQTTInstallation)) =~ "installed-password-canary"
    target = Path.join(c.root, Credential.filename())
    File.chmod!(target, 0o600)
    File.write!(target, JSON.encode!(Map.put(cred, "username", "changed-user-canary")))
    File.chmod!(target, 0o400)

    assert {:error, :mqtt_credential_changed} =
             MQTTConfiguration.check(snapshot, c.root, c.profile)

    assert {:error, :mqtt_credential_changed} =
             snapshot.prepared.publisher.connection.credentials.()

    assert Process.alive?(h.host)
  end

  test "unsafe credential custody fails before Store resources", c do
    c = prepare(c)

    data = %{
      "format" => "wotex-home.mqtt-credential@1",
      "username" => "user",
      "password_base64" => "cA=="
    }

    path = write(c.root, Credential.filename(), JSON.encode!(data))
    File.chmod!(path, 0o600)
    assert {:error, :mqtt_credential_unavailable} = Credential.load(c.root)
    File.chmod!(path, 0o400)
    :ok = File.ln(path, Path.join(c.root, "second-link"))
    assert {:error, :mqtt_credential_unavailable} = Credential.load(c.root)
    File.rm!(Path.join(c.root, "second-link"))
    File.rename!(path, path <> ".real")
    File.ln_s!(path <> ".real", path)
    assert {:error, :mqtt_credential_unavailable} = Credential.load(c.root)
    refute File.exists?(Path.join(c.root, "home.sqlite"))
  end

  test "partial broker setup failure retires all children and redacts the startup report", c do
    c = prepare(c, grant: 0x80) |> install()
    old_trap = Process.flag(:trap_exit, true)

    log =
      try do
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, _} = Host.start_link(data_dir: c.root)

          receive do
            {:EXIT, _, _} -> :ok
          after
            100 -> :ok
          end
        end)
      after
        Process.flag(:trap_exit, old_trap)
      end

    wait(fn ->
      Host.store() == nil and Host.external_sources() == nil and Host.external_reports() == nil
    end)

    assert Process.whereis(MQTTInstallation) == nil
    refute File.exists?(Path.join(c.root, "ipc/home.sock"))
    refute log =~ "fixture:private:stable"
    refute log =~ "test/temperature"
    refute log =~ "127.0.0.1"
  end

  test "new Host startup changes source epoch and never reuses the terminated publisher", c do
    c = prepare(c) |> install()
    h = start_host(c)
    assert_receive {:mqtt_connect, _, _}
    {:ok, %{"sources" => [before]}} = ExternalSourceOwner.catalogue(h.sources)
    old = :sys.get_state(MQTTInstallation).publisher

    selected =
      F.select_target(%{
        store: h.store,
        sources: h.sources,
        publisher: old,
        authority: Host.authority(),
        v: c.fixture,
        config: c.native
      })

    send(c.broker, {:send, F.publish(~s({"value":250}))})
    assert_receive {:mqtt_sent, _, :ok}

    wait(fn ->
      case Publisher.status(old) do
        {:ok, %{accepted: 1, pending_frames: 0}} -> true
        _ -> false
      end
    end)

    assert {:ok, %{"freshness" => "fresh"}} =
             Authority.external_report_current(
               Host.authority(),
               selected.reader_credential,
               "sensor:external",
               "sample"
             )

    Supervisor.stop(h.host)
    {broker, port} = F.broker(self())
    on_exit(fn -> Process.exit(broker, :kill) end)
    # Updating immutable operator policy requires an explicit stopped-host replacement.
    File.rm!(Path.join(c.root, MQTTConfiguration.filename()))
    document = put_in(c.document, ["connection", "port"], port)
    source = write(c.root, "next-mqtt-input.json", JSON.encode!(document))
    assert {:ok, _} = MQTTConfiguration.publish(c.root, source)
    new = start_host(c)
    assert_receive {:mqtt_connect, ^broker, _}
    {:ok, %{"sources" => [after_restart]}} = ExternalSourceOwner.catalogue(new.sources)
    assert before["data"]["source_epoch"] != after_restart["data"]["source_epoch"]
    refute Process.alive?(old)
    assert {:ok, %{dispatch_enabled: false}} = Store.health(new.store)

    assert {:ok, %{"freshness" => "unknown"}} =
             Authority.external_report_current(
               Host.authority(),
               selected.reader_credential,
               "sensor:external",
               "sample"
             )
  end

  test "fresh ordinary Application starts solely from the private files", c do
    c = prepare(c) |> install()
    script = Path.join(c.root, "application.exs")

    File.write!(script, ~S"""
    System.delete_env("WOTEX_HOME_LIFX_INTERFACE")
    {:ok, _} = Application.ensure_all_started(:wotex_home)
    true = is_pid(WotexHome.Host.store())
    true = is_pid(WotexHome.Host.external_sources())
    true = is_pid(WotexHome.Host.external_reports())
    true = is_pid(Process.whereis(WotexHome.Host.MQTTInstallation))
    {:ok, %{dispatch_enabled: false}} = WotexHome.Durable.Store.health(WotexHome.Host.store())
    :ok = Application.stop(:wotex_home)
    IO.puts("mqtt-configured")
    """)

    paths = Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)])

    assert {:ok, output} =
             Woh.Tool.Command.run("elixir", paths ++ [script], 16384, 15000, [
               {"WOTEX_HOME_DATA_DIR", c.root}
             ])

    assert output =~ "mqtt-configured"
    refute output =~ "test/temperature"
    refute output =~ "fixture:private:stable"
    assert_receive {:mqtt_connect, broker, _}
    assert broker == c.broker
    send(broker, :probe)
    assert_receive {:mqtt_probe, ^broker, {:error, :closed}}
  end

  test "replaced empty root and failed source synchronization preserve inactive policy", c do
    c = prepare(c)
    {:ok, absent} = MQTTConfiguration.load(c.root, c.profile)
    old = c.root <> ".original"
    File.rename!(c.root, old)

    try do
      File.mkdir!(c.root)
      File.chmod!(c.root, 0o700)

      assert {:error, :mqtt_configuration_changed} =
               MQTTConfiguration.check(absent, c.root, c.profile)
    after
      File.rm_rf!(c.root)
      File.rename!(old, c.root)
    end

    c = install(c)
    File.rm!(Path.join(c.root, MQTTConfiguration.filename()))

    assert {:error, :mqtt_configuration_unavailable} =
             MQTTConfiguration.publish(
               c.root,
               Path.join(c.root, "mqtt-input.json"),
               fn _ -> {:error, :eio} end
             )

    refute File.exists?(Path.join(c.root, MQTTConfiguration.filename()))
    refute File.exists?(Path.join(c.root, "home.sqlite"))
  end
end
