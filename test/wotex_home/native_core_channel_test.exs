defmodule WotexHome.NativeCoreChannelTest do
  use ExUnit.Case
  alias WotexHome.Authority
  alias WotexHome.Durable.Store
  alias WotexHome.NativeSetup.{Bridge, Codec}

  setup do
    directory =
      Path.join(System.tmp_dir!(), "woh-native-channel-#{System.unique_integer([:positive])}")

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    path = Path.join(directory, "home.sqlite")

    store =
      start_supervised!(
        Supervisor.child_spec({Store, path: path, name: __MODULE__.Store}, restart: :temporary)
      )

    on_exit(fn -> File.rm_rf!(directory) end)
    {:ok, store: store, authority: Authority.new(store: __MODULE__.Store), path: path}
  end

  test "independent pipe records reconcile one original verifier-only receipt", c do
    {:ok, identity} = Authority.native_setup_identity(c.authority)
    verifier = :crypto.hash(:sha256, :crypto.strong_rand_bytes(32)) |> Base.encode16(case: :lower)

    bytes =
      "[\"wotex-home.native-setup-authority.v1\",\"ensure\",\"#{identity["deployment_id"]}\",\"#{identity["owner_id"]}\",1,\"operator\",\"#{verifier}\"]"

    {:ok, device} = StringIO.open(frame(bytes) <> frame(bytes), encoding: :latin1)
    assert :ok = Bridge.run(c.authority, device)
    {_, output} = StringIO.contents(device)
    {first, rest} = response(output)
    {second, ""} = response(rest)
    assert first == second

    assert {:ok, %{"principal_id" => "native-setup-v1:1:operator", "revision" => 1}} =
             Codec.decode("ensured", first)

    refute String.contains?(output, verifier)
    assert {:ok, 1} = Store.revision(c.store)
    StringIO.close(device)
  end

  test "complete malformed and oversized frames stop without provisioning", c do
    for bytes <- [frame("[\"wotex-home.native-setup-authority.v1\",\"unknown\"]"), <<4_097::32>>] do
      {:ok, device} = StringIO.open(bytes, encoding: :latin1)
      assert {:error, :invalid_native_setup_record} = Bridge.run(c.authority, device)
      {_, output} = StringIO.contents(device)
      {body, ""} = response(output)

      assert body ==
               "[\"wotex-home.native-setup-authority.v1\",\"error\",\"invalid_native_setup_record\"]"

      StringIO.close(device)
    end

    assert {:ok, 0} = Store.revision(c.store)
  end

  test "entry point refuses an existing Home VM without changing its lifecycle or IO" do
    supervisor = Process.whereis(WotexHome.Supervisor)
    assert is_pid(supervisor)
    logger = :logger.get_handler_config(:default)
    io = :io.getopts(:standard_io)
    assert {:error, :native_setup_unavailable} = WotexHome.NativeSetup.CoreHost.main()
    assert Process.alive?(supervisor)
    assert :logger.get_handler_config(:default) == logger
    assert :io.getopts(:standard_io) == io
  end

  test "original Store death ends an idle read despite a named replacement", c do
    parent = self()

    device =
      spawn(fn ->
        receive do
          {:io_request, reader, reply, request} ->
            send(parent, {:idle_native_read, reader, reply, request})

            receive do
              :stop -> :ok
            end
        end
      end)

    on_exit(fn -> Process.exit(device, :kill) end)
    task = Task.async(fn -> Bridge.run(c.authority, device) end)
    assert_receive {:idle_native_read, reader, _, _}, 1_000
    GenServer.stop(c.store)

    replacement =
      start_supervised!({Store, path: c.path, name: __MODULE__.Store}, id: :replacement)

    assert {:error, :core_owner_lost} = Task.await(task, 2_000)
    refute Process.alive?(reader)
    assert Process.alive?(replacement)
    assert {:ok, 0} = Store.revision(replacement)
  end

  test "decision timeout retains uncertainty and retries the same committed custody", c do
    {:ok, identity} = Authority.native_setup_identity(c.authority)

    input =
      identity
      |> Map.delete("store_revision")
      |> Map.merge(%{
        "role" => "operator",
        "verifier" =>
          :crypto.hash(:sha256, :crypto.strong_rand_bytes(32)) |> Base.encode16(case: :lower)
      })

    {:ok, body} = Codec.encode("ensure", input)
    {:ok, device} = StringIO.open(frame(body), encoding: :latin1)
    :sys.suspend(c.store)

    try do
      task = Task.async(fn -> Bridge.run(c.authority, device) end)
      assert {:error, :outcome_unknown} = Task.await(task, 7_000)
      assert {_, ""} = StringIO.contents(device)
    after
      :sys.resume(c.store)
      StringIO.close(device)
    end

    assert {:ok, 1} = Store.revision(c.store)

    assert {:ok, %{"revision" => 1} = original} =
             Authority.ensure_native_principal(c.authority, input)

    assert {:ok, ^original} = Authority.ensure_native_principal(c.authority, input)
    assert {:ok, 1} = Store.revision(c.store)
  end

  test "original lookup timeout is a read timeout and queued work creates no custody", c do
    {:ok, identity} = Authority.native_setup_identity(c.authority)

    input =
      identity
      |> Map.delete("store_revision")
      |> Map.merge(%{
        "role" => "operator",
        "verifier" => String.duplicate("a", 64),
        "creation_revision" => 1
      })

    {:ok, body} = Codec.encode("existing", input)
    {:ok, device} = StringIO.open(frame(body), encoding: :latin1)
    :sys.suspend(c.store)

    try do
      task = Task.async(fn -> Bridge.run(c.authority, device) end)
      assert {:error, :frame_timeout} = Task.await(task, 7_000)
      assert {_, ""} = StringIO.contents(device)
    after
      :sys.resume(c.store)
      StringIO.close(device)
    end

    assert {:ok, 0} = Store.revision(c.store)

    assert {:error, :native_custody_conflict} =
             Authority.existing_native_principal(c.authority, input)

    assert {:ok, 0} = Store.revision(c.store)
  end

  defp frame(body), do: <<byte_size(body)::32, body::binary>>
  defp response(<<size::32, body::binary-size(size), rest::binary>>), do: {body, rest}
