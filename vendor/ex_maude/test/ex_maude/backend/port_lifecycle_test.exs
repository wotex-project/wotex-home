defmodule ExMaude.Backend.PortLifecycleTest do
  @moduledoc """
  Tests Port backend timeout and restart semantics with protocol-compatible
  fake Maude executables.

  The fake shell scripts speak the prompt protocol, which makes lifecycle
  behavior deterministic without requiring a real Maude installation.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ExMaude.Backend.Port
  alias ExMaude.Error

  @fake_maude Path.expand("../../support/fake_maude.sh", __DIR__)
  @fake_silent Path.expand("../../support/fake_silent.sh", __DIR__)

  defp start_fake_worker(opts \\ []) do
    opts = Keyword.merge([maude_path: @fake_maude, use_pty: false], opts)
    start_supervised!({Port, opts}, restart: :temporary)
  end

  test "a blocked input pipe cannot outlive its command deadline" do
    path = Path.expand("../../support/fake_blocked_input.sh", __DIR__)
    pid = start_supervised!({Port, maude_path: path}, restart: :temporary)
    ref = Process.monitor(pid)

    assert {:error, %Error{type: :timeout}} =
             Port.execute(pid, String.duplicate("x", 1_000_000), timeout: 50)

    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
  end

  describe "command timeout" do
    test "reports the requested timeout value in the error" do
      pid = start_fake_worker()
      ref = Process.monitor(pid)

      assert {:error, %Error{type: :timeout} = error} =
               Port.execute(pid, "hang", timeout: 80)

      assert error.details.timeout_ms == 80
      assert error.message =~ "80ms"
      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :command_timeout}}, 1_000
    end

    test "stops the worker so the pool can replace it" do
      pid = start_fake_worker()
      ref = Process.monitor(pid)

      assert {:error, %Error{type: :timeout}} = Port.execute(pid, "hang", timeout: 50)
      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :command_timeout}}, 1_000
    end

    test "emits a timeout telemetry event with the actual timeout" do
      handler_id = "port-lifecycle-timeout-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:ex_maude, :server, :timeout],
        fn _, measurements, _, _ ->
          send(test_pid, {:timeout_event, measurements})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      pid = start_fake_worker()
      ref = Process.monitor(pid)
      Port.execute(pid, "hang", timeout: 60)

      assert_receive {:timeout_event, %{timeout_ms: 60}}, 1_000
      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :command_timeout}}, 1_000
    end
  end

  describe "stale timeout messages" do
    test "a timer whose command already completed is ignored" do
      state = %Port{}

      assert {:noreply, ^state} = Port.handle_info({:command_timeout, make_ref()}, state)
    end

    test "a timer for a previous command does not cut into the current one" do
      pending = %{from: {self(), make_ref()}, ref: make_ref(), timer: make_ref(), timeout: 100}
      state = %Port{pending: pending}

      assert {:noreply, %Port{pending: ^pending}} =
               Port.handle_info({:command_timeout, make_ref()}, state)
    end
  end

  describe "busy guard" do
    test "rejects a second command while one is in flight" do
      pending = %{from: {self(), make_ref()}, ref: make_ref(), timer: make_ref(), timeout: 100}
      state = %Port{pending: pending}

      assert {:reply, {:error, %Error{type: :busy}}, ^state} =
               Port.handle_call(
                 {:execute, "reduce in NAT : 1 .", 100},
                 {self(), make_ref()},
                 state
               )
    end
  end

  describe "response framing and limits" do
    test "preserves prompt-like text inside a response and frames the next command" do
      pid = start_fake_worker()

      assert {:ok, response} = Port.execute(pid, "payload Maude> marker")
      assert response =~ "echo:payload Maude> marker"

      assert {:ok, next_response} = Port.execute(pid, "marker-b")
      assert next_response =~ "echo:marker-b"
      refute next_response =~ "payload"
    end

    test "an oversized response returns a structured error and retires the worker" do
      pid = start_fake_worker(max_response_bytes: 64)
      ref = Process.monitor(pid)

      assert {:error, %Error{type: :response_too_large} = error} =
               Port.execute(pid, "oversized")

      assert error.details == %{max_response_bytes: 64}
      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :response_too_large}}, 1_000
    end
  end

  describe "response isolation across worker restarts" do
    test "a command after a timeout never receives the timed-out command's output" do
      pool_name = :port_lifecycle_pool

      {:ok, pool} =
        :poolboy.start_link(
          [name: {:local, pool_name}, worker_module: Port, size: 1, max_overflow: 0],
          maude_path: @fake_maude,
          use_pty: false
        )

      {worker_ref, {:error, %Error{type: :timeout}}} =
        :poolboy.transaction(pool_name, fn worker ->
          {Process.monitor(worker), Port.execute(worker, "hang", timeout: 50)}
        end)

      # Wait for the timed-out worker to die and for poolboy to replace it —
      # checkouts in that window race the reaping and get the dying pid.
      assert_receive {:DOWN, ^worker_ref, :process, _, {:shutdown, :command_timeout}}, 1_000
      wait_for_available_worker(pool_name)

      # The replacement must answer with the new command's payload, not
      # anything from the hung session.
      assert {:ok, response} =
               :poolboy.transaction(pool_name, fn worker ->
                 Port.execute(worker, "marker-b", timeout: 1_000)
               end)

      assert response =~ "marker-b"
      refute response =~ "hang"

      :poolboy.stop(pool)
    end
  end

  describe "startup failures" do
    test "init fails fast when the binary never prints a prompt" do
      Process.flag(:trap_exit, true)

      assert capture_log(fn ->
               assert {:error, {:maude_start_failed, :no_prompt}} =
                        Port.start_link(
                          maude_path: @fake_silent,
                          use_pty: false,
                          startup_timeout_ms: 150
                        )
             end) =~ "Timeout waiting for Maude prompt"
    end

    test "init reports a binary that exits before becoming ready" do
      Process.flag(:trap_exit, true)
      false_path = System.find_executable("false")

      assert {:error, {:maude_start_failed, {:exited_during_startup, _}}} =
               Port.start_link(
                 maude_path: false_path,
                 use_pty: false,
                 startup_timeout_ms: 1_000
               )
    end
  end

  describe "launcher resolution" do
    test "explicit pipes mode always uses -interactive" do
      assert {"/bin/maude", ["-interactive" | _]} =
               Port.resolve_launcher(false, {:unix, :darwin}, "/bin/maude", fn _ -> nil end)
    end

    test "darwin uses script when available" do
      finder = fn "script" -> "/usr/bin/script" end

      assert {"/usr/bin/script", ["-q", "/dev/null", "/bin/maude" | _]} =
               Port.resolve_launcher(true, {:unix, :darwin}, "/bin/maude", finder)
    end

    test "darwin falls back to -interactive when script is missing" do
      assert {"/bin/maude", ["-interactive" | _]} =
               Port.resolve_launcher(true, {:unix, :darwin}, "/bin/maude", fn _ -> nil end)
    end

    test "linux prefers unbuffer, then script, then -interactive" do
      unbuffer_finder = fn
        "unbuffer" -> "/usr/bin/unbuffer"
        _ -> nil
      end

      assert {"/usr/bin/unbuffer", ["/bin/maude" | _]} =
               Port.resolve_launcher(true, {:unix, :linux}, "/bin/maude", unbuffer_finder)

      script_finder = fn
        "script" -> "/usr/bin/script"
        _ -> nil
      end

      assert {"/usr/bin/script", ["-qc", cmd, "/dev/null"]} =
               Port.resolve_launcher(true, {:unix, :linux}, "/bin/maude", script_finder)

      assert cmd =~ "/bin/maude"

      assert {"/bin/maude", ["-interactive" | _]} =
               Port.resolve_launcher(true, {:unix, :linux}, "/bin/maude", fn _ -> nil end)
    end

    test "linux script preserves shell metacharacters in executable paths" do
      executable = "/tmp/Maude's $(printf injected); executable"

      finder = fn
        "script" -> "/usr/bin/script"
        _ -> nil
      end

      {_, ["-qc", command, _]} = Port.resolve_launcher(true, {:unix, :linux}, executable, finder)

      # Let the shell parse the generated arguments without executing them.
      {parsed, 0} = System.cmd("sh", ["-c", "set -- " <> command <> "; printf '%s' \"$1\""])
      assert parsed == executable
    end

    test "non-unix platforms use -interactive" do
      assert {"maude.exe", ["-interactive" | _]} =
               Port.resolve_launcher(true, {:win32, :nt}, "maude.exe", fn _ -> nil end)
    end
  end

  describe "os process cleanup" do
    test "the fake maude OS process is killed when the worker times out" do
      pid = start_fake_worker()
      %Port{os_pid: os_pid} = :sys.get_state(pid)
      assert is_integer(os_pid)

      ref = Process.monitor(pid)
      Port.execute(pid, "hang", timeout: 50)
      assert_receive {:DOWN, ^ref, :process, _, {:shutdown, :command_timeout}}, 1_000

      # `kill -0` probes for existence: non-zero exit means the pid is gone.
      wait_until_dead(os_pid, 50)
    end
  end

  describe "real Maude integration" do
    @tag :integration
    test "an unbounded rewrite times out, restarts the worker, and kills the interpreter" do
      # The worker stops with {:shutdown, _} on timeout; trap the linked exit
      # so it doesn't take the test process down with it.
      Process.flag(:trap_exit, true)

      loop_module =
        Path.join(System.tmp_dir!(), "ex_maude_loop_#{System.unique_integer([:positive])}.maude")

      File.write!(loop_module, "mod LOOP is sort S . op a : -> S . rl a => a . endm\n")
      on_exit(fn -> File.rm(loop_module) end)

      {:ok, pid} = Port.start_link(use_pty: false, preload_modules: [loop_module])
      %Port{os_pid: os_pid} = :sys.get_state(pid)
      ref = Process.monitor(pid)

      assert {:error, %Error{type: :timeout}} =
               Port.execute(pid, "rewrite in LOOP : a .", timeout: 300)

      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :command_timeout}}, 1_000
      wait_until_dead(os_pid, 100)
    end
  end

  defp wait_for_available_worker(pool_name, attempts \\ 100) do
    Enum.reduce_while(1..attempts, nil, fn _, _ ->
      case :poolboy.status(pool_name) do
        {:ready, available, _, _} when available > 0 ->
          {:halt, :ok}

        _ ->
          Process.sleep(10)
          {:cont, nil}
      end
    end) || flunk("pool never recovered an available worker")
  end

  defp wait_until_dead(os_pid, attempts) do
    probe = fn ->
      System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end

    Enum.reduce_while(1..attempts, nil, fn _, _ ->
      case probe.() do
        {_, 0} ->
          Process.sleep(20)
          {:cont, nil}

        {_, _} ->
          {:halt, :ok}
      end
    end) ||
      flunk("OS process #{os_pid} still alive after timeout-triggered worker stop")
  end

  describe "startup preloads" do
    @tag :integration
    test "rejects invalid Maude source instead of recording success" do
      Process.flag(:trap_exit, true)

      path =
        Path.join(
          System.tmp_dir!(),
          "invalid-preload-#{System.unique_integer([:positive])}.maude"
        )

      File.write!(path, "fmod INVALID-PRELOAD is protecting NONEXISTENT-PRELOAD . endfm")
      on_exit(fn -> File.rm(path) end)

      assert {:error, {:maude_start_failed, {:preload_failed, ^path, %Error{}}}} =
               Port.start_link(maude_path: ExMaude.Binary.path(), preload_modules: [path])
    end

    test "rejects missing preload files" do
      Process.flag(:trap_exit, true)
      path = "/nonexistent/ex-maude-preload.maude"

      assert {:error,
              {:maude_start_failed, {:preload_failed, ^path, %Error{type: :file_not_found}}}} =
               Port.start_link(maude_path: @fake_maude, preload_modules: [path])
    end
  end
end
