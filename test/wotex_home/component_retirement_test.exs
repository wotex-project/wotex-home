defmodule WotexHome.ComponentRetirementTest do
  @moduledoc false

  use ExUnit.Case, async: false
  alias WotexHome.Durable.Store
  alias WotexHome.Plugins.{Bundle, RetirementOwner, Runner}

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "woh-component-retirement-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    source = Path.join(root, "source.wasm")
    File.write!(source, <<0, 97, 115, 109, 13, 0, 1, 0>>)
    {:ok, digest} = Bundle.install(root, source)

    on_exit(fn ->
      File.write(Path.join(root, "release"), "")

      if File.exists?(Path.join(root, "worker.pid")) do
        pid = native_pid(root)
        eventually(fn -> not alive?(pid) end)
      end

      eventually(fn ->
        case Process.whereis(RetirementOwner) do
          nil -> true
          owner -> :sys.get_state(owner).active == nil
        end
      end)

      File.rm_rf!(root)
    end)

    %{root: root, digest: digest}
  end

  test "timeouts, early valid output and malformed output retain native capacity until actual exit",
       c do
    store = start_supervised!({Store, path: Path.join(c.root, "home.sqlite")})
    before = Store.health(store)

    for {mode, expected} <- [
          {"delayed", :component_timeout},
          {"valid-delayed", :component_timeout},
          {"eof-delayed", :component_timeout},
          {"late-delayed", :component_timeout},
          {"huge-delayed", :invalid_response}
        ] do
      reset(c.root)
      runner = start_runner(c, mode, 1_000)
      task = Task.async(fn -> preview(runner, c) end)
      pid = native_pid(c.root)
      assert {:error, ^expected} = Task.await(task, 2_000)
      eventually(fn -> File.exists?(Path.join(c.root, "cancelled")) end)
      assert File.read!(Path.join(c.root, "cancelled")) == "00"
      assert alive?(pid)
      owner = Process.whereis(RetirementOwner)
      token = :sys.get_state(owner).active.token
      send(owner, {:DOWN, nil, :process, self(), :normal})
      send(owner, {:DOWN, make_ref(), :process, self(), :normal})
      send(owner, {:loaded, token, nil, {:error, :invalid_bundle}})
      assert :sys.get_state(owner).active.port != nil
      for _ <- 1..25, do: assert({:error, :component_capacity} = preview(runner, c))
      assert launches(c.root) == 1
      assert Store.health(store) == before
      File.write!(Path.join(c.root, "release"), "")
      eventually(fn -> not alive?(pid) and :sys.get_state(runner).active == nil end)
      assert Store.health(store) == before
      stop_supervised!(Runner)
    end
  end

  test "caller loss fences both the original and another Runner until retirement", c do
    runner = start_runner(c, "delayed", 2_000)

    other =
      start_supervised!(
        Supervisor.child_spec({Runner, root: c.root, executable: Path.join(c.root, "worker.py")},
          id: :other_runner
        )
      )

    caller = spawn(fn -> preview(runner, c) end)
    pid = native_pid(c.root)
    Process.exit(caller, :kill)
    eventually(fn -> File.exists?(Path.join(c.root, "cancelled")) end)

    for target <- [runner, other],
        _ <- 1..15,
        do: assert({:error, :component_capacity} = preview(target, c))

    assert launches(c.root) == 1
    File.write!(Path.join(c.root, "release"), "")
    eventually(fn -> not alive?(pid) and :sys.get_state(runner).active == nil end)
    write_worker(c.root, "success")
    assert {:ok, %{result: {:ok, false}}} = preview(other, c)
    assert launches(c.root) == 2
  end

  for stop <- [:stop, :kill] do
    @stop stop
    test "Runner #{@stop} cannot release a retiring original for its replacement", c do
      runner = start_runner(c, "delayed", 2_000, false)
      owner = Process.whereis(RetirementOwner)
      task = Task.async(fn -> preview(runner, c) end)
      pid = native_pid(c.root)
      owner = owner || Process.whereis(RetirementOwner)
      if @stop == :kill, do: Process.exit(runner, :kill), else: GenServer.stop(runner)
      assert {:error, :runner_unavailable} = Task.await(task)
      eventually(fn -> File.exists?(Path.join(c.root, "cancelled")) end)
      replacement = start_runner(c, "delayed", 2_000)
      assert Process.whereis(RetirementOwner) == owner
      for _ <- 1..25, do: assert({:error, :component_capacity} = preview(replacement, c))
      assert launches(c.root) == 1
      assert alive?(pid)
      File.write!(Path.join(c.root, "release"), "")
      eventually(fn -> not alive?(pid) and :sys.get_state(owner).active == nil end)
      write_worker(c.root, "success")
      assert {:ok, %{result: {:ok, false}}} = preview(replacement, c)
      assert launches(c.root) == 2
    end
  end

  for fault <- [:owner, :port] do
    @fault fault
    @tag :requires_socket
    test "a disposable VM fences admission after #{@fault} loss even after original exit", c do
      write_worker(c.root, "delayed")
      script = Path.join(c.root, "owner_loss.exs")

      File.write!(script, """
      alias WotexHome.Plugins.{Runner, RetirementOwner}
      root = #{inspect(c.root)}
      digest = #{inspect(c.digest)}
      fault = #{inspect(@fault)}
      wait = fn fun ->
        retry = fn retry, n ->
          cond do
            fun.() -> :ok
            n == 0 -> raise "fixture wait expired"
            true -> Process.sleep(10); retry.(retry, n - 1)
          end
        end
        retry.(retry, 300)
      end
      alive = fn pid -> elem(System.cmd("/bin/kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true), 1) == 0 end
      {:ok, runner} = Runner.start_link(root: root, executable: Path.join(root, "worker.py"), deadline_ms: 2000)
      task = Task.async(fn -> Runner.preview(runner, digest, :decode_power, <<0, 0>>) end)
      try do
        wait.(fn -> File.exists?(Path.join(root, "worker.pid")) and File.read!(Path.join(root, "worker.pid")) != "" end)
        pid = String.to_integer(File.read!(Path.join(root, "worker.pid")))
        original_owner = Process.whereis(RetirementOwner)
        if fault == :port do
          Port.close(:sys.get_state(original_owner).active.port)
          wait.(fn -> File.exists?(Path.join(root, "cancelled")) end)
          "" = File.read!(Path.join(root, "cancelled"))
          for _ <- 1..25, do: ({:error, :component_capacity} = Runner.preview(runner, digest, :decode_power, <<0, 0>>))
          File.write!(Path.join(root, "release"), "")
          wait.(fn -> not alive.(pid) end)
          {:error, :component_timeout} = Task.await(task)
          {:error, :component_capacity} = Runner.preview(runner, digest, :decode_power, <<0, 0>>)
          Process.exit(original_owner, :kill)
          wait.(fn -> not Process.alive?(original_owner) end)
          wait.(fn -> :sys.get_state(runner).active == nil end)
        else
          Process.exit(original_owner, :kill)
          {:error, :native_crash} = Task.await(task)
        end
        {:ok, owner} = RetirementOwner.ensure_started()
        true = :sys.get_state(owner).fenced
        for _ <- 1..25, do: ({:error, :component_capacity} = Runner.preview(runner, digest, :decode_power, <<0, 0>>))
        File.write!(Path.join(root, "release"), "")
        wait.(fn -> not alive.(pid) end)
        {:error, :component_capacity} = Runner.preview(runner, digest, :decode_power, <<0, 0>>)
        1 = length(File.read!(Path.join(root, "launches")) |> String.split("\\n", trim: true))
        IO.puts("retirement owner loss remains fenced")
      after
        File.write!(Path.join(root, "release"), "")
      end
      """)

      assert {:ok, output} =
               Woh.Tool.Command.run_diagnostic(
                 System.find_executable("elixir"),
                 [
                   System.find_executable("mix"),
                   "run",
                   "--no-start",
                   "--no-compile",
                   "--no-deps-check",
                   script
                 ],
                 16_384,
                 12_000
               )

      assert output =~ "retirement owner loss remains fenced"
    end
  end

  test "bundle load refusal and normal exit release the unused or proven-retired slot", c do
    runner = start_runner(c, "success", 2_000)

    assert {:error, :invalid_bundle} =
             Runner.preview(runner, String.duplicate("a", 64), :decode_power, <<0, 0>>)

    refute File.exists?(Path.join(c.root, "launches"))
    for _ <- 1..3, do: assert({:ok, %{result: {:ok, false}}} = preview(runner, c))
    assert launches(c.root) == 3
  end

  test "an actual loader exception before Port creation releases only the unused slot", c do
    {:ok, owner} = RetirementOwner.ensure_started()
    token = make_ref()
    deadline = System.monotonic_time(:millisecond) + 2_000

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        # Trusted fault injection: the actual loader raises on missing root.
        RetirementOwner.submit(
          owner,
          self(),
          self(),
          token,
          %{},
          c.digest,
          :decode_power,
          <<0, 0>>,
          deadline
        )

        assert_receive {:component_retired, ^owner, ^token, {:error, :native_crash}}, 1_000
      end)

    assert log =~ "KeyError"
    refute File.exists?(Path.join(c.root, "launches"))
    runner = start_runner(c, "success", 2_000)
    assert {:ok, %{result: {:ok, false}}} = preview(runner, c)
    assert launches(c.root) == 1
  end

  defp preview(runner, c), do: Runner.preview(runner, c.digest, :decode_power, <<0, 0>>)

  defp start_runner(c, mode, deadline, supervised \\ true) do
    executable = write_worker(c.root, mode)
    opts = [root: c.root, executable: executable, deadline_ms: deadline]

    if supervised do
      start_supervised!({Runner, opts})
    else
      {:ok, runner} = Runner.start_link(opts)
      Process.unlink(runner)
      on_exit(fn -> if Process.alive?(runner), do: GenServer.stop(runner) end)
      runner
    end
  end

  defp write_worker(root, mode) do
    executable = Path.join(root, "worker.py")

    File.write!(executable, """
    #!/usr/bin/python3
    import os,sys,struct,threading,time
    mode = #{inspect(mode)}
    threading.Thread(target=lambda: (time.sleep(8), os._exit(124)), daemon=True).start()
    header=sys.stdin.buffer.read(4)
    size=struct.unpack('>I',header)[0]
    sys.stdin.buffer.read(size)
    with open('launches','a') as f: f.write(str(os.getpid())+'\\n')
    with open('worker.pid','w') as f: f.write(str(os.getpid()))
    def retire():
        byte=sys.stdin.buffer.read(1)
        with open('cancelled.pending','x') as f: f.write(byte.hex())
        os.rename('cancelled.pending', 'cancelled')
        while not os.path.exists('release'): time.sleep(0.005)
        if mode=='late-delayed':
            sys.stdout.buffer.write(b'\\x00\\x00\\x00\\x03\\x01\\x00\\x00');sys.stdout.buffer.flush()
        os._exit(125)
    threading.Thread(target=retire,daemon=True).start()
    if mode in ['success','valid-delayed']:
        sys.stdout.buffer.write(b'\\x00\\x00\\x00\\x03\\x01\\x00\\x00');sys.stdout.buffer.flush()
        if mode=='success': os._exit(0)
    if mode=='eof-delayed': os.close(1)
    if mode=='huge-delayed':
        sys.stdout.buffer.write(b'\\xff\\xff\\xff\\xff');sys.stdout.buffer.flush()
    time.sleep(60)
    """)

    File.chmod!(executable, 0o700)
    executable
  end

  defp reset(root) do
    for name <- ~w(worker.pid launches cancelled cancelled.pending release),
        do: File.rm(Path.join(root, name))
  end

  defp launches(root),
    do: File.read!(Path.join(root, "launches")) |> String.split("\n", trim: true) |> length()

  defp native_pid(root) do
    path = Path.join(root, "worker.pid")
    eventually(fn -> File.exists?(path) and File.read!(path) != "" end)
    String.to_integer(File.read!(path))
  end

  defp alive?(pid),
    do:
      elem(System.cmd("/bin/kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true), 1) ==
        0

  defp eventually(fun, attempts \\ 200)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end

  defp eventually(fun, 0), do: assert(fun.())
end
