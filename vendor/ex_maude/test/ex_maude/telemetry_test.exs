defmodule ExMaude.TelemetryTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias ExMaude.Telemetry

  doctest ExMaude.Telemetry

  describe "events/0" do
    test "returns list of all event names" do
      events = Telemetry.events()

      assert is_list(events)

      # All events should be lists of atoms
      for event <- events do
        assert is_list(event)
        assert Enum.all?(event, &is_atom/1)
      end
    end

    test "includes command events" do
      events = Telemetry.events()

      assert [:ex_maude, :command, :start] in events
      assert [:ex_maude, :command, :stop] in events
      assert [:ex_maude, :command, :exception] in events
    end

    test "includes pool events" do
      events = Telemetry.events()

      assert [:ex_maude, :pool, :checkout, :start] in events
      assert [:ex_maude, :pool, :checkout, :stop] in events
    end

    test "includes iot events" do
      events = Telemetry.events()

      assert [:ex_maude, :iot, :detect_conflicts, :start] in events
      assert [:ex_maude, :iot, :detect_conflicts, :stop] in events
    end
  end

  describe "span/3" do
    setup do
      test_pid = self()
      ref = make_ref()

      handler = fn event, measurements, metadata, {pid, r} ->
        send(pid, {r, event, measurements, metadata})
      end

      handler_id = "test-handler-#{inspect(ref)}"

      :telemetry.attach_many(
        handler_id,
        Telemetry.events(),
        handler,
        {test_pid, ref}
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, ref: ref}
    end

    test "emits start and stop events on success", %{ref: ref} do
      result =
        Telemetry.span([:ex_maude, :command], %{operation: :test, module: "TEST"}, fn ->
          {:ok, "result"}
        end)

      assert result == {:ok, "result"}

      assert_receive {^ref, [:ex_maude, :command, :start], start_measurements, start_metadata}
      assert is_integer(start_measurements.system_time)
      assert start_metadata.operation == :test
      assert start_metadata.module == "TEST"

      assert_receive {^ref, [:ex_maude, :command, :stop], stop_measurements, stop_metadata}
      assert is_integer(stop_measurements.duration)
      assert stop_measurements.duration > 0
      assert stop_metadata.result == :ok
      assert stop_metadata.operation == :test
      assert stop_metadata.module == "TEST"
    end

    test "emits start and stop events on error result", %{ref: ref} do
      result =
        Telemetry.span([:ex_maude, :command], %{operation: :fail_test}, fn ->
          {:error, :some_reason}
        end)

      assert result == {:error, :some_reason}

      assert_receive {^ref, [:ex_maude, :command, :start], _, _}

      assert_receive {^ref, [:ex_maude, :command, :stop], stop_measurements, stop_metadata}
      assert is_integer(stop_measurements.duration)
      assert stop_metadata.result == :error
    end

    test "emits exception event on raise", %{ref: ref} do
      assert_raise RuntimeError, "test error", fn ->
        Telemetry.span([:ex_maude, :command], %{operation: :raise_test}, fn ->
          raise "test error"
        end)
      end

      assert_receive {^ref, [:ex_maude, :command, :start], _, _}

      assert_receive {^ref, [:ex_maude, :command, :exception], exc_measurements, exc_metadata}
      assert is_integer(exc_measurements.duration)
      assert exc_metadata.kind == :error
      assert %RuntimeError{message: "test error"} = exc_metadata.reason
    end

    test "emits exception event on throw", %{ref: ref} do
      catch_throw(
        Telemetry.span([:ex_maude, :command], %{operation: :throw_test}, fn ->
          throw(:test_throw)
        end)
      )

      assert_receive {^ref, [:ex_maude, :command, :exception], exc_measurements, exc_metadata}
      assert is_integer(exc_measurements.duration)
      assert exc_metadata.kind == :throw
      assert exc_metadata.reason == :test_throw
    end

    test "emits exception event on exit", %{ref: ref} do
      catch_exit(
        Telemetry.span([:ex_maude, :command], %{operation: :exit_test}, fn ->
          exit(:test_exit)
        end)
      )

      assert_receive {^ref, [:ex_maude, :command, :exception], exc_measurements, exc_metadata}
      assert is_integer(exc_measurements.duration)
      assert exc_metadata.kind == :exit
      assert exc_metadata.reason == :test_exit
    end

    test "duration is in native time units", %{ref: ref} do
      Telemetry.span([:ex_maude, :command], %{operation: :duration_test}, fn ->
        Process.sleep(10)
        {:ok, :done}
      end)

      assert_receive {^ref, [:ex_maude, :command, :stop], %{duration: duration}, _}

      # Convert to milliseconds - should be at least 10ms
      ms = System.convert_time_unit(duration, :native, :millisecond)
      assert ms >= 10
    end

    test "preserves metadata through span", %{ref: ref} do
      metadata = %{operation: :meta_test, module: "MOD", custom_field: "custom_value"}

      Telemetry.span([:ex_maude, :command], metadata, fn ->
        {:ok, :result}
      end)

      assert_receive {^ref, [:ex_maude, :command, :start], _, start_meta}
      assert start_meta.custom_field == "custom_value"

      assert_receive {^ref, [:ex_maude, :command, :stop], _, stop_meta}
      assert stop_meta.custom_field == "custom_value"
      assert stop_meta.result == :ok
    end

    test "handles non-tuple results", %{ref: ref} do
      result =
        Telemetry.span([:ex_maude, :command], %{operation: :bare_result}, fn ->
          :bare_atom
        end)

      assert result == :bare_atom

      assert_receive {^ref, [:ex_maude, :command, :stop], _, stop_meta}
      # Non-tuple results should use :ok as the result atom
      assert stop_meta.result == :ok
    end

    test "preserves an empty tuple result without emitting an exception", %{ref: ref} do
      assert Telemetry.span([:ex_maude, :command], %{}, fn -> {} end) == {}
      assert_receive {^ref, [:ex_maude, :command, :stop], _, %{result: :ok}}
      refute_receive {^ref, [:ex_maude, :command, :exception], _, _}
    end
  end

  describe "Prometheus/OpenTelemetry compatibility" do
    test "server command telemetry redacts command text by default" do
      original = Application.get_env(:ex_maude, :telemetry_include_commands)
      Application.put_env(:ex_maude, :telemetry_include_commands, false)
      on_exit(fn -> restore_env(:telemetry_include_commands, original) end)

      handler_id = "server-redaction-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:ex_maude, :server, :command_start],
        fn _, measurements, metadata, _ -> send(test_pid, {measurements, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      Telemetry.command_started(:port, "reduce in SECRET : token .")

      assert_receive {%{command_bytes: 26}, metadata}
      assert metadata.backend == :port
      refute Map.has_key?(metadata, :command)
    end

    test "server command telemetry includes truncated text only when opted in" do
      original = Application.get_env(:ex_maude, :telemetry_include_commands)
      Application.put_env(:ex_maude, :telemetry_include_commands, true)
      on_exit(fn -> restore_env(:telemetry_include_commands, original) end)

      handler_id = "server-command-opt-in-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:ex_maude, :server, :command_start],
        fn _, measurements, metadata, _ -> send(test_pid, {measurements, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      command = String.duplicate("x", 101)
      Telemetry.command_started(:nif, command)

      assert_receive {%{command_bytes: 101}, %{command: redacted, backend: :nif}}
      assert redacted == String.duplicate("x", 100) <> "..."
    end

    test "server events keep contextual values out of measurements" do
      handler_id = "server-contract-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:ex_maude, :server, :command_complete],
        fn _, measurements, metadata, _ -> send(test_pid, {measurements, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Telemetry.server_event(
        :command_complete,
        %{success: true, response_size: 42, command: "reduce in NAT : 1 ."},
        %{backend: :port, pid: self()}
      )

      assert_receive {measurements, metadata}
      assert Enum.all?(measurements, fn {_, value} -> is_number(value) end)
      assert measurements.response_size == 42
      assert metadata.result == :ok
      assert metadata.command == "reduce in NAT : 1 ."
      refute Map.has_key?(measurements, :success)
      refute Map.has_key?(measurements, :command)
    end

    test "measurements use native time units" do
      start_time = System.monotonic_time()
      Process.sleep(1)
      duration = System.monotonic_time() - start_time

      assert is_integer(duration)
      assert System.convert_time_unit(duration, :native, :millisecond) >= 0
      assert System.convert_time_unit(duration, :native, :microsecond) >= 0
    end

    test "result metadata uses atoms not booleans" do
      # This is important for Prometheus label cardinality
      # :ok and :error are atoms, not true/false
      assert is_atom(:ok)
      assert is_atom(:error)
      refute is_boolean(:ok)
      refute is_boolean(:error)
    end

    test "event names follow :app :component :action pattern" do
      events = Telemetry.events()

      # Span events end in a phase; server worker events are point-in-time
      # lifecycle markers and end in the action itself.
      phases = [:start, :stop, :exception]
      lifecycle_actions = [:start, :command_start, :command_complete, :timeout, :crash]

      for event <- events do
        assert length(event) >= 3

        assert hd(event) == :ex_maude

        case event do
          [:ex_maude, :server, action] -> assert action in lifecycle_actions
          _ -> assert List.last(event) in phases
        end
      end
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:ex_maude, key)
  defp restore_env(key, value), do: Application.put_env(:ex_maude, key, value)

  describe "span/3 additional edge cases" do
    setup do
      test_pid = self()
      ref = make_ref()

      handler = fn event, measurements, metadata, {pid, r} ->
        send(pid, {r, event, measurements, metadata})
      end

      handler_id = "edge-case-handler-#{inspect(ref)}"

      :telemetry.attach_many(
        handler_id,
        Telemetry.events(),
        handler,
        {test_pid, ref}
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, ref: ref}
    end

    test "handles nested spans", %{ref: ref} do
      result =
        Telemetry.span([:ex_maude, :command], %{operation: :outer}, fn ->
          inner_result =
            Telemetry.span([:ex_maude, :command], %{operation: :inner}, fn ->
              {:ok, "inner_value"}
            end)

          {:ok, {:outer, inner_result}}
        end)

      assert {:ok, {:outer, {:ok, "inner_value"}}} = result

      assert_receive {^ref, [:ex_maude, :command, :start], _, %{operation: :outer}}
      assert_receive {^ref, [:ex_maude, :command, :start], _, %{operation: :inner}}
      assert_receive {^ref, [:ex_maude, :command, :stop], _, %{operation: :inner}}
      assert_receive {^ref, [:ex_maude, :command, :stop], _, %{operation: :outer}}
    end

    test "duration is always positive", %{ref: ref} do
      Telemetry.span([:ex_maude, :command], %{operation: :quick}, fn ->
        {:ok, :done}
      end)

      assert_receive {^ref, [:ex_maude, :command, :stop], %{duration: duration}, _}
      assert duration >= 0
    end

    test "handles complex metadata", %{ref: ref} do
      complex_metadata = %{
        operation: :complex,
        module: "TEST",
        nested: %{key: "value"},
        list: [1, 2, 3]
      }

      Telemetry.span([:ex_maude, :command], complex_metadata, fn ->
        {:ok, :result}
      end)

      assert_receive {^ref, [:ex_maude, :command, :start], _, meta}
      assert meta.nested == %{key: "value"}
      assert meta.list == [1, 2, 3]
    end
  end

  describe "events/0 additional tests" do
    test "returns the full list of public events" do
      events = Telemetry.events()
      assert length(events) == 14

      assert [:ex_maude, :ai, :detect_conflicts, :start] in events
      assert [:ex_maude, :ai, :detect_conflicts, :stop] in events
      assert [:ex_maude, :server, :timeout] in events
      assert [:ex_maude, :server, :crash] in events
    end

    test "all events are unique" do
      events = Telemetry.events()
      assert length(events) == length(Enum.uniq(events))
    end

    test "events can be attached without error" do
      events = Telemetry.events()
      handler_id = "test-attach-#{:erlang.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler_id,
        events,
        fn _, _, _, _ -> :ok end,
        nil
      )

      :telemetry.detach(handler_id)
    end
  end
end
