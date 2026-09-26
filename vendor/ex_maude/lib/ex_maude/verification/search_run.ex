defmodule ExMaude.Verification.SearchRun do
  @moduledoc """
  Runs one bounded Maude search in an isolated Port session.

  The caller supplies exact model bytes, a query and the executable path. The
  result distinguishes a completed declared bound from a solution cutoff and
  failures. A returned path is fetched before this run's worker is stopped;
  no state number or worker handle survives as a reusable trace capability.
  The result does not assert that a bounded model is finite or exhausted beyond
  its declared depth.
  """

  alias ExMaude.Backend.Port
  alias ExMaude.Command
  alias ExMaude.Error
  alias ExMaude.Parser
  alias ExMaude.Telemetry

  @parser_version "ex_maude.search-run.v1"
  @solution ~r/^Solution\s+(\d+)\s+\(state\s+(\d+)\)$/m
  @max_output 16_777_216
  @max_bound 1_000_000

  @type query :: %{
          required(:module) => String.t(),
          required(:initial) => String.t(),
          required(:pattern) => String.t(),
          optional(:max_depth) => pos_integer(),
          optional(:max_solutions) => pos_integer(),
          optional(:arrow) => String.t(),
          optional(:condition) => String.t()
        }

  @type termination ::
          :completed_declared_bound
          | :depth_truncation
          | :solution_limit
          | :timeout
          | :output_truncation
          | :worker_loss
          | :parser_error

  @type t :: %{
          model_digest: String.t(),
          query_digest: String.t(),
          executable_digest: String.t(),
          executable_version: String.t(),
          backend: :port,
          parser_version: String.t(),
          session_id: String.t(),
          limits: map(),
          termination: termination(),
          solutions: list(map()),
          states_explored: non_neg_integer() | nil,
          raw_output_digest: String.t() | nil,
          depth_probe: map() | nil,
          trace: map() | nil,
          error: term() | nil
        }

  @doc """
  Runs a bounded search and returns typed evidence even on command failure.

  Required `:maude_path` is an explicit executable path. `:timeout` and
  `:max_response_bytes` are per-command limits. The worker is retired on normal
  return. If the caller is force-stopped, a monitor retires the worker and its
  snapshot; the Port backend's OS guard stops the Maude process.
  A completed declared bound is not a finite-model proof. A second search at
  depth `N + 1` on the same worker reports `:depth_truncation` if it discovers
  more states or solutions. An unknown or malformed terminal marker yields
  `:parser_error`.
  """
  @spec run(binary(), query(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def run(model_source, query, opts) do
    started = System.monotonic_time()
    result = do_run(model_source, query, opts)
    Telemetry.search_run_completed(result, started)
    result
  end

  defp do_run(model_source, query, opts)
       when is_binary(model_source) and is_map(query) and is_list(opts) do
    with true <- Keyword.keyword?(opts),
         {:ok, inputs} <- validate(model_source, query, opts),
         {:ok, executable_digest} <- file_digest(inputs.maude_path),
         {:ok, executable_version} <- executable_version(inputs.maude_path, inputs.timeout),
         {:ok, directory, model_path} <- snapshot(model_source) do
      try do
        execute(model_source, inputs, executable_digest, executable_version, model_path)
      after
        File.rm_rf(directory)
      end
    else
      false -> invalid("options must be a keyword list")
      error -> error
    end
  end

  defp do_run(_, _, _),
    do: {:error, Error.new(:validation, "model and query must be bytes and a map")}

  defp validate(model_source, query, opts) do
    with :ok <- validate_model(model_source),
         :ok <- validate_options(opts),
         :ok <- validate_query(query) do
      depth = Map.get(query, :max_depth, 100)
      solutions = Map.get(query, :max_solutions, 1)

      command =
        Command.search(query.module, query.initial, query.pattern,
          max_depth: depth,
          max_solutions: solutions,
          arrow: Map.get(query, :arrow, "=>*"),
          condition: Map.get(query, :condition)
        )

      {:ok,
       %{
         maude_path: Keyword.fetch!(opts, :maude_path),
         timeout: Keyword.get(opts, :timeout, 30_000),
         output: Keyword.get(opts, :max_response_bytes, @max_output),
         depth: depth,
         max_solutions: solutions,
         command: command,
         query: query
       }}
    end
  end

  defp validate_model(source) do
    if source != "" and byte_size(source) <= @max_output,
      do: :ok,
      else: invalid("model bytes must be nonempty and at most 16 MiB")
  end

  defp validate_options(opts) do
    path = Keyword.get(opts, :maude_path)
    timeout = Keyword.get(opts, :timeout, 30_000)
    output = Keyword.get(opts, :max_response_bytes, @max_output)

    cond do
      Enum.any?(Keyword.keys(opts), &(&1 not in [:maude_path, :timeout, :max_response_bytes])) ->
        invalid("unsupported search option")

      not (is_binary(path) and File.regular?(path)) ->
        invalid("maude_path must name an existing executable")

      not (is_integer(timeout) and timeout in 1..300_000) ->
        invalid("timeout must be between 1 and 300000 ms")

      not (is_integer(output) and output in 1..@max_output) ->
        invalid("max_response_bytes is invalid")

      true ->
        :ok
    end
  end

  defp validate_query(query) do
    with :ok <- validate_query_shape(query) do
      validate_query_bounds(query)
    end
  end

  defp validate_query_shape(query) do
    cond do
      Enum.any?(
        Map.keys(query),
        &(&1 not in [:module, :initial, :pattern, :max_depth, :max_solutions, :arrow, :condition])
      ) ->
        invalid("unsupported query field")

      not Enum.all?([:module, :initial, :pattern], &present_text?(Map.get(query, &1))) ->
        invalid("module, initial and pattern are required")

      Map.has_key?(query, :condition) and not is_binary(query.condition) ->
        invalid("condition must be text")

      Enum.any?([:module, :initial, :pattern, :condition], &delimiter?(Map.get(query, &1))) ->
        invalid("query fields cannot contain command delimiters")

      true ->
        :ok
    end
  end

  defp validate_query_bounds(query) do
    depth = Map.get(query, :max_depth, 100)
    solutions = Map.get(query, :max_solutions, 1)
    arrow = Map.get(query, :arrow, "=>*")

    cond do
      not (is_integer(depth) and depth in 1..(@max_bound - 1) and is_integer(solutions) and
               solutions in 1..@max_bound) ->
        invalid("search depth must be below 1000000 and solution bound at most 1000000")

      arrow not in ["=>1", "=>+", "=>*", "=>!"] ->
        invalid("unsupported search arrow")

      true ->
        :ok
    end
  end

  defp present_text?(value), do: is_binary(value) and value != ""

  defp delimiter?(value),
    do: is_binary(value) and String.contains?(value, [".", "\n", "\r", <<0>>])

  defp invalid(message), do: {:error, Error.new(:validation, message)}

  defp snapshot(source) do
    directory =
      Path.join(
        System.tmp_dir!(),
        "ex_maude_search_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      )

    with :ok <- File.mkdir(directory),
         :ok <- File.chmod(directory, 0o700),
         path = Path.join(directory, "model.maude"),
         :ok <- File.write(path, source, [:binary, :exclusive]),
         :ok <- File.chmod(path, 0o400) do
      {:ok, directory, path}
    else
      {:error, reason} ->
        File.rm_rf(directory)
        {:error, Error.new(:load_error, "cannot snapshot search model: #{inspect(reason)}")}
    end
  end

  defp execute(source, inputs, executable_digest, executable_version, model_path) do
    session_id = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

    evidence = %{
      model_digest: digest(source),
      query_digest: digest(Command.normalize(inputs.command)),
      executable_digest: executable_digest,
      executable_version: executable_version,
      backend: :port,
      parser_version: @parser_version,
      session_id: session_id,
      limits: %{
        max_depth: inputs.depth,
        max_states: :unsupported,
        max_solutions: inputs.max_solutions,
        timeout_ms: inputs.timeout,
        max_response_bytes: inputs.output
      },
      termination: :worker_loss,
      solutions: [],
      states_explored: nil,
      raw_output_digest: nil,
      depth_probe: nil,
      trace: nil,
      error: nil
    }

    case Port.start_link(
           maude_path: inputs.maude_path,
           preload_modules: [model_path],
           isolated_preloads: true,
           startup_timeout_ms: inputs.timeout,
           max_response_bytes: inputs.output
         ) do
      {:ok, worker} ->
        Process.unlink(worker)
        watcher = watch_caller(self(), worker, Path.dirname(model_path))

        try do
          result =
            safe_call(fn -> Port.execute(worker, inputs.command, timeout: inputs.timeout) end)

          interpret(result, worker, inputs, evidence)
        after
          retire(worker)
          send(watcher, :owner_done)
        end

      {:error, reason} ->
        {:ok, %{evidence | termination: classify_start(reason), error: reason}}
    end
  end

  defp interpret({:ok, raw}, worker, inputs, evidence) do
    base = %{evidence | raw_output_digest: digest(raw)}

    case parse(raw, inputs) do
      {:ok, termination, solutions, states} ->
        case trace(worker, solutions, inputs) do
          {:ok, trace} ->
            observed = %{
              base
              | termination: termination,
                solutions: solutions,
                states_explored: states,
                trace: trace
            }

            maybe_probe(worker, inputs, observed)

          {:error, error} ->
            {:ok, %{base | termination: classify(error), error: error}}
        end

      {:error, reason} ->
        {:ok, %{base | termination: :parser_error, error: reason}}
    end
  end

  defp interpret({:error, error}, _, _, evidence),
    do: {:ok, %{evidence | termination: classify(error), error: error}}

  defp maybe_probe(_, _, %{termination: termination} = evidence)
       when termination != :completed_declared_bound,
       do: {:ok, evidence}

  defp maybe_probe(worker, inputs, evidence) do
    query = Map.put(inputs.query, :max_depth, inputs.depth + 1)

    command =
      Command.search(query.module, query.initial, query.pattern,
        max_depth: query.max_depth,
        max_solutions: inputs.max_solutions,
        arrow: Map.get(query, :arrow, "=>*"),
        condition: Map.get(query, :condition)
      )

    result = safe_call(fn -> Port.execute(worker, command, timeout: inputs.timeout) end)

    case result do
      {:ok, raw} -> probe_output(raw, command, inputs, evidence)
      {:error, error} -> {:ok, %{evidence | termination: classify(error), error: error}}
    end
  end

  defp probe_output(raw, command, inputs, evidence) do
    probe_inputs = %{inputs | command: command, max_solutions: inputs.max_solutions}

    case parse(raw, probe_inputs) do
      {:ok, completion, solutions, states} when states >= evidence.states_explored ->
        changed =
          states > evidence.states_explored or solutions != evidence.solutions or
            completion == :solution_limit

        probe = %{
          max_depth: inputs.depth + 1,
          raw_output_digest: digest(raw),
          states_explored: states,
          solutions_observed: length(solutions),
          completion: completion
        }

        termination = if changed, do: :depth_truncation, else: :completed_declared_bound
        {:ok, %{evidence | termination: termination, depth_probe: probe}}

      {:ok, _, _, _} ->
        {:ok, %{evidence | termination: :parser_error, error: :nonmonotonic_state_count}}

      {:error, reason} ->
        {:ok, %{evidence | termination: :parser_error, error: reason}}
    end
  end

  defp parse(raw, inputs) do
    parsed = Parser.parse_search_results(raw)
    headers = Regex.scan(@solution, raw)
    states = Regex.scan(~r/^states:\s*(\d+)/m, raw) |> List.last()
    terminal = terminal_marker(raw)

    with :ok <- check_echo(raw, inputs.command),
         :ok <- check_solutions(headers, parsed) do
      completion(terminal, parsed, states, inputs.max_solutions)
    end
  end

  defp check_echo(raw, command) do
    if String.starts_with?(raw, Command.normalize(command)),
      do: :ok,
      else: {:error, :missing_command_echo}
  end

  defp check_solutions(headers, parsed) do
    cond do
      length(headers) != length(parsed) ->
        {:error, :malformed_solution}

      Enum.any?(Enum.zip(headers, parsed), fn {[_, number, state], solution} ->
        solution.solution != String.to_integer(number) or
            solution.state_num != String.to_integer(state)
      end) ->
        {:error, :solution_mismatch}

      true ->
        :ok
    end
  end

  defp completion(terminal, parsed, states, max_solutions) do
    cond do
      terminal == "No solution." and parsed == [] and states != nil ->
        {:ok, :completed_declared_bound, parsed, state_count(states)}

      terminal == "No more solutions." and states != nil ->
        {:ok, :completed_declared_bound, parsed, state_count(states)}

      terminal == nil and length(parsed) == max_solutions and states != nil ->
        {:ok, :solution_limit, parsed, state_count(states)}

      true ->
        {:error, :unknown_terminal}
    end
  end

  defp state_count([_, count]), do: String.to_integer(count)

  defp terminal_marker(raw) do
    lines =
      raw
      |> String.trim_trailing()
      |> String.split("\n")

    case Enum.take(lines, -2) do
      [marker, "states: " <> _] when marker in ["No solution.", "No more solutions."] ->
        marker

      _ ->
        nil
    end
  end

  defp trace(_, [], _), do: {:ok, nil}

  defp trace(worker, [first | _], inputs) when is_integer(first.state_num) do
    result =
      safe_call(fn ->
        Port.execute(worker, "show path #{first.state_num}", timeout: inputs.timeout)
      end)

    case result do
      {:ok, raw} ->
        if String.contains?(raw, "state #{first.state_num},") do
          {:ok, %{state_num: first.state_num, bytes: raw, digest: digest(raw)}}
        else
          {:error, :missing_path_state}
        end

      error ->
        error
    end
  end

  defp trace(_, _, _), do: {:error, :missing_state_number}

  defp classify(%Error{type: :timeout}), do: :timeout
  defp classify(%Error{type: :response_too_large}), do: :output_truncation

  defp classify(%Error{type: type})
       when type in [:parse_error, :syntax_error, :module_not_found],
       do: :parser_error

  defp classify(:missing_path_state), do: :parser_error
  defp classify(:missing_state_number), do: :parser_error
  defp classify(_), do: :worker_loss

  defp classify_start({:maude_start_failed, {:preload_failed, _, %Error{} = error}}),
    do: classify(error)

  defp classify_start({:maude_start_failed, :no_prompt}), do: :timeout
  defp classify_start({:maude_start_failed, :response_too_large}), do: :output_truncation
  defp classify_start(_), do: :worker_loss

  defp retire(worker) do
    if Process.alive?(worker), do: Port.stop(worker)
  catch
    :exit, _ -> :ok
  end

  defp watch_caller(owner, worker, directory) do
    spawn(fn ->
      ref = Process.monitor(owner)

      receive do
        :owner_done ->
          Process.demonitor(ref, [:flush])

        {:DOWN, ^ref, :process, ^owner, _} ->
          if Process.alive?(worker), do: Process.exit(worker, :kill)
      end

      File.rm_rf(directory)
    end)
  end

  defp safe_call(call) do
    call.()
  catch
    :exit, reason -> {:error, Error.pool_error(reason)}
  end

  defp file_digest(path) do
    try do
      hash =
        path
        |> File.stream!(1_048_576, [])
        |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
        |> :crypto.hash_final()

      {:ok, "sha256:" <> Base.encode16(hash, case: :lower)}
    rescue
      error ->
        {:error,
         Error.new(:load_error, "cannot read Maude executable: #{Exception.message(error)}")}
    end
  end

  defp executable_version(path, timeout) do
    case ExMaude.Subprocess.run(path, ["--version"], min(timeout, 5_000), 65_536) do
      {:ok, output, 0} ->
        {:ok, String.trim(output)}

      {:error, :timeout} ->
        {:error, Error.timeout(min(timeout, 5_000))}

      {:error, :output_too_large} ->
        {:error, Error.response_too_large(65_536)}

      other ->
        {:error, Error.new(:load_error, "cannot identify Maude executable: #{inspect(other)}")}
    end
  end

  defp digest(bytes),
    do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