end

defmodule WotexHome.NativeCoreHostCLITest do
  use ExUnit.Case
  alias WotexHome.Durable.{HostLock, Store}
  alias WotexHome.NativeSetup.Codec

  setup do
    directory =
      Path.join(System.tmp_dir!(), "woh-native-child-#{System.unique_integer([:positive])}")

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)
    {:ok, directory: directory, path: Path.join(directory, "home.sqlite")}
  end

  @tag requires_socket: true
  test "real child pipes resolve the same receipt after a fresh process", c do
    port = child(c.directory)
    assert Port.command(port, frame("[\"wotex-home.native-setup-authority.v1\",\"identity\"]"))
    {body, buffer} = receive_frame(port, "")
    assert {:ok, identity} = Codec.decode("identity", body)

    input =
      identity
      |> Map.delete("store_revision")
      |> Map.merge(%{
        "role" => "operator",
        "verifier" =>
          :crypto.hash(:sha256, :crypto.strong_rand_bytes(32)) |> Base.encode16(case: :lower)
      })

    {:ok, ensure} = Codec.encode("ensure", input)
    {:ok, existing} = Codec.encode("existing", Map.put(input, "creation_revision", 1))
    assert Port.command(port, frame(existing))
    {missing, buffer} = receive_frame(port, buffer)
    assert {:ok, %{"reason" => "native_custody_conflict"}} = Codec.decode("error", missing)
    assert Port.command(port, frame(ensure))
    {first, buffer} = receive_frame(port, buffer)
    assert {:ok, %{"revision" => 1} = receipt} = Codec.decode("ensured", first)
    assert Port.command(port, frame(existing))
    {found, buffer} = receive_frame(port, buffer)
    assert {:ok, ^receipt} = Codec.decode("found", found)
    assert Port.command(port, frame("[\"wotex-home.native-setup-authority.v1\",\"unknown\"]"))
    {error, ""} = receive_frame(port, buffer)
    assert {:ok, %{"reason" => "invalid_native_setup_record"}} = Codec.decode("error", error)
    assert_receive {^port, {:exit_status, 1}}, 5_000
    assert {:ok, lock} = HostLock.acquire(c.path)
    :ok = HostLock.release(lock)

    reopened = child(c.directory)
    assert Port.command(reopened, frame(existing))
    {same, ""} = receive_frame(reopened, "")
    assert same == found
    assert Port.command(reopened, frame(ensure))
    {second, ""} = receive_frame(reopened, "")
    assert second == first
    assert Port.command(reopened, <<4_097::32>>)
    {_, ""} = receive_frame(reopened, "")
    assert_receive {^reopened, {:exit_status, 1}}, 5_000
    assert {:ok, store} = Store.start_link(path: c.path)
    assert {:ok, 1} = Store.revision(store)
    GenServer.stop(store)
    refute File.exists?(Path.join(c.directory, "ipc/home.sock"))
  end

  @tag requires_socket: true
  test "real child refuses oversized header before waiting for its body", c do
    port = child(c.directory)
    started = System.monotonic_time(:millisecond)
    assert Port.command(port, <<4_097::32>>)
    {body, ""} = receive_frame(port, "")
    assert {:ok, %{"reason" => "invalid_native_setup_record"}} = Codec.decode("error", body)
    assert_receive {^port, {:exit_status, 1}}, 5_000
    assert System.monotonic_time(:millisecond) - started < 4_000
    assert {:ok, store} = Store.start_link(path: c.path)
    assert {:ok, 0} = Store.revision(store)
    GenServer.stop(store)
  end

  @tag requires_socket: true
  test "real child dripped header and body share one original deadline", c do
    port = child(c.directory)
    # Read one identity first so VM startup time is outside the drip interval.
    assert Port.command(port, frame("[\"wotex-home.native-setup-authority.v1\",\"identity\"]"))
    {_, ""} = receive_frame(port, "")
    started = System.monotonic_time(:millisecond)

    for byte <- [0, 0, 0, 52, ?[] do
      assert Port.command(port, <<byte>>)
      Process.sleep(1_100)
    end

    assert_receive {^port, {:exit_status, 1}}, 2_000
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 5_000 and elapsed < 7_500
    assert {:ok, store} = Store.start_link(path: c.path)
    assert {:ok, 0} = Store.revision(store)
    GenServer.stop(store)
  end

  @tag requires_socket: true
  test "actual stdin EOF gracefully closes the child's normal Host", c do
    python = System.find_executable("python3")
    assert is_binary(python)

    script = ~S"""
    import os, struct, subprocess, sys
    environment = dict(os.environ, WOTEX_HOME_DATA_DIR=sys.argv[1], MIX_ENV='test', WOTEX_HOME_GIT_DEPS='1')
    environment.pop('WOTEX_HOME_LIFX_INTERFACE', None)
    process = subprocess.Popen(['mix','run','--no-start','--no-compile','--no-deps-check','bin/native_core_host.exs'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment)
    try:
      body = b'["wotex-home.native-setup-authority.v1","identity"]'
      process.stdin.write(struct.pack('>I', len(body)) + body)
      process.stdin.flush()
      header = process.stdout.read(4)
      assert len(header) == 4
      size = struct.unpack('>I', header)[0]
      assert 1 <= size <= 4096
      assert len(process.stdout.read(size)) == size
      process.stdin.close()
      assert process.wait(timeout=5) == 0
      assert process.stdout.read(1) == b''
      assert len(process.stderr.read(8193)) <= 8192
      print('native core EOF shutdown passed')
    finally:
      if process.poll() is None:
        process.kill()
        process.wait(timeout=5)
    """

    assert {:ok, "native core EOF shutdown passed\n"} =
             Woh.Tool.Command.run(python, ["-c", script, c.directory], 16_384, 12_000)

    assert {:ok, lock} = HostLock.acquire(c.path)
    :ok = HostLock.release(lock)
    refute File.exists?(Path.join(c.directory, "ipc/home.sock"))
  end

  defp child(directory) do
    port =
      Port.open({:spawn_executable, System.find_executable("mix")}, [
        :binary,
        :exit_status,
        :use_stdio,
        {:args,
         ["run", "--no-start", "--no-compile", "--no-deps-check", "bin/native_core_host.exs"]},
        {:env,
         [
           {~c"MIX_ENV", ~c"test"},
           {~c"WOTEX_HOME_GIT_DEPS", ~c"1"},
           {~c"WOTEX_HOME_DATA_DIR", String.to_charlist(directory)},
           {~c"WOTEX_HOME_LIFX_INTERFACE", false}
         ]}
      ])

    on_exit(fn -> if Port.info(port), do: Port.close(port) end)
    port
  end

  defp frame(body), do: <<byte_size(body)::32, body::binary>>

  defp receive_frame(port, bytes, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 5_000

    case bytes do
      <<size::32, rest::binary>> when size in 1..4_096 and byte_size(rest) >= size ->
        <<body::binary-size(size), remaining::binary>> = rest
        {body, remaining}

      _ ->
        receive do
          {^port, {:data, data}} ->
            assert byte_size(bytes) + byte_size(data) <= 8_200
            receive_frame(port, bytes <> data, deadline)

          {^port, {:exit_status, status}} ->
            flunk("native child exited before a bounded reply (#{status})")
        after
          max(0, deadline - System.monotonic_time(:millisecond)) ->
            flunk("native child reply deadline exceeded")
        end
    end
  end
end
