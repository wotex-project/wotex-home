defmodule ExMaude.Backend.NIFIntegrationTest do
  @moduledoc false

  use ExMaude.NIFCase, async: false

  alias ExMaude.Backend.NIF
  alias ExMaude.Error

  @moduletag :nif
  @moduletag :integration
  @moduletag timeout: 60_000

  describe "struct" do
    test "has expected fields" do
      state = %NIF{}
      assert Map.has_key?(state, :handle)
      assert Map.has_key?(state, :maude_path)
      assert is_nil(state.handle)
      assert is_nil(state.maude_path)
    end
  end

  describe "start_link/1" do
    test "starts NIF worker successfully" do
      assert {:ok, pid} = NIF.start_link([])
      assert Process.alive?(pid)
      assert NIF.alive?(pid)

      NIF.stop(pid)
    end

    test "loads configured modules before returning" do
      path =
        Path.join(
          System.tmp_dir!(),
          "test_nif_preload_#{:erlang.unique_integer([:positive])}.maude"
        )

      File.write!(path, "fmod NIF-PRELOAD is sort Answer . op answer : -> Answer . endfm")
      on_exit(fn -> File.rm(path) end)

      assert {:ok, pid} = NIF.start_link(preload_modules: [path])
      assert {:ok, "answer"} = NIF.execute(pid, "reduce in NIF-PRELOAD : answer")

      NIF.stop(pid)
    end

    test "fails fast with invalid maude path" do
      Process.flag(:trap_exit, true)
      result = NIF.start_link(maude_path: "/nonexistent/maude")

      case result do
        {:error, _} ->
          :ok

        {:ok, pid} ->
          assert_receive {:EXIT, ^pid, _reason}, 5_000
      end
    end
  end

  describe "execute/3" do
    setup do
      {:ok, pid} = NIF.start_link([])
      on_exit(fn -> catch_exit(NIF.stop(pid)) end)
      {:ok, pid: pid}
    end

    test "executes simple reduce command", %{pid: pid} do
      assert {:ok, "6"} = NIF.execute(pid, "reduce in NAT : 1 + 2 + 3 .")
    end

    test "emits redacted command-start telemetry", %{pid: pid} do
      test_pid = self()
      handler = "nif-command-start-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:ex_maude, :server, :command_start],
        fn _, measurements, metadata, _ -> send(test_pid, {measurements, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      assert {:ok, "3"} = NIF.execute(pid, "reduce in NAT : 1 + 2")

      assert_receive {%{command_bytes: bytes}, %{backend: :nif} = metadata}
      assert bytes == byte_size("reduce in NAT : 1 + 2 .")
      refute Map.has_key?(metadata, :command)
    end

    test "handles multiple sequential commands", %{pid: pid} do
      for i <- 1..10 do
        assert {:ok, result} = NIF.execute(pid, "reduce in NAT : #{i} + #{i} .")
        assert result == "#{i * 2}"
      end
    end

    test "accepts commands without trailing period", %{pid: pid} do
      assert {:ok, "6"} = NIF.execute(pid, "reduce in NAT : 1 + 2 + 3")
    end

    test "the NIF surfaces a structured timeout when Maude doesn't respond" do
      # Feeding a command directly to the NIF without the trailing period
      # leaves Maude waiting for more input — the NIF timeout fires.
      maude = ExMaude.Binary.find()
      handle = ExMaude.Backend.NIF.Native.start(maude)
      on_exit(fn -> ExMaude.Backend.NIF.Native.stop(handle) end)

      start = System.monotonic_time(:millisecond)
      result = ExMaude.Backend.NIF.Native.execute_with_timeout(handle, "reduce in NAT : 1", 150)
      elapsed = System.monotonic_time(:millisecond) - start

      assert {:error, {:timeout, 150}} = result
      assert elapsed < 1_500
    end

    test "surfaces Maude errors as structured errors", %{pid: pid} do
      result = NIF.execute(pid, "reduce in NONEXISTENT-MOD : 1 + 1 .")
      assert {:error, %Error{}} = result
    end

    test "survives a malformed command and keeps the worker usable", %{pid: pid} do
      for _ <- 1..10 do
        assert {:error, %Error{type: :syntax_error}} = NIF.execute(pid, "@@@ garbage @@@ .")
        assert NIF.alive?(pid)
        assert {:ok, "6"} = NIF.execute(pid, "reduce in NAT : 1 + 2 + 3 .")
      end
    end
  end

  describe "load_file/2" do
    setup do
      {:ok, pid} = NIF.start_link([])
      on_exit(fn -> catch_exit(NIF.stop(pid)) end)
      {:ok, pid: pid}
    end

    test "loads a valid Maude file", %{pid: pid} do
      path =
        Path.join(System.tmp_dir!(), "test_nif_#{:erlang.unique_integer([:positive])}.maude")

      File.write!(path, "fmod TEST-NIF is sort Foo . endfm")
      on_exit(fn -> File.rm(path) end)

      assert :ok = NIF.load_file(pid, path)
    end

    test "loads a file whose path contains spaces", %{pid: pid} do
      path =
        Path.join(
          System.tmp_dir!(),
          "test nif #{:erlang.unique_integer([:positive])}.maude"
        )

      File.write!(path, "fmod TEST-NIF-SPACED-PATH is sort Foo . endfm")
      on_exit(fn -> File.rm(path) end)

      assert :ok = NIF.load_file(pid, path)
    end
  end

  describe "alive?/1" do
    test "returns true for running worker" do
      {:ok, pid} = NIF.start_link([])
      assert NIF.alive?(pid)
      NIF.stop(pid)
    end

    test "returns false for stopped worker" do
      {:ok, pid} = NIF.start_link([])
      NIF.stop(pid)
      Process.sleep(100)

      refute NIF.alive?(pid)
    end
  end

  describe "stop/1" do
    test "stops the worker gracefully" do
      {:ok, pid} = NIF.start_link([])
      assert :ok = NIF.stop(pid)
      Process.sleep(100)
      refute Process.alive?(pid)
    end

    test "spawning many workers and stopping them leaves no zombies" do
      before_count = maude_process_count()

      for _ <- 1..10 do
        {:ok, pid} = NIF.start_link([])
        NIF.stop(pid)
      end

      Process.sleep(200)

      after_count = maude_process_count()
      assert after_count <= before_count + 1
    end
  end

  defp maude_process_count do
    case System.cmd("pgrep", ["-c", "maude"], stderr_to_stdout: true) do
      {output, _} -> parse_count(String.trim(output))
    end
  rescue
    _ -> 0
  end

  defp parse_count(""), do: 0
  defp parse_count(str), do: String.to_integer(str)
end
