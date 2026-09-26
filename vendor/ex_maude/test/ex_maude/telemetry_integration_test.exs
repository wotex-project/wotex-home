defmodule ExMaude.TelemetryIntegrationTest do
  @moduledoc false

  use ExMaude.MaudeCase

  alias ExMaude.Telemetry

  describe "integration with ExMaude.Maude" do
    setup do
      test_pid = self()
      ref = make_ref()

      handler = fn event, measurements, metadata, {pid, r} ->
        send(pid, {r, event, measurements, metadata})
      end

      handler_id = "maude-test-handler-#{inspect(ref)}"

      :telemetry.attach_many(
        handler_id,
        Telemetry.events(),
        handler,
        {test_pid, ref}
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, ref: ref}
    end

    @tag :integration
    test "reduce emits command telemetry", %{ref: ref} do
      {:ok, _} = ExMaude.Maude.reduce("NAT", "1 + 1")

      assert_receive {^ref, [:ex_maude, :command, :start], %{system_time: _},
                      %{operation: :reduce, module: "NAT"}}

      assert_receive {^ref, [:ex_maude, :command, :stop], %{duration: duration},
                      %{operation: :reduce, module: "NAT", result: :ok}}

      assert duration > 0
    end

    @tag :integration
    test "rewrite emits command telemetry", %{ref: ref} do
      {:ok, _} = ExMaude.Maude.rewrite("NAT", "0", max_rewrites: 10)

      assert_receive {^ref, [:ex_maude, :command, :start], _,
                      %{operation: :rewrite, module: "NAT"}}

      assert_receive {^ref, [:ex_maude, :command, :stop], _, %{operation: :rewrite, result: :ok}}
    end

    @tag :integration
    test "search emits command telemetry", %{ref: ref} do
      {:ok, _} = ExMaude.Maude.search("NAT", "0", "N:Nat", max_solutions: 1, max_depth: 1)

      assert_receive {^ref, [:ex_maude, :command, :start], _,
                      %{operation: :search, module: "NAT"}}

      assert_receive {^ref, [:ex_maude, :command, :stop], _, %{operation: :search, result: :ok}}
    end

    @tag :integration
    test "execute emits command telemetry", %{ref: ref} do
      {:ok, _} = ExMaude.Maude.execute("reduce in NAT : 1 + 1 .")

      assert_receive {^ref, [:ex_maude, :command, :start], _,
                      %{operation: :execute, module: "raw"}}

      assert_receive {^ref, [:ex_maude, :command, :stop], _, %{operation: :execute, result: :ok}}
    end

    @tag :integration
    test "Port backend emits redacted server command telemetry", %{ref: ref} do
      command = "reduce in NAT : 1 + 1 ."
      {:ok, _} = ExMaude.Maude.execute(command)

      assert_receive {^ref, [:ex_maude, :server, :command_start],
                      %{command_bytes: command_bytes, system_time: _},
                      %{backend: :port} = metadata}

      assert command_bytes == byte_size(command <> "\n")
      refute Map.has_key?(metadata, :command)
    end

    @tag :integration
    test "parse emits command telemetry", %{ref: ref} do
      {:ok, _} = ExMaude.Maude.parse("NAT", "1 + 2")

      assert_receive {^ref, [:ex_maude, :command, :start], _, %{operation: :parse, module: "NAT"}}

      assert_receive {^ref, [:ex_maude, :command, :stop], _, %{operation: :parse, result: :ok}}
    end

    @tag :integration
    test "failed command emits error result", %{ref: ref} do
      {:error, _} = ExMaude.Maude.reduce("NONEXISTENT-MODULE", "1 + 1")

      assert_receive {^ref, [:ex_maude, :command, :stop], _,
                      %{operation: :reduce, result: :error}}
    end
  end

  describe "integration with ExMaude.Pool" do
    setup do
      test_pid = self()
      ref = make_ref()

      handler = fn event, measurements, metadata, {pid, r} ->
        send(pid, {r, event, measurements, metadata})
      end

      handler_id = "pool-test-handler-#{inspect(ref)}"

      :telemetry.attach_many(
        handler_id,
        Telemetry.events(),
        handler,
        {test_pid, ref}
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, ref: ref}
    end

    @tag :integration
    test "transaction emits pool checkout telemetry", %{ref: ref} do
      {:ok, _} = ExMaude.Maude.reduce("NAT", "1 + 1")

      assert_receive {^ref, [:ex_maude, :pool, :checkout, :start], %{system_time: sys_time}, %{}}
      assert is_integer(sys_time)

      assert_receive {^ref, [:ex_maude, :pool, :checkout, :stop], %{duration: duration},
                      %{result: :ok}}

      assert duration > 0
    end
  end
end
