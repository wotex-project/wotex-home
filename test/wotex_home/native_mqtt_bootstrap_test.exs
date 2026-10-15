defmodule WotexHome.NativeMQTTBootstrapTest do
  @moduledoc false

  use ExUnit.Case, async: true
  alias WotexHome.MQTT.NativeCredential
  alias WotexHome.NativeSetup.MQTTBootstrap
  alias WotexHome.Recovery.PrivateFile
  @vectors JSON.decode!(File.read!("test/fixtures/mqtt/native-bootstrap.json"))
  @sha String.duplicate("a", 64)

  setup do
    root =
      Path.join(
        if(:os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()),
        "home-native-mqtt-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    path = Path.join(root, "source")
    File.write!(path, "source-witness")
    File.chmod!(path, 0o400)
    {:ok, _, seal} = PrivateFile.read_sealed(path, 1024)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, seal: seal}
  end

  test "frozen canonical bootstrap vectors are distinct from ordinary setup framing" do
    assert MQTTBootstrap.request(nil) == @vectors["none"]
    assert MQTTBootstrap.request(%{sha256: @sha}) == @vectors["request"]
    assert {:ok, nil} = MQTTBootstrap.reply(@vectors["none"], nil)

    assert {:ok, {:password, "fixture-user", "fixture-password"}} =
             MQTTBootstrap.reply(@vectors["reply"], %{sha256: @sha})

    assert @vectors["ordinary_frame_limit"] == 4096
    assert @vectors["reply_limit"] == 8192

    assert {:error, :invalid_native_setup_record} =
             WotexHome.NativeSetup.Codec.decode("identity", String.duplicate("x", 4097))
  end

  test "alternate representations, changed digests and malformed secrets refuse" do
    reply = @vectors["reply"]

    for bytes <- [
          reply <> "\n",
          " " <> reply,
          String.replace(reply, ",", ", "),
          String.replace(reply, @sha, String.duplicate("b", 64)),
          String.replace(reply, "fixture-user", ""),
          String.replace(reply, "Zml4dHVyZS1wYXNzd29yZA==", "YQ"),
          String.replace(reply, "\"fixture-user\"", "true"),
          String.replace(reply, "\"fixture-user\"", "[]"),
          String.replace(reply, "\"fixture-user\"", "{\"a\":1}"),
          String.replace(reply, "\"fixture-user\"", "1.0"),
          String.replace(reply, "fixture-user", "fixture\\u002duser"),
          String.duplicate("[", 8192),
          String.duplicate("x", 8193),
          @vectors["none"]
        ] do
      assert {:error, :invalid_native_mqtt_bootstrap} =
               MQTTBootstrap.reply(bytes, %{sha256: @sha})
    end

    assert {:error, :invalid_native_mqtt_bootstrap} = MQTTBootstrap.reply(reply, nil)
  end

  test "maximum binary password and UTF-8 username fit only the startup reply" do
    user = String.duplicate("å", 64)
    password = :binary.copy(<<255>>, 4096)

    bytes =
      JSON.encode!([
        "wotex-home.native-mqtt-bootstrap@1",
        "credential",
        @sha,
        user,
        Base.encode64(password)
      ])

    assert byte_size(bytes) > 4096 and byte_size(bytes) <= 8192
    assert {:ok, {:password, ^user, ^password}} = MQTTBootstrap.reply(bytes, %{sha256: @sha})
    oversized = String.replace(bytes, user, user <> "x")

    assert {:error, :invalid_native_mqtt_bootstrap} =
             MQTTBootstrap.reply(oversized, %{sha256: @sha})
  end

  test "capability checks preserve custody and resolution consumes exactly once", c do
    assert {:ok, cap} =
             NativeCredential.start_link(
               @sha,
               c.seal,
               {:password, "canary-user", "canary-password"}
             )

    on_exit(fn -> NativeCredential.stop(cap) end)
    assert NativeCredential.matches?(cap, @sha, c.seal)
    assert :ok = NativeCredential.check(cap)
    assert :ok = NativeCredential.check(cap)

    for forged <- [
          %{cap | token: make_ref()},
          %{cap | sha256: String.duplicate("b", 64)},
          %{cap | seal: %{c.seal | path: c.seal.path <> ".changed"}}
        ] do
      assert {:error, :mqtt_native_credential_unavailable} = NativeCredential.check(forged)
      assert {:error, :mqtt_native_credential_unavailable} = NativeCredential.resolve(forged)
    end

    refute inspect(cap) =~ "canary"
    refute inspect(:sys.get_status(cap.owner)) =~ "canary"
    assert {:password, "canary-user", "canary-password"} = NativeCredential.resolve(cap)
    assert {:error, :mqtt_native_credential_unavailable} = NativeCredential.resolve(cap)
    assert {:error, :mqtt_native_credential_unavailable} = NativeCredential.check(cap)
  end

  test "deadline and original parent loss retire custody", c do
    assert {:ok, cap} = NativeCredential.start_link(@sha, c.seal, {:password, "user", "password"})
    :sys.replace_state(cap.owner, &%{&1 | deadline: System.monotonic_time(:millisecond) - 1})
    assert {:error, :mqtt_native_credential_unavailable} = NativeCredential.resolve(cap)
    monitor = Process.monitor(cap.owner)
    send(cap.owner, :expire)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}
    parent = self()

    pid =
      spawn(fn ->
        {:ok, owned} = NativeCredential.start_link(@sha, c.seal, {:password, "user", "password"})
        send(parent, {:owned, owned})

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:owned, owned}
    monitor = Process.monitor(owned.owner)
    send(pid, :finish)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}
    assert {:error, :mqtt_native_credential_unavailable} = NativeCredential.resolve(owned)
  end

  test "invalid credentials cannot enter a private owner", c do
    for pair <- [
          {:password, "", "password"},
          {:password, <<0>>, "p"},
          {:password, "user", ""},
          {:password, "u", String.duplicate("p", 4097)},
          :none
        ] do
      assert {:error, :mqtt_native_credential_unavailable} =
               NativeCredential.start_link(@sha, c.seal, pair)
    end
  end

  test "absent policy exchanges none without creating a credential or Store", c do
    body = @vectors["none"]
    {:ok, device} = StringIO.open(<<byte_size(body)::32, body::binary>>)
    assert {:ok, nil} = MQTTBootstrap.run(c.root, device)
    assert {_, <<size::32, response::binary-size(size)>>} = StringIO.contents(device)
    assert response == body
    refute File.exists?(Path.join(c.root, "home.sqlite"))
    StringIO.close(device)
  end

  @tag timeout: 8_000
  test "a blocked request write shares the original five-second exchange bound", c do
    parent = self()

    device =
      spawn(fn ->
        receive do
          {:io_request, _, _, _} ->
            send(parent, :write_blocked)

            receive do
              :close -> :ok
            end
        end
      end)

    on_exit(fn -> Process.exit(device, :kill) end)
    started = System.monotonic_time(:millisecond)
    pending = Task.async(fn -> MQTTBootstrap.run(c.root, device) end)
    assert_receive :write_blocked
    assert {:error, :invalid_native_mqtt_bootstrap} = Task.await(pending, 6_500)
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 5_000 and elapsed < 6_500
    refute File.exists?(Path.join(c.root, "home.sqlite"))
  end
end
