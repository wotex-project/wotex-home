defmodule ExMaude.Backend.CNodeIntegrationTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias ExMaude.Backend

  @moduletag :cnode
  @moduletag :integration
  @moduletag timeout: 60_000

  @cnode_available Backend.available?(:cnode) and Node.alive?()

  if @cnode_available do
    alias ExMaude.Backend.CNode, warn: false
    @fake_drip Path.expand("../../support/fake_drip_maude.sh", __DIR__)
    @fake_maude Path.expand("../../support/fake_maude.sh", __DIR__)

    @tag :tmp_dir
    test "load diagnostics distinguish result text from warnings", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "quoted.maude")
      File.write!(path, ~s|reduce in STRING : "Warning and Error" .|)
      pid = start_supervised!({CNode, preload_modules: [path]})
      assert :ok = CNode.load_file(pid, path)

      File.write!(path, "fmod INVALID-IMPORT is protecting ABSENT-MODULE . endfm")
      assert {:error, %ExMaude.Error{}} = CNode.load_file(pid, path)
      assert {:ok, "3"} = CNode.execute(pid, "reduce in NAT : 1 + 2 .")
    end

    describe "struct" do
      test "has expected fields" do
        state = %CNode{}
        assert Map.has_key?(state, :cnode_name)
        assert Map.has_key?(state, :port)
        assert Map.has_key?(state, :os_pid)
        assert Map.has_key?(state, :maude_path)
        assert Map.has_key?(state, :cookie)
        assert Map.has_key?(state, :connected)
        assert state.connected == false
      end
    end

    describe "start_link/1" do
      test "returns only after the C-Node worker is connected" do
        assert {:ok, pid} = CNode.start_link([])
        assert Process.alive?(pid)
        assert CNode.alive?(pid)
        assert {:ok, "3"} = CNode.execute(pid, "reduce in NAT : 1 + 2")

        CNode.stop(pid)
      end

      test "does not expose the distribution cookie in process arguments" do
        assert {:ok, pid} = CNode.start_link([])
        state = :sys.get_state(pid)
        cookie = Node.get_cookie() |> Atom.to_string()

        {command, 0} =
          System.cmd("ps", ["-o", "command=", "-p", Integer.to_string(state.os_pid)],
            stderr_to_stdout: true
          )

        refute command =~ cookie
        CNode.stop(pid)
      end

      test "loads configured modules before returning" do
        path = Path.join(System.tmp_dir!(), "test_cnode_preload_#{:rand.uniform(10_000)}.maude")

        File.write!(
          path,
          "fmod CNODE-PRELOAD is sort Answer . op answer : -> Answer . endfm"
        )

        on_exit(fn -> File.rm(path) end)

        assert {:ok, pid} = CNode.start_link(preload_modules: [path])
        assert {:ok, "answer"} = CNode.execute(pid, "reduce in CNODE-PRELOAD : answer")

        CNode.stop(pid)
      end

      test "fails gracefully with invalid maude path" do
        Process.flag(:trap_exit, true)
        result = CNode.start_link(maude_path: "/nonexistent/maude")

        case result do
          {:error, _} ->
            assert true

          {:ok, pid} ->
            assert_receive {:EXIT, ^pid, _reason}, 5000
        end
      end
    end

    describe "execute/3" do
      setup do
        {:ok, pid} = CNode.start_link([])

        Enum.reduce_while(1..40, false, fn _, _ ->
          if CNode.alive?(pid) do
            {:halt, true}
          else
            Process.sleep(100)
            {:cont, false}
          end
        end)

        on_exit(fn -> catch_exit(CNode.stop(pid)) end)
        {:ok, pid: pid}
      end

      test "executes simple reduce command", %{pid: pid} do
        assert {:ok, "3"} = CNode.execute(pid, "reduce in NAT : 1 + 2")
      end

      test "emits redacted command-start telemetry", %{pid: pid} do
        test_pid = self()
        handler = "cnode-command-start-#{System.unique_integer([:positive])}"

        :telemetry.attach(
          handler,
          [:ex_maude, :server, :command_start],
          fn _, measurements, metadata, _ -> send(test_pid, {measurements, metadata}) end,
          nil
        )

        on_exit(fn -> :telemetry.detach(handler) end)
        assert {:ok, "3"} = CNode.execute(pid, "reduce in NAT : 1 + 2")

        assert_receive {%{command_bytes: bytes}, %{backend: :cnode} = metadata}
        assert bytes == byte_size("reduce in NAT : 1 + 2 .")
        refute Map.has_key?(metadata, :command)
      end

      test "handles syntax errors gracefully", %{pid: pid} do
        # Incomplete commands may timeout as Maude waits for more input,
        # or return a warning. Both are acceptable behaviors.
        result = CNode.execute(pid, "reduce in NAT : 1 + .", timeout: 5000)
        assert match?({:ok, _}, result) or match?({:error, _}, result)
      end

      test "handles multiple sequential commands", %{pid: pid} do
        for i <- 1..10 do
          assert {:ok, result} = CNode.execute(pid, "reduce in NAT : #{i} + #{i} .")
          assert result =~ "#{i * 2}"
        end
      end

      test "handles timeout option", %{pid: pid} do
        assert {:ok, _} = CNode.execute(pid, "reduce in NAT : 1 + 1 .", timeout: 5000)
      end

      test "returns responses larger than the former 64 KiB bridge buffer", %{pid: pid} do
        payload = String.duplicate("x", 100_000)

        assert {:ok, result} =
                 CNode.execute(pid, ~s|reduce in STRING : "#{payload}"|, timeout: 10_000)

        assert byte_size(result) >= byte_size(payload)
        assert result =~ String.slice(payload, 0, 1_000)
      end
    end

    describe "load_file/2" do
      setup do
        {:ok, pid} = CNode.start_link([])

        Enum.reduce_while(1..40, false, fn _, _ ->
          if CNode.alive?(pid) do
            {:halt, true}
          else
            Process.sleep(100)
            {:cont, false}
          end
        end)

        on_exit(fn -> catch_exit(CNode.stop(pid)) end)
        {:ok, pid: pid}
      end

      test "loads valid Maude file", %{pid: pid} do
        path = Path.join(System.tmp_dir!(), "test_cnode_#{:rand.uniform(10000)}.maude")
        File.write!(path, "fmod TEST-CNODE is sort Foo . endfm")
        on_exit(fn -> File.rm(path) end)

        assert :ok = CNode.load_file(pid, path)
      end

      test "loads a file whose path contains spaces", %{pid: pid} do
        path = Path.join(System.tmp_dir!(), "test cnode #{:rand.uniform(10000)}.maude")
        File.write!(path, "fmod TEST-CNODE-SPACED-PATH is sort Foo . endfm")
        on_exit(fn -> File.rm(path) end)

        assert :ok = CNode.load_file(pid, path)
      end

      test "returns error for missing file", %{pid: pid} do
        result = CNode.load_file(pid, "/nonexistent/file.maude")
        assert {:error, _} = result
      end
    end

    describe "worker lifecycle" do
      setup do
        {:ok, pid} = CNode.start_link([])

        Enum.reduce_while(1..40, false, fn _, _ ->
          if CNode.alive?(pid) do
            {:halt, true}
          else
            Process.sleep(100)
            {:cont, false}
          end
        end)

        on_exit(fn -> catch_exit(CNode.stop(pid)) end)
        {:ok, pid: pid}
      end

      test "a timed-out command stops the worker for pool replacement", %{pid: pid} do
        # The worker stops with {:shutdown, _}; trap the linked exit.
        Process.flag(:trap_exit, true)
        path = Path.join(System.tmp_dir!(), "test_cnode_loop_#{:rand.uniform(10_000)}.maude")
        File.write!(path, "mod CNODE-LOOP is sort S . op a : -> S . rl a => a . endm")
        on_exit(fn -> File.rm(path) end)

        assert :ok = CNode.load_file(pid, path)

        ref = Process.monitor(pid)

        assert {:error, %ExMaude.Error{type: :timeout}} =
                 CNode.execute(pid, "rewrite in CNODE-LOOP : a .", timeout: 300)

        assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, {:bridge_failure, :timeout}}},
                       2_000
      end

      test "responses are parsed like the other backends", %{pid: pid} do
        assert {:ok, "3"} = CNode.execute(pid, "reduce in NAT : 1 + 2 .")
      end

      test "a stale reply from a previous command is never misattributed", %{pid: pid} do
        Process.flag(:trap_exit, true)
        # Force a timeout whose late bridge reply would previously have been
        # consumed by the next command's bare receive.
        path = Path.join(System.tmp_dir!(), "test_cnode_loop2_#{:rand.uniform(10_000)}.maude")
        File.write!(path, "mod CNODE-LOOP2 is sort S . op a : -> S . rl a => a . endm")
        on_exit(fn -> File.rm(path) end)

        assert :ok = CNode.load_file(pid, path)
        ref = Process.monitor(pid)

        {:error, _} = CNode.execute(pid, "rewrite in CNODE-LOOP2 : a .", timeout: 300)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000

        # A fresh worker answers the new command with the new payload.
        {:ok, pid2} = CNode.start_link([])

        Enum.reduce_while(1..40, false, fn _, _ ->
          if CNode.alive?(pid2),
            do: {:halt, true},
            else:
              (
                Process.sleep(100)
                {:cont, false}
              )
        end)

        on_exit(fn -> catch_exit(CNode.stop(pid2)) end)

        assert {:ok, "42"} = CNode.execute(pid2, "reduce in NAT : 40 + 2 .")
      end

      test "continuous partial output cannot extend the command deadline", %{pid: pooled_pid} do
        CNode.stop(pooled_pid)
        Process.flag(:trap_exit, true)
        {:ok, pid} = CNode.start_link(maude_path: @fake_drip)

        started_at = System.monotonic_time(:millisecond)
        assert {:error, %ExMaude.Error{type: :timeout}} = CNode.execute(pid, "drip", timeout: 150)
        elapsed = System.monotonic_time(:millisecond) - started_at

        assert elapsed < 700
      end

      test "prompt-like payload text is preserved without leaking into the next frame", %{
        pid: pooled_pid
      } do
        CNode.stop(pooled_pid)
        {:ok, pid} = CNode.start_link(maude_path: @fake_maude)
        on_exit(fn -> catch_exit(CNode.stop(pid)) end)

        assert {:ok, response} = CNode.execute(pid, "payload Maude> marker")
        assert response =~ "echo:payload Maude> marker"

        assert {:ok, next_response} = CNode.execute(pid, "marker-b")
        assert next_response =~ "echo:marker-b"
        refute next_response =~ "payload"
      end

      test "an oversized response returns a structured error and retires the worker", %{
        pid: pooled_pid
      } do
        CNode.stop(pooled_pid)
        Process.flag(:trap_exit, true)
        {:ok, pid} = CNode.start_link(maude_path: @fake_maude, max_response_bytes: 64)
        ref = Process.monitor(pid)

        assert {:error, %ExMaude.Error{type: :response_too_large} = error} =
                 CNode.execute(pid, "oversized")

        assert error.details == %{max_response_bytes: 64}

        assert_receive {:DOWN, ^ref, :process, ^pid,
                        {:shutdown, {:bridge_failure, :response_too_large}}},
                       2_000
      end
    end

    describe "alive?/1" do
      test "returns true for running worker" do
        {:ok, pid} = CNode.start_link([])
        Process.sleep(2000)

        assert CNode.alive?(pid)
        CNode.stop(pid)
      end

      test "returns false for stopped worker" do
        {:ok, pid} = CNode.start_link([])
        Process.sleep(1000)
        CNode.stop(pid)
        Process.sleep(100)

        refute CNode.alive?(pid)
      end
    end

    describe "stop/1" do
      test "stops the worker gracefully" do
        {:ok, pid} = CNode.start_link([])
        Process.sleep(1000)

        assert :ok = CNode.stop(pid)
        Process.sleep(100)
        refute Process.alive?(pid)
      end
    end
  end

  @tag skip: not @cnode_available
  test "blocked writes respect the command timeout" do
    path = Path.expand("../../support/fake_blocked_input.sh", __DIR__)
    pid = start_supervised!({ExMaude.Backend.CNode, maude_path: path}, restart: :temporary)
    ref = Process.monitor(pid)

    assert {:error, %ExMaude.Error{type: :timeout}} =
             ExMaude.Backend.CNode.execute(pid, String.duplicate("x", 1_000_000), timeout: 50)

    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
  end
end
