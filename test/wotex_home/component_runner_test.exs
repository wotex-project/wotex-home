defmodule WotexHome.ComponentRunnerTest do
  use ExUnit.Case, async: false
  alias WotexHome.Durable.Store
  alias WotexHome.Plugins.{Bundle, Runner}

  setup do
    root =
      Path.join(System.tmp_dir!(), "woh-runner-failure-#{System.unique_integer([:positive])}")

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    source = Path.join(root, "source.wasm")
    File.write!(source, <<0, 97, 115, 109, 13, 0, 1, 0>>)
    {:ok, digest} = Bundle.install(root, source)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, digest: digest}
  end

  test "deadline closes the process, rejects capacity and keeps Store responsive", context do
    # Leave room for a cold OS/Python launch before asserting the admitted slot.
    runner = fake_runner(context, "hang", 2_000)
    store = start_supervised!({Store, path: Path.join(context.root, "home.sqlite")})
    before = Store.health(store)
    task = Task.async(fn -> Runner.preview(runner, context.digest, :decode_power, <<0, 0>>) end)
    pid = native_pid(context)

    assert {:error, :component_capacity} =
             Runner.preview(runner, context.digest, :decode_power, <<0, 0>>)

    assert Store.health(store) == before
    assert {:error, :component_timeout} = Task.await(task, 3_000)
    eventually(fn -> not native_alive?(pid) end)
    assert Process.alive?(runner)
    assert Store.health(store) == before
  end

  test "caller loss retires native work and releases the slot", context do
    runner = fake_runner(context, "hang", 2_000)
    caller = spawn(fn -> Runner.preview(runner, context.digest, :decode_power, <<0, 0>>) end)
    pid = native_pid(context)
    Process.exit(caller, :kill)
    eventually(fn -> not native_alive?(pid) and :sys.get_state(runner).active == nil end)
    File.rm!(Path.join(context.root, "worker.pid"))
    next = spawn(fn -> Runner.preview(runner, context.digest, :decode_power, <<0, 0>>) end)
    next_pid = native_pid(context)
    refute next_pid == pid
    Process.exit(next, :kill)
    eventually(fn -> not native_alive?(next_pid) end)
  end

  test "runner shutdown retires a linked job and its OS worker", context do
    runner = fake_runner(context, "hang", 2_000)
    task = Task.async(fn -> Runner.preview(runner, context.digest, :decode_power, <<0, 0>>) end)
    pid = native_pid(context)
    stop_supervised!(Runner)
    assert {:error, :runner_unavailable} = Task.await(task)
    eventually(fn -> not native_alive?(pid) end)
  end

  test "native exit, truncated and huge framing are bounded typed failures", context do
    for {mode, expected} <- [
          {"crash", :native_crash},
          {"truncated", :native_crash},
          {"huge", :invalid_response},
          {"trailing", :invalid_response}
        ] do
      runner = fake_runner(context, mode, 1_000)
      assert {:error, ^expected} = Runner.preview(runner, context.digest, :decode_power, <<0, 0>>)
      pid = native_pid(context)
      eventually(fn -> not native_alive?(pid) end)
      stop_supervised!(Runner)
      File.rm!(Path.join(context.root, "worker.pid"))
    end
  end

  test "unknown inputs never spawn and inherited secrets are removed", context do
    runner = fake_runner(context, "environment", 1_000)
    assert {:error, :invalid_input} = Runner.preview(runner, context.digest, :encode_power, 1)
    refute File.exists?(Path.join(context.root, "worker.pid"))
    previous = System.get_env("WOH_COMPONENT_SECRET_CANARY")
    System.put_env("WOH_COMPONENT_SECRET_CANARY", "private-canary")

    on_exit(fn ->
      if previous == nil,
        do: System.delete_env("WOH_COMPONENT_SECRET_CANARY"),
        else: System.put_env("WOH_COMPONENT_SECRET_CANARY", previous)
    end)

    assert {:ok, %{result: {:ok, false}}} =
             Runner.preview(runner, context.digest, :decode_power, <<0, 0>>)
  end

  defp fake_runner(context, mode, deadline) do
    executable = Path.join(context.root, "worker.py")

    File.write!(executable, """
    #!/usr/bin/python3
    import os, sys, struct, threading, time
    mode = #{inspect(mode)}
    header = sys.stdin.buffer.read(4)
    size = struct.unpack('>I', header)[0]
    sys.stdin.buffer.read(size)
    with open('worker.pid', 'w') as file: file.write(str(os.getpid()))
    def eof():
        sys.stdin.buffer.read(1)
        os._exit(125)
    threading.Thread(target=eof, daemon=True).start()
    if mode == 'hang': time.sleep(60)
    if mode == 'crash': os._exit(9)
    if mode == 'truncated': sys.stdout.buffer.write(b'\\x00\\x00'); sys.stdout.buffer.flush(); os._exit(0)
    if mode == 'huge': sys.stdout.buffer.write(b'\\xff\\xff\\xff\\xff'); sys.stdout.buffer.flush(); time.sleep(60)
    if mode == 'trailing': sys.stdout.buffer.write(b'\\x00\\x00\\x00\\x03\\x01\\x00\\x00extra'); sys.stdout.buffer.flush(); time.sleep(60)
    if mode == 'environment':
        value = int('WOH_COMPONENT_SECRET_CANARY' in os.environ)
        sys.stdout.buffer.write(b'\\x00\\x00\\x00\\x03\\x01\\x00' + bytes([value]))
        sys.stdout.buffer.flush()
        os._exit(0)
    """)

    File.chmod!(executable, 0o700)
    start_supervised!({Runner, root: context.root, executable: executable, deadline_ms: deadline})
  end

  defp native_pid(context) do
    path = Path.join(context.root, "worker.pid")
    eventually(fn -> File.exists?(path) and File.read!(path) != "" end)
    String.to_integer(File.read!(path))
  end

  defp native_alive?(pid) do
    {_, status} = System.cmd("/bin/kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)
    status == 0
  end

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(fun, 0), do: assert(fun.())
end
