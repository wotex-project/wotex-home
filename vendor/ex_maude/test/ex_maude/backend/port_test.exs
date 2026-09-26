defmodule ExMaude.Backend.PortTest do
  @moduledoc false

  use ExMaude.MaudeCase

  alias ExMaude.Backend.Port

  describe "module structure" do
    test "implements Backend behaviour" do
      behaviours = Port.__info__(:attributes)[:behaviour] || []
      assert ExMaude.Backend in behaviours
    end

    test "is a GenServer" do
      assert function_exported?(Port, :init, 1)
      assert function_exported?(Port, :handle_call, 3)
      assert function_exported?(Port, :handle_info, 2)
      assert function_exported?(Port, :terminate, 2)
    end

    test "has correct struct fields" do
      state = %Port{}
      assert Map.has_key?(state, :port)
      assert Map.has_key?(state, :buffer)
      assert Map.has_key?(state, :pending)
      assert Map.has_key?(state, :maude_path)
      assert Map.has_key?(state, :os_pid)
    end
  end

  describe "start_link/1" do
    test "fails with non-existent maude path" do
      Process.flag(:trap_exit, true)

      result = Port.start_link(maude_path: "/nonexistent/maude/binary")

      case result do
        {:error, _} ->
          assert true

        {:ok, pid} ->
          assert_receive {:EXIT, ^pid, _reason}, 1000
      end
    end
  end

  describe "execute/3" do
    test "accepts timeout option" do
      assert function_exported?(Port, :execute, 3)
    end

    test "exits when server is not alive" do
      fake_pid = spawn(fn -> :ok end)
      Process.sleep(10)

      assert catch_exit(Port.execute(fake_pid, "test", timeout: 100))
    end
  end

  describe "load_file/2" do
    test "function exists with correct arity" do
      assert function_exported?(Port, :load_file, 2)
    end
  end

  describe "stop/1" do
    test "function exists with correct arity" do
      assert function_exported?(Port, :stop, 1)
    end
  end

  describe "integration tests" do
    @tag :integration
    test "starts and stops", %{maude_available: true} do
      {:ok, pid} = Port.start_link([])
      assert Process.alive?(pid)
      assert Port.alive?(pid)

      Port.stop(pid)
      Process.sleep(100)
      refute Process.alive?(pid)
    end

    @tag :integration
    test "executes reduce command", %{maude_available: true} do
      {:ok, pid} = Port.start_link([])

      {:ok, result} = Port.execute(pid, "reduce in NAT : 1 + 2 .")
      assert result == "3"

      Port.stop(pid)
    end

    @tag :integration
    test "executes multiple commands sequentially", %{maude_available: true} do
      {:ok, pid} = Port.start_link([])

      {:ok, r1} = Port.execute(pid, "reduce in NAT : 10 .")
      {:ok, r2} = Port.execute(pid, "reduce in NAT : 20 .")
      {:ok, r3} = Port.execute(pid, "reduce in BOOL : true and false .")

      assert r1 == "10"
      assert r2 == "20"
      assert r3 == "false"

      Port.stop(pid)
    end

    @tag :integration
    test "reports alive? correctly", %{maude_available: true} do
      {:ok, pid} = Port.start_link([])

      assert Port.alive?(pid) == true

      Port.stop(pid)
      Process.sleep(100)

      assert Port.alive?(pid) == false
    end

    @tag :integration
    test "handles syntax errors gracefully", %{maude_available: true} do
      {:ok, pid} = Port.start_link([])

      result = Port.execute(pid, "reduce in NAT : invalid$$syntax .")
      assert match?({:error, _}, result)

      Port.stop(pid)
    end

    @tag :integration
    test "handles load_file for non-existent file", %{maude_available: true} do
      {:ok, pid} = Port.start_link([])

      result = Port.load_file(pid, "/nonexistent/file.maude")
      assert match?({:error, _}, result)

      Port.stop(pid)
    end

    @tag :integration
    @tag :tmp_dir
    test "loads a file whose path contains spaces", %{maude_available: true, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "module with spaces.maude")
      File.write!(path, "fmod PORT-SPACED-PATH is sort Foo . endfm")
      {:ok, pid} = Port.start_link([])

      assert :ok = Port.load_file(pid, path)

      Port.stop(pid)
    end
  end

  describe "alive?/1 edge cases" do
    test "returns false for dead process" do
      pid = spawn(fn -> :ok end)
      Process.sleep(50)
      refute Port.alive?(pid)
    end

    test "returns false for non-existent pid" do
      pid = spawn(fn -> :ok end)
      Process.exit(pid, :kill)
      Process.sleep(10)
      refute Port.alive?(pid)
    end
  end

  describe "telemetry events" do
    @tag :integration
    test "emits start event", %{maude_available: true} do
      test_pid = self()

      :telemetry.attach(
        "test-port-start",
        [:ex_maude, :server, :start],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      {:ok, pid} = Port.start_link([])

      assert_receive {:telemetry, [:ex_maude, :server, :start], _, %{backend: :port}}, 5000

      Port.stop(pid)
      :telemetry.detach("test-port-start")
    end

    @tag :integration
    test "emits command_complete event", %{maude_available: true} do
      test_pid = self()

      :telemetry.attach(
        "test-port-command",
        [:ex_maude, :server, :command_complete],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      {:ok, pid} = Port.start_link([])
      Port.execute(pid, "reduce in NAT : 1 + 1 .")

      assert_receive {:telemetry, [:ex_maude, :server, :command_complete],
                      %{response_size: response_size, system_time: system_time},
                      %{backend: :port, result: :ok}},
                     5000

      assert is_integer(response_size)
      assert is_integer(system_time)

      Port.stop(pid)
      :telemetry.detach("test-port-command")
    end
  end
end
