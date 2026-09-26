defmodule ExMaude.IoT.ReceiptRun do
  @moduledoc false

  alias ExMaude.Backend.Port
  alias ExMaude.{Binary, Error, Parser}
  alias ExMaude.IoT.ConflictParser
  alias ExMaude.Verification.Receipt

  @schema "0.1.0"
  @profile "bundled-iot-v1"
  @default_output_bytes 1_048_576
  @default_witness_bytes 16_384

  @doc false
  @spec start_clock() :: %{utc: DateTime.t(), monotonic_ms: integer()}
  def start_clock,
    do: %{utc: DateTime.utc_now(), monotonic_ms: System.monotonic_time(:millisecond)}

  @spec run(atom(), String.t(), map(), keyword(), map()) ::
          {:ok, Receipt.t()} | {:error, Error.t()}
  def run(operation, command, identities, opts, clock) do
    started = clock.utc
    start_ms = clock.monotonic_ms
    run_id = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

    with :ok <- validate_opts(operation, opts),
         {:ok, source} <- File.read(ExMaude.iot_rules_path()),
         {:ok, checker} <- checker_identity(),
         {:ok, encoder_digest} <- encoder_identity(),
         {:ok, library_digest} <- library_identity(),
         {:ok, directory, model_path, checker_path} <- snapshot(source, checker) do
      try do
        identity_sources = %{
          source: source,
          checker: checker,
          encoder_digest: encoder_digest,
          library_digest: library_digest
        }

        semantic = semantic(operation, command, identities, opts, identity_sources)

        remaining = remaining_ms(start_ms, opts)

        {result, worker_epoch, phases} =
          if remaining > 0 do
            execute(
              %{model_path: model_path, checker_path: checker_path},
              command,
              operation,
              remaining,
              opts
            )
          else
            {{:error, Error.timeout(Keyword.get(opts, :timeout, 30_000))}, nil,
             %{native: :not_started, parse: :not_run}}
          end

        model_observation = observed_model_digest(model_path, source, worker_epoch)
        checker_observation = observed_checker_digest(checker_path, checker, worker_epoch)
        result = enforce_identity(result, model_observation, checker_observation)
        provisional_witness = witness(operation, result, opts, semantic)
        result = enforce_deadline(result, start_ms, opts)
        completion = completion(result)
        findings = findings(operation, result)
        witness = if match?({:ok, _}, result), do: provisional_witness, else: nil

        execution = %{
          run_id: run_id,
          started_at: started,
          finished_at: DateTime.utc_now(),
          elapsed_ms: System.monotonic_time(:millisecond) - start_ms,
          worker_epoch: worker_epoch,
          observed_model_digest: model_observation,
          observed_checker_digest: checker_observation,
          effective_budgets: semantic.budgets,
          queue_disposition: :not_applicable,
          native_disposition: phases.native,
          parse_disposition: phases.parse,
          worker_disposition: if(remaining > 0, do: :retired, else: :not_started),
          disposition: disposition(result),
          completion: completion,
          findings: findings,
          witness: witness
        }

        {:ok, %Receipt{schema_version: @schema, semantic: semantic, execution: execution}}
      after
        File.rm_rf(directory)
      end
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, Error.new(:load_error, "Receipt preparation failed: #{inspect(reason)}")}
    end
  end

  defp validate_opts(operation, opts) do
    with :ok <- reject_pool(opts),
         :ok <- reject_unknown(operation, opts) do
      validate_limits(opts)
    end
  end

  defp reject_pool(opts) do
    if Keyword.has_key?(opts, :pool),
      do:
        {:error,
         Error.new(:validation, "receipt runs use an isolated Port worker; :pool is unsupported")},
      else: :ok
  end

  defp reject_unknown(operation, opts) do
    common = [:timeout, :max_response_bytes, :max_witness_bytes, :assumptions]

    allowed =
      if(operation == :conflicts,
        do: [:conflict_types | common],
        else: [:initial_state, :max_depth | common]
      )

    if Enum.any?(Keyword.keys(opts), &(&1 not in allowed)),
      do: {:error, Error.new(:validation, "unsupported receipt option or model semantics")},
      else: :ok
  end

  defp validate_limits(opts) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    output = Keyword.get(opts, :max_response_bytes, @default_output_bytes)
    witness = witness_limit(opts)
    assumptions = Keyword.get(opts, :assumptions, [])

    cond do
      not (is_integer(timeout) and timeout > 0) ->
        {:error, Error.new(:validation, "timeout must be a positive integer")}

      not (is_integer(output) and output in 1..2_147_483_000) ->
        {:error, Error.new(:validation, "max_response_bytes is invalid")}

      not (is_integer(witness) and witness > 0 and witness <= output) ->
        {:error, Error.new(:validation, "max_witness_bytes must fit within max_response_bytes")}

      true ->
        validate_assumptions(assumptions)
    end
  end

  defp validate_assumptions(assumptions) do
    if ExMaude.Validation.proper_list?(assumptions) and
         Enum.all?(assumptions, &is_binary/1),
       do: :ok,
       else: {:error, Error.new(:validation, "assumptions must be a list of strings")}
  end

  defp checker_identity do
    case Binary.find() do
      nil ->
        {:error, Error.new(:file_not_found, "Maude executable unavailable")}

      path ->
        path = Path.expand(path)
        prelude = Path.join(Path.dirname(path), "prelude.maude")

        with {:ok, executable} <- File.read(path),
             {:ok, prelude_source} <- File.read(prelude) do
          {:ok,
           %{
             executable: executable,
             prelude_source: prelude_source,
             digest: digest(executable),
             prelude_digest: digest(prelude_source)
           }}
        else
          {:error, reason} ->
            {:error,
             Error.new(:load_error, "Cannot pin Maude executable and prelude: #{inspect(reason)}")}
        end
    end
  end

  defp encoder_identity do
    Code.ensure_loaded!(ExMaude.IoT.Encoder)

    case File.read(:code.which(ExMaude.IoT.Encoder)) do
      {:ok, beam} ->
        {:ok, digest(beam)}

      {:error, reason} ->
        {:error, Error.new(:load_error, "Cannot pin encoder: #{inspect(reason)}")}
    end
  end

  defp library_identity do
    modules = [
      __MODULE__,
      ExMaude.IoT,
      ExMaude.Command,
      ExMaude.Parser,
      ExMaude.IoT.ConflictParser,
      ExMaude.Backend.Port
    ]

    Enum.reduce_while(modules, {:ok, []}, fn module, {:ok, hashes} ->
      Code.ensure_loaded!(module)

      case File.read(:code.which(module)) do
        {:ok, beam} ->
          {:cont, {:ok, [{module, digest(beam)} | hashes]}}

        {:error, reason} ->
          {:halt, {:error, Error.new(:load_error, "Cannot pin library: #{inspect(reason)}")}}
      end
    end)
    |> case do
      {:ok, hashes} -> {:ok, digest(:erlang.term_to_binary(Enum.reverse(hashes)))}
      error -> error
    end
  end

  defp snapshot(source, checker) do
    directory =
      Path.join(
        System.tmp_dir!(),
        "ex_maude_receipt_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      )

    with :ok <- File.mkdir(directory),
         :ok <- File.chmod(directory, 0o700),
         path = Path.join(directory, "iot-rules.maude"),
         :ok <- File.write(path, source, [:binary, :exclusive]),
         :ok <- File.chmod(path, 0o400),
         checker_path = Path.join(directory, "maude"),
         :ok <- File.write(checker_path, checker.executable, [:binary, :exclusive]),
         :ok <- File.chmod(checker_path, 0o500),
         prelude_path = Path.join(directory, "prelude.maude"),
         :ok <- File.write(prelude_path, checker.prelude_source, [:binary, :exclusive]),
         :ok <- File.chmod(prelude_path, 0o400) do
      {:ok, directory, path, checker_path}
    else
      {:error, reason} ->
        File.rm_rf(directory)
        {:error, Error.new(:load_error, "Cannot snapshot bundled model: #{inspect(reason)}")}
    end
  end

  defp semantic(operation, command, identities, opts, sources) do
    budgets = %{
      timeout_ms: Keyword.get(opts, :timeout, 30_000),
      max_depth: if(operation == :conflicts, do: nil, else: Keyword.get(opts, :max_depth, 50)),
      max_solutions: if(operation == :conflicts, do: nil, else: 1),
      max_response_bytes: Keyword.get(opts, :max_response_bytes, @default_output_bytes),
      max_witness_bytes: witness_limit(opts),
      os_memory_limit: :not_enforced
    }

    base = %{
      schema_version: @schema,
      profile: @profile,
      operation: operation,
      input_digest: digest(command),
      rule_digest:
        digest(:erlang.term_to_binary(Map.fetch!(identities, :rules), [:deterministic])),
      initial_state_digest: identity_digest(Map.get(identities, :initial_state)),
      target_digest: identity_digest(Map.get(identities, :target)),
      model_closure_digest:
        digest(:erlang.term_to_binary({digest(sources.source), sources.checker.prelude_digest})),
      encoder_digest: sources.encoder_digest,
      library_digest: sources.library_digest,
      checker_digest: sources.checker.digest,
      backend: :port,
      budgets: budgets,
      caller_assumptions: Enum.sort(Keyword.get(opts, :assumptions, [])),
      selection: Map.get(identities, :selection)
    }

    Map.put(base, :digest, digest(:erlang.term_to_binary(base, [:deterministic])))
  end

  defp identity_digest(nil), do: nil
  defp identity_digest(value), do: digest(:erlang.term_to_binary(value, [:deterministic]))

  defp execute(snapshot, command, operation, timeout, opts) do
    deadline = System.monotonic_time(:millisecond) + timeout

    task =
      Task.async(fn ->
        Process.flag(:trap_exit, true)
        startup = max(1, remaining_ms_from(deadline))

        try do
          case Port.start_link(
                 maude_path: snapshot.checker_path,
                 preload_modules: [snapshot.model_path],
                 isolated_preloads: true,
                 use_pty: false,
                 startup_timeout_ms: startup,
                 max_response_bytes: Keyword.get(opts, :max_response_bytes, @default_output_bytes)
               ) do
            {:ok, worker} ->
              epoch = %{
                pid: worker,
                nonce: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
              }

              try do
                remaining = remaining_ms_from(deadline)

                if remaining > 0 do
                  native = Port.execute(worker, command, timeout: remaining)
                  {result, phases} = parse_with_phases(operation, native, opts)
                  {result, epoch, phases}
                else
                  {{:error, Error.timeout(timeout)}, epoch,
                   %{native: :not_started, parse: :not_run}}
                end
              after
                stop_worker(worker)
              end

            {:error, reason} ->
              {{:error,
                start_failure(
                  reason,
                  timeout,
                  Keyword.get(opts, :max_response_bytes, @default_output_bytes)
                )}, nil, %{native: :not_started, parse: :not_run}}
          end
        rescue
          error ->
            {{:error,
              Error.new(:unknown, "Receipt execution failed: #{Exception.message(error)}")}, nil,
             %{native: :unknown, parse: :unknown}}
        catch
          kind, reason ->
            {{:error, Error.new(:unknown, "Receipt execution #{kind}: #{inspect(reason)}")}, nil,
             %{native: :unknown, parse: :unknown}}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        {{:error, Error.new(:unknown, "Receipt task exited: #{inspect(reason)}")}, nil,
         %{native: :unknown, parse: :unknown}}

      _ ->
        {{:error, Error.timeout(timeout)}, nil, %{native: :timeout, parse: :not_confirmed}}
    end
  end

  defp remaining_ms_from(deadline), do: max(0, deadline - System.monotonic_time(:millisecond))

  defp start_failure({:maude_start_failed, {:preload_failed, _, reason}}, timeout, limit),
    do: start_failure(reason, timeout, limit)

  defp start_failure({:maude_start_failed, reason}, timeout, limit),
    do: start_failure(reason, timeout, limit)

  defp start_failure(:response_too_large, _, limit), do: Error.response_too_large(limit)
  defp start_failure(:no_prompt, timeout, _), do: Error.timeout(timeout)
  defp start_failure(%Error{} = error, _, _), do: error

  defp start_failure(reason, _, _),
    do: Error.new(:load_error, "Isolated worker did not start: #{inspect(reason)}")

  defp stop_worker(worker) do
    if Process.alive?(worker), do: GenServer.stop(worker, :normal, 1_000)
  catch
    :exit, _ -> :ok
  end

  defp remaining_ms(start_ms, opts),
    do:
      max(
        0,
        Keyword.get(opts, :timeout, 30_000) - (System.monotonic_time(:millisecond) - start_ms)
      )

  defp parse_with_phases(operation, {:ok, _} = native, opts) do
    result = parse(operation, native, opts)
    parsing = if match?({:ok, _}, result), do: :completed, else: :error
    {result, %{native: :completed, parse: parsing}}
  end

  defp parse_with_phases(_, {:error, %Error{type: type}} = error, _),
    do: {error, %{native: type, parse: :not_run}}

  defp parse_with_phases(_, error, _), do: {error, %{native: :error, parse: :not_run}}

  defp parse(:conflicts, {:ok, output}, opts) do
    case ConflictParser.parse_result(output) do
      {:ok, conflicts} ->
        selected = Keyword.get(opts, :conflict_types)
        {:ok, if(selected, do: Enum.filter(conflicts, &(&1.type in selected)), else: conflicts)}

      error ->
        error
    end
  end

  defp parse(operation, {:ok, output}, _) when operation in [:safety, :deadlock] do
    cond do
      Regex.match?(~r/^No solution\.$/m, output) ->
        {:ok, []}

      Regex.match?(~r/^Solution \d+/m, output) ->
        case Parser.parse_search_results(output) do
          [_ | _] = solutions -> {:ok, solutions}
          [] -> {:error, Error.new(:parse_error, "Search solution could not be parsed")}
        end

      true ->
        {:error, Error.new(:parse_error, "Search completion could not be recognized")}
    end
  end

  defp parse(_, error, _), do: error

  defp completion({:ok, _}), do: :bounded_complete
  defp completion({:error, %Error{type: :timeout}}), do: :timeout
  defp completion({:error, %Error{type: :response_too_large}}), do: :output_overflow
  defp completion({:error, %Error{type: :parse_error}}), do: :malformed_result
  defp completion({:error, %Error{type: :file_not_found}}), do: :unavailable
  defp completion({:error, %Error{type: :load_error}}), do: :unavailable
  defp completion(_), do: :error

  defp disposition({:ok, _}), do: :completed
  defp disposition({:error, %Error{type: type}}), do: type
  defp disposition(_), do: :error

  defp findings(:conflicts, {:ok, items}), do: items

  defp findings(:safety, {:ok, items}),
    do: Enum.map(items, &%{kind: :reachable_bad_state, state_num: &1.state_num})

  defp findings(:deadlock, {:ok, items}),
    do: Enum.map(items, &%{kind: :terminal_state_missing_goal, state_num: &1.state_num})

  defp findings(_, _), do: []

  defp witness(operation, {:ok, [first | _]}, opts, semantic) do
    bytes = :erlang.term_to_binary(first, [:deterministic])
    scope = if(operation == :conflicts, do: :pairwise_conflict, else: :returned_solution)

    reference = %{
      scope: scope,
      digest: digest(bytes),
      semantic_digest: semantic.digest,
      model_closure_digest: semantic.model_closure_digest
    }

    if byte_size(bytes) <= witness_limit(opts) do
      Map.merge(reference, %{value: first, complete: true})
    else
      Map.merge(reference, %{value: nil, complete: false})
    end
  end

  defp witness(_, _, _, _), do: nil

  defp observed_model_digest(_, _, nil), do: nil

  defp observed_model_digest(model_path, source, _) do
    case File.read(model_path) do
      {:ok, ^source} -> digest(source)
      _ -> :identity_mismatch
    end
  end

  defp observed_checker_digest(_, _, nil), do: nil

  defp observed_checker_digest(checker_path, checker, _) do
    with {:ok, executable} <- File.read(checker_path),
         {:ok, prelude} <- File.read(Path.join(Path.dirname(checker_path), "prelude.maude")),
         true <- digest(executable) == checker.digest,
         true <- digest(prelude) == checker.prelude_digest do
      checker.digest
    else
      _ -> :identity_mismatch
    end
  end

  defp enforce_identity({:ok, _}, :identity_mismatch, _) do
    {:error, Error.new(:load_error, "Model snapshot changed during execution")}
  end

  defp enforce_identity({:ok, _}, _, :identity_mismatch) do
    {:error, Error.new(:load_error, "Checker snapshot changed during execution")}
  end

  defp enforce_identity(result, _, _), do: result

  defp enforce_deadline(result, start_ms, opts) do
    if remaining_ms(start_ms, opts) == 0 do
      {:error, Error.timeout(Keyword.get(opts, :timeout, 30_000))}
    else
      result
    end
  end

  defp witness_limit(opts) do
    output = Keyword.get(opts, :max_response_bytes, @default_output_bytes)

    default =
      if is_integer(output), do: min(@default_witness_bytes, output), else: @default_witness_bytes

    Keyword.get(opts, :max_witness_bytes, default)
  end

  defp digest(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
