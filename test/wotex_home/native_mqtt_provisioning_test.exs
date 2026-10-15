Code.require_file("../support/mqtt_fixture.exs", __DIR__)

defmodule WotexHome.NativeMQTTProvisioningTest do
  @moduledoc false

  use ExUnit.Case, async: false
  alias WotexHome.Durable.{HostLock, Store}
  alias WotexHome.Host.{MQTTConfiguration, ProfileConfiguration}
  alias WotexHome.NativeSetup.MQTTProvisioning, as: P
  alias WotexHome.TestSupport.MQTTFixture, as: F
  @vectors JSON.decode!(File.read!("test/fixtures/mqtt/native-provision.json"))
  @keys ~w(authoring_sha256 source_sha256 basis_sha256 root_sha256)a

  setup do
    base =
      Path.join(
        if(:os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()),
        "home-mqtt-provision-#{System.unique_integer([:positive])}"
      )

    root = Path.join(base, "data")
    input = Path.join(base, "inputs")

    for path <- [base, root, input],
        do:
          (
            File.mkdir!(path)
            File.chmod!(path, 0o700)
          )

    {authoring, document} = F.installation_documents()
    a = write(input, "authoring.json", authoring)
    s = write(input, "mqtt.json", document)
    on_exit(fn -> File.rm_rf!(base) end)
    %{base: base, root: root, a: a, s: s}
  end

  defp write(root, name, bytes) do
    path = Path.join(root, name)
    File.write!(path, bytes)
    File.chmod!(path, 0o400)
    path
  end

  defp prepared(c) do
    assert {:ok, summary} = P.prepare(c.root, c.a, c.s)
    {summary, Map.take(summary, @keys)}
  end

  test "frozen foreground requests and replies have a separate closed grammar" do
    assert {:ok, {:prepare, "/private/fixture/authoring.json", "/private/fixture/mqtt.json"}} =
             P.request(@vectors["prepare"])

    assert {:ok, {:publish, _, _, expected}} = P.request(@vectors["publish"])
    summary = Map.merge(expected, %{channels: 1, authentication: "keychain"})
    assert P.response("prepared", {:ok, summary}) == @vectors["prepared"]
    assert P.response("published", {:ok, summary}) == @vectors["published"]

    assert P.response("error", {:error, :native_mqtt_publication_conflict}) ==
             @vectors["conflict"]

    for bad <- [
          @vectors["prepare"] <> "\n",
          String.replace(@vectors["prepare"], ",", ", "),
          String.replace(@vectors["prepare"], "\"prepare\"", "true"),
          String.replace(@vectors["prepare"], "\"prepare\"", "[]"),
          String.replace(@vectors["prepare"], "/private/fixture/authoring.json", "relative"),
          String.replace(@vectors["prepare"], "\"prepare\"", "\"publish\""),
          String.replace(
            @vectors["publish"],
            String.duplicate("a", 64),
            String.duplicate("A", 64)
          ),
          String.duplicate("[", 4096),
          String.duplicate("x", 4097)
        ] do
      assert {:error, :invalid_native_mqtt_provisioning} = P.request(bad)
    end
  end

  test "preparation reconstructs actual producer but creates no policy, gate or Store", c do
    {summary, _} = prepared(c)
    assert summary.channels == 1 and summary.authentication == "none"

    assert summary.authoring_sha256 ==
             Base.encode16(:crypto.hash(:sha256, File.read!(c.a)), case: :lower)

    assert summary.source_sha256 ==
             Base.encode16(:crypto.hash(:sha256, File.read!(c.s)), case: :lower)

    assert File.ls!(c.root) == []
    assert Process.whereis(WotexHome.Host.MQTTInstallation) == nil
  end

  test "publication is immutable and exact installed confirmation survives source loss", c do
    {summary, expected} = prepared(c)
    assert {:ok, ^summary} = P.publish(c.root, c.a, c.s, expected)
    assert File.read!(Path.join(c.root, ProfileConfiguration.filename())) == File.read!(c.a)
    assert File.read!(Path.join(c.root, MQTTConfiguration.filename())) == File.read!(c.s)
    assert {:ok, snapshot} = ProfileConfiguration.load(c.root)
    assert {:ok, _} = MQTTConfiguration.load(c.root, snapshot.configuration)
    File.rm!(c.a)
    File.rm!(c.s)
    assert {:ok, ^summary} = P.publish(c.root, c.a, c.s, expected)
    refute File.exists?(Path.join(c.root, "home.sqlite"))
    assert {:ok, lock} = HostLock.acquire(Path.join(c.root, "home.sqlite"))
    assert :ok = HostLock.release(lock)
  end

  test "same bytes under a replaced source seal and changed root refuse", c do
    {_, expected} = prepared(c)
    original = File.read!(c.s)
    File.rename!(c.s, c.s <> ".old")
    write(Path.dirname(c.s), Path.basename(c.s), original)
    assert {:error, :native_mqtt_source_changed} = P.publish(c.root, c.a, c.s, expected)
    File.rename!(c.root, c.root <> ".old")
    File.mkdir!(c.root)
    File.chmod!(c.root, 0o700)
    assert {:error, :native_mqtt_source_changed} = P.publish(c.root, c.a, c.s, expected)
    refute File.exists?(Path.join(c.root, ProfileConfiguration.filename()))
  end

  test "conflicting destination refuses preparation and publication without replacement", c do
    {_, expected} = prepared(c)
    path = write(c.root, MQTTConfiguration.filename(), "different-private-policy-canary")
    assert {:error, :native_mqtt_publication_conflict} = P.prepare(c.root, c.a, c.s)
    assert {:error, :native_mqtt_publication_conflict} = P.publish(c.root, c.a, c.s, expected)
    assert File.read!(path) == "different-private-policy-canary"
    refute File.exists?(Path.join(c.root, ProfileConfiguration.filename()))
  end

  test "active Store prevents publication while preparation stays inert", c do
    {summary, expected} = prepared(c)
    assert {:ok, store} = Store.start_link(path: Path.join(c.root, "home.sqlite"))
    on_exit(fn -> if Process.alive?(store), do: GenServer.stop(store) end)
    assert {:ok, ^summary} = P.prepare(c.root, c.a, c.s)
    assert {:error, :native_mqtt_host_running} = P.publish(c.root, c.a, c.s, expected)
    refute File.exists?(Path.join(c.root, ProfileConfiguration.filename()))
    GenServer.stop(store)
    assert {:ok, ^summary} = P.publish(c.root, c.a, c.s, expected)
  end

  test "partial authoring publication is uncertain and exact retry completes it", c do
    {summary, expected} = prepared(c)
    calls = :atomics.new(1, signed: false)

    sync = fn file ->
      if :atomics.add_get(calls, 1, 1) == 3, do: {:error, :eio}, else: :file.sync(file)
    end

    assert {:error, :native_mqtt_publication_uncertain} =
             P.publish(c.root, c.a, c.s, expected, sync)

    assert File.exists?(Path.join(c.root, ProfileConfiguration.filename()))
    refute File.exists?(Path.join(c.root, MQTTConfiguration.filename()))
    assert {:ok, ^summary} = P.publish(c.root, c.a, c.s, expected)
    refute File.exists?(Path.join(c.root, "home.sqlite"))
  end

  test "unsafe document modes and links refuse before publication", c do
    File.chmod!(c.s, 0o600)
    assert {:error, :native_mqtt_provisioning_unavailable} = P.prepare(c.root, c.a, c.s)
    File.chmod!(c.s, 0o400)
    File.ln!(c.s, c.s <> ".link")
    assert {:error, :native_mqtt_provisioning_unavailable} = P.prepare(c.root, c.a, c.s)
    refute File.exists?(Path.join(c.root, "home.sqlite"))
  end

  @tag :requires_socket
  test "actual fixed foreground entry prepares and publishes through original pipes without Home",
       c do
    script = ~S"""
    import json, os, struct, subprocess, sys
    root,a,s=sys.argv[1:]
    def run(record):
      env=dict(os.environ,MIX_ENV='test',WOTEX_HOME_GIT_DEPS='1',WOTEX_HOME_DATA_DIR=root)
      p=subprocess.Popen(['mix','run','--no-start','--no-compile','--no-deps-check','-e','WotexHome.NativeSetup.MQTTProvisioning.main()'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env)
      try:
        body=json.dumps(record,separators=(',',':')).encode()
        p.stdin.write(struct.pack('>I',len(body))+body); p.stdin.flush()
        header=p.stdout.read(4); assert len(header)==4
        size=struct.unpack('>I',header)[0]; assert 1<=size<=4096
        reply=json.loads(p.stdout.read(size))
        p.stdin.close(); assert p.wait(timeout=5)==0
        assert p.stdout.read(1)==b'' and len(p.stderr.read(8193))<=8192
        return reply
      finally:
        if p.poll() is None: p.kill(); p.wait(timeout=5)
    prepared=run(['wotex-home.native-mqtt-provision@1','prepare',a,s])
    assert prepared[0:2]==['wotex-home.native-mqtt-provision@1','prepared']
    assert prepared[6:]==[1,'none']
    assert os.listdir(root)==[]
    published=run(['wotex-home.native-mqtt-provision@1','publish',a,s]+prepared[2:6])
    assert published==[prepared[0],'published']+prepared[2:]
    assert not os.path.exists(root+'/home.sqlite') and not os.path.exists(root+'/ipc')
    print('native MQTT foreground producer and publication passed')
    """

    assert {:ok, "native MQTT foreground producer and publication passed\n"} =
             Woh.Tool.Command.run(
               System.find_executable("python3"),
               ["-c", script, c.root, c.a, c.s],
               16384,
               15000
             )
  end
end
