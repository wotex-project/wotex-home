defmodule ExMaude.Telemetry do
  @moduledoc """
  Telemetry events for ExMaude.

  ExMaude uses the standard `:telemetry` library to emit events that can be
  consumed by monitoring tools, custom handlers, or exported to Prometheus,
  OpenTelemetry, and other observability platforms.

  ## Event Conventions

  All events follow standard conventions compatible with `telemetry_metrics`,
  Prometheus exporters, and OpenTelemetry:

  - **Measurements** are always numeric values (durations in native time units)
  - **Metadata** contains atoms for tags/labels (`:ok` or `:error`, not booleans)
  - **Event names** follow `[:app, :component, :action, :phase]` pattern

  ## Events

  ### Command Events

  Emitted for high-level Maude operations (`reduce`, `rewrite`, `search`,
  `execute`, `parse`, `load_file`, `ensure_file_loaded`, and `load_module`).

  `[:ex_maude, :command, :start]`
  - Measurements: `%{system_time: integer}`
  - Metadata: `%{operation: atom, module: String.t}`

  `[:ex_maude, :command, :stop]`
  - Measurements: `%{duration: integer}` (native time units)
  - Metadata: `%{operation: atom, module: String.t, result: :ok | :error}`

  `[:ex_maude, :command, :exception]`
  - Measurements: `%{duration: integer}`
  - Metadata: `%{operation: atom, module: String.t, kind: atom, reason: term}`

  ### Server (Worker) Events

  Emitted by the backend workers (Port, C-Node, NIF) around the lifecycle of
  each Maude OS process. All carry `%{system_time: integer}` plus the numeric
  measurements below, with metadata `%{pid: pid, backend: :port | :cnode | :nif}`.

  `[:ex_maude, :server, :start]`
  - Metadata also includes `%{maude_path: String.t}`
  - Emitted when a worker's Maude process is ready. Also fires when the pool
    replaces a worker after a timeout or crash.

  `[:ex_maude, :server, :command_start]`
  - Measurements: `%{command_bytes: integer}`
  - Metadata includes command text only when
    `config :ex_maude, telemetry_include_commands: true`; opted-in text is
    truncated to 100 characters. Commands may contain sensitive application
    data, so the secure default is `false`.

  `[:ex_maude, :server, :command_complete]`
  - Measurements: `%{response_size: integer}` when available
  - Metadata also includes `%{result: :ok | :error}`

  `[:ex_maude, :server, :timeout]`
  - Measurements: `%{timeout_ms: integer}` (Port also reports `buffer_size`)
  - A command timed out. The worker **stops** with `{:shutdown, _}` and the
    pool starts a replacement (Maude cannot cancel an in-flight computation,
    so the session is no longer trustworthy); expect a follow-up
    `[:ex_maude, :server, :start]` event.

  `[:ex_maude, :server, :crash]`
  - Measurements: `%{exit_status: integer}`
  - The Maude OS process exited unexpectedly.

  ### Pool Events

  Emitted for worker pool checkout operations.

  `[:ex_maude, :pool, :checkout, :start]`
  - Measurements: `%{system_time: integer}`
  - Metadata: `%{backend: :unknown, pool: pool_name}` (no worker is checked out yet)

  `[:ex_maude, :pool, :checkout, :stop]`
  - Measurements: `%{duration: integer}`
  - Metadata: `%{result: :ok | :error, backend: :port | :cnode | :nif | :unknown,
    pool: pool_name}` (`:unknown` when checkout failed)

  ### IoT Events

  Emitted for IoT conflict detection operations.

  `[:ex_maude, :iot, :detect_conflicts, :start]`
  - Measurements: `%{system_time: integer, rule_count: integer}`
  - Metadata: `%{template: :iot_rules}`

  `[:ex_maude, :iot, :detect_conflicts, :stop]`
  - Measurements: `%{duration: integer, conflict_count: integer}`
  - Metadata: `%{result: :ok | :error, template: :iot_rules}`

  ### AI Events

  Emitted for AI conflict detection operations. Mirrors the IoT envelope so
  handlers can dispatch on the `:template` metadata key.

  `[:ex_maude, :ai, :detect_conflicts, :start]`
  - Measurements: `%{system_time: integer, rule_count: integer}`
  - Metadata: `%{template: :ai_rules}`

  `[:ex_maude, :ai, :detect_conflicts, :stop]`
  - Measurements: `%{duration: integer, conflict_count: integer}`
  - Metadata: `%{result: :ok | :error, template: :ai_rules}`

  ## Attaching Handlers

  Attach a handler to receive telemetry events:

      :telemetry.attach(
        "my-app-ex-maude-handler",
        [:ex_maude, :command, :stop],
        fn event, measurements, metadata, config ->
          Logger.info("ExMaude command completed",
            operation: metadata.operation,
            duration_ms: System.convert_time_unit(measurements.duration, :native, :millisecond),
            result: metadata.result
          )
        end,
        nil
      )

  Or attach to multiple events:

      :telemetry.attach_many(
        "my-app-ex-maude-handlers",
        ExMaude.Telemetry.events(),
        &MyApp.Telemetry.handle_event/4,
        nil
      )

  ## Prometheus Integration

  Using `telemetry_metrics` in your consuming application:

      defp metrics do
        [
          counter("ex_maude.command.stop.count",
            tags: [:operation, :result],
            description: "Total Maude commands executed"
          ),
          distribution("ex_maude.command.stop.duration",
            unit: {:native, :millisecond},
            tags: [:operation, :result],
            description: "Maude command execution time"
          ),
          counter("ex_maude.pool.checkout.stop.count",
            tags: [:result],
            description: "Pool checkout operations"
          ),
          distribution("ex_maude.pool.checkout.stop.duration",
            unit: {:native, :millisecond},
            tags: [:result],
            description: "Pool checkout time"
          ),
          counter("ex_maude.iot.detect_conflicts.stop.count",
            tags: [:result],
            description: "IoT conflict detections"
          ),
          last_value("ex_maude.iot.detect_conflicts.stop.conflict_count",
            description: "Number of conflicts detected"
          )
        ]
      end

  ## OpenTelemetry Integration

  Using `opentelemetry_telemetry` in your consuming application:

      OpentelemetryTelemetry.attach_default_handlers()

  ## Converting Duration

  Durations are in native time units. Convert for display:

      duration_ms = System.convert_time_unit(duration, :native, :millisecond)
      duration_us = System.convert_time_unit(duration, :native, :microsecond)
  """

  @doc """
  Returns a list of all telemetry events emitted by ExMaude.

  Useful for attaching handlers to all events at once:

      :telemetry.attach_many(
        "my-handler",
        ExMaude.Telemetry.events(),
        &handle_event/4,
        nil
      )

  ## Examples

      iex> events = ExMaude.Telemetry.events()
      ...> [:ex_maude, :command, :stop] in events
      true
  """
  @dialyzer {:nowarn_function, events: 0}
  @spec events() :: [nonempty_list(atom())]
  def events do
    [
      [:ex_maude, :command, :start],
      [:ex_maude, :command, :stop],
      [:ex_maude, :command, :exception],
      [:ex_maude, :server, :start],
      [:ex_maude, :server, :command_start],
      [:ex_maude, :server, :command_complete],
      [:ex_maude, :server, :timeout],
      [:ex_maude, :server, :crash],
      [:ex_maude, :pool, :checkout, :start],
      [:ex_maude, :pool, :checkout, :stop],
      [:ex_maude, :iot, :detect_conflicts, :start],
      [:ex_maude, :iot, :detect_conflicts, :stop],
      [:ex_maude, :ai, :detect_conflicts, :start],
      [:ex_maude, :ai, :detect_conflicts, :stop]
    ]
  end

  @server_measurement_keys [
    :duration,
    :response_size,
    :command_bytes,
    :timeout_ms,
    :buffer_size,
    :exit_status
  ]

  @doc false
  @spec command_started(:port | :cnode | :nif, String.t()) :: :ok
  def command_started(backend, command) do
    attributes =
      if Application.get_env(:ex_maude, :telemetry_include_commands, false) do
        %{command_bytes: byte_size(command), command: truncate(command, 100)}
      else
        %{command_bytes: byte_size(command)}
      end

    server_event(:command_start, attributes, %{pid: self(), backend: backend})
  end

  @doc false
  @spec server_event(atom(), map(), map()) :: :ok
  def server_event(event, attributes, metadata)
      when is_atom(event) and is_map(attributes) and is_map(metadata) do
    {measurements, context} = Map.split(attributes, @server_measurement_keys)

    metadata =
      context
      |> normalize_server_context()
      |> Map.merge(metadata)

    :telemetry.execute(
      [:ex_maude, :server, event],
      Map.put(measurements, :system_time, System.system_time()),
      metadata
    )
  end

  defp normalize_server_context(%{success: success} = context) when is_boolean(success) do
    context
    |> Map.delete(:success)
    |> Map.put(:result, if(success, do: :ok, else: :error))
  end

  defp normalize_server_context(context), do: context

  defp truncate(command, max_characters) do
    if String.length(command) > max_characters,
      do: String.slice(command, 0, max_characters) <> "...",
      else: command
  end

  @doc """
  Executes a function and emits start/stop/exception telemetry events.

  This is used internally by ExMaude modules to instrument operations.
  Nonempty tuple results use their first element as the `:result` metadata value;
  all other results, including the empty tuple, are recorded as `:ok`. The
  callback's return value is preserved unchanged.

  ## Parameters

  - `event` - The event prefix (e.g., `[:ex_maude, :command]`)
  - `start_metadata` - Metadata to include in all events
  - `fun` - Function to execute

  ## Events Emitted

  - `event ++ [:start]` - Before function execution
  - `event ++ [:stop]` - After successful completion
  - `event ++ [:exception]` - If function raises or throws
  """
  @spec span([atom(), ...], map(), (-> result)) :: result when result: term()
  def span(event, start_metadata, fun) when is_list(event) and is_map(start_metadata) do
    # credo:disable-for-lines:3 Credo.Check.Refactor.AppendSingleItem
    start_event = event ++ [:start]
    stop_event = event ++ [:stop]
    exception_event = event ++ [:exception]

    start_time = System.monotonic_time()

    :telemetry.execute(
      start_event,
      %{system_time: System.system_time()},
      start_metadata
    )

    try do
      result = fun.()
      duration = System.monotonic_time() - start_time
      result_atom = if is_tuple(result) and tuple_size(result) > 0, do: elem(result, 0), else: :ok

      :telemetry.execute(
        stop_event,
        %{duration: duration},
        Map.put(start_metadata, :result, result_atom)
      )

      result
    rescue
      e ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          exception_event,
          %{duration: duration},
          Map.merge(start_metadata, %{kind: :error, reason: e})
        )

        reraise e, __STACKTRACE__
    catch
      kind, reason ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          exception_event,
          %{duration: duration},
          Map.merge(start_metadata, %{kind: kind, reason: reason})
        )

        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end
end
