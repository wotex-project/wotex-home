defmodule ExMaude.Verification.SearchRunTest do
  use ExUnit.Case, async: false

  alias ExMaude.Verification.SearchRun

  @moduletag :integration

  @model """
  mod CONJUNCT-SEARCH is
    sort State .
    ops a b c : -> State [ctor] .
    rl [to-b] : a => b .
    rl [to-c] : a => c .
  endm
  """
  @depth_model """
  mod CONJUNCT-DEPTH is
    sort State .
    ops a b c : -> State [ctor] .
    rl [to-b] : a => b .
    rl [to-c] : b => c .
  endm
  """

  setup_all do
    assert path = ExMaude.Binary.find(), "selected Maude executable is required"
    {:ok, path: path}
  end

  test "distinguishes bounded completion, cutoff and a finite no-solution observation", %{
    path: path
  } do
    query = %{module: "CONJUNCT-SEARCH", initial: "a", pattern: "S:State", max_depth: 5}

    assert {:ok, cutoff} =
             SearchRun.run(@model, Map.put(query, :max_solutions, 1), maude_path: path)

    assert cutoff.termination == :solution_limit
    assert length(cutoff.solutions) == 1
    assert cutoff.trace.state_num == 0
    assert cutoff.trace.digest == digest(cutoff.trace.bytes)

    assert {:ok, complete} =
             SearchRun.run(@model, Map.put(query, :max_solutions, 5), maude_path: path)

    assert complete.termination == :completed_declared_bound
    assert length(complete.solutions) == 3
    assert complete.states_explored == 3
    assert complete.depth_probe.states_explored == 3
    assert complete.model_digest == cutoff.model_digest
    refute complete.query_digest == cutoff.query_digest
    refute complete.session_id == cutoff.session_id
    assert complete.raw_output_digest =~ ~r/^sha256:[0-9a-f]{64}$/

    assert {:ok, absent} =
             SearchRun.run(
               @model,
               query
               |> Map.put(:initial, "b")
               |> Map.put(:pattern, "c")
               |> Map.put(:max_solutions, 5),
               maude_path: path
             )

    assert absent.termination == :completed_declared_bound
    assert absent.solutions == []
    assert absent.trace == nil
    assert absent.depth_probe.states_explored == 1
  end

  test "a one-step frontier detects depth truncation without claiming no counterexample", %{
    path: path
  } do
    query = %{
      module: "CONJUNCT-DEPTH",
      initial: "a",
      pattern: "c",
      max_depth: 1,
      max_solutions: 3
    }

    assert {:ok, result} = SearchRun.run(@depth_model, query, maude_path: path)
    assert result.termination == :depth_truncation
    assert result.solutions == []
    assert result.states_explored == 2
    assert result.depth_probe.max_depth == 2
    assert result.depth_probe.states_explored == 3
    assert result.depth_probe.solutions_observed == 1
    assert result.depth_probe.raw_output_digest =~ ~r/^sha256:[0-9a-f]{64}$/
  end

  test "retrieves a nontrivial path inside the same isolated session", %{path: path} do
    query = %{
      module: "CONJUNCT-SEARCH",
      initial: "a",
      pattern: "c",
      max_depth: 5,
      max_solutions: 5
    }

    assert {:ok, result} = SearchRun.run(@model, query, maude_path: path)
    assert result.termination == :completed_declared_bound
    assert [%{state_num: 2}] = result.solutions
    assert result.trace.state_num == 2
    assert result.trace.bytes =~ "state 0, State: a"
    assert result.trace.bytes =~ "state 2, State: c"
    assert result.trace.digest == digest(result.trace.bytes)
  end

  test "emits bounded telemetry without model, query or path content", %{path: path} do
    event = [:ex_maude, :verification, :search_run, :stop]
    handler_id = "search-run-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn name, measurements, metadata, _ ->
          send(parent, {:search_telemetry, name, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    model = String.replace(@model, "CONJUNCT-SEARCH", "PRIVATE-MODEL-CANARY")

    query = %{
      module: "PRIVATE-MODEL-CANARY",
      initial: "a",
      pattern: "c",
      max_depth: 5,
      max_solutions: 5
    }

    assert {:ok, result} = SearchRun.run(model, query, maude_path: path)
    assert result.termination == :completed_declared_bound

    assert_receive {:search_telemetry, ^event, measurements, metadata}
    assert Map.keys(measurements) |> Enum.sort() == [:count, :duration, :solutions_observed]
    assert measurements.count == 1
    assert measurements.duration > 0
    assert measurements.solutions_observed == 1
    assert metadata == %{backend: :port, termination: :completed_declared_bound}
    refute inspect({measurements, metadata}) =~ "PRIVATE-MODEL-CANARY"
    refute inspect({measurements, metadata}) =~ path

    assert {:error, %ExMaude.Error{type: :validation}} =
             SearchRun.run(model, Map.put(query, :max_depth, 0), maude_path: path)

    assert_receive {:search_telemetry, ^event, %{count: 1, solutions_observed: 0},
                    %{backend: :port, termination: :validation_error}}
  end

  test "concurrent searches keep independent sessions and paths", %{path: path} do
    query = %{
      module: "CONJUNCT-SEARCH",
      initial: "a",
      pattern: "c",
      max_depth: 5,
      max_solutions: 5
    }

    receipts =
      1..6
      |> Task.async_stream(
        fn _ -> SearchRun.run(@model, query, maude_path: path) end,
        max_concurrency: 6,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, {:ok, receipt}} -> receipt end)

    assert length(Enum.uniq_by(receipts, & &1.session_id)) == 6
    assert length(Enum.uniq_by(receipts, & &1.query_digest)) == 1
    assert Enum.all?(receipts, &(&1.termination == :completed_declared_bound))
    assert Enum.all?(receipts, &(&1.trace.state_num == 2))
  end

  test "response overflow remains inconclusive", %{path: path} do
    query = %{
      module: "CONJUNCT-SEARCH",
      initial: "a",
      pattern: "S:State",
      max_depth: 5,
      max_solutions: 5
    }

    assert {:ok, result} =
             SearchRun.run(@model, query, maude_path: path, max_response_bytes: 256)

    assert result.termination == :output_truncation
    assert result.solutions == []
    assert result.raw_output_digest == nil
  end

  test "a backend parser refusal cannot become an empty completed search", %{path: path} do
    query = %{
      module: "MISSING-MODULE",
      initial: "a",
      pattern: "c",
      max_depth: 2,
      max_solutions: 2
    }

    assert {:ok, result} = SearchRun.run(@model, query, maude_path: path)
    assert result.termination == :parser_error
    assert result.solutions == []
    assert %ExMaude.Error{type: :module_not_found} = result.error
  end

  test "a delayed CLI response is a timeout, not an empty search" do
    path = fake_maude("sleep 2")
    assert {:ok, result} = SearchRun.run(@model, base_query(), maude_path: path, timeout: 500)
    assert result.termination == :timeout
    assert result.solutions == []
    assert result.raw_output_digest == nil
  end

  test "a lost CLI worker is distinct from parser refusal" do
    path = fake_maude("exit 7")
    assert {:ok, result} = SearchRun.run(@model, base_query(), maude_path: path)
    assert result.termination == :worker_loss
    assert result.solutions == []
  end

  test "force-stopping a caller retires its isolated OS worker" do
    pid_file =
      Path.join(System.tmp_dir!(), "ex_maude_search_pid_#{System.unique_integer([:positive])}")

    started = pid_file <> ".started"

    on_exit(fn ->
      File.rm(pid_file)
      File.rm(started)
    end)

    path = fake_maude("printf 'ready' > '#{started}'; exec sleep 20", pid_file)
    parent = self()

    {caller, monitor} =
      spawn_monitor(fn ->
        send(parent, {:search_result, SearchRun.run(@model, base_query(), maude_path: path)})
      end)

    assert eventually(fn -> File.exists?(started) end)
    os_pid = String.trim(File.read!(pid_file))
    assert {_, 0} = System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true)

    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}

    assert eventually(fn ->
             {_, status} = System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true)
             status != 0
           end)

    refute_receive {:search_result, _}
  end

  test "an unknown terminal marker cannot count as completed", %{path: _path} do
    path = fake_maude("printf '%s\\n\\nSearch stopped.\\nstates: 1\\nMaude> ' \"$line\"")
    assert {:ok, result} = SearchRun.run(@model, base_query(), maude_path: path)
    assert result.termination == :parser_error
    assert result.solutions == []
    assert result.raw_output_digest =~ ~r/^sha256:[0-9a-f]{64}$/
  end

  test "refuses invalid bounds before starting a worker", %{path: path} do
    assert {:error, %ExMaude.Error{type: :validation}} =
             SearchRun.run(
               @model,
               %{module: "CONJUNCT-SEARCH", initial: "a", pattern: "c", max_depth: 0},
               maude_path: path
             )

    assert {:error, %ExMaude.Error{type: :validation}} =
             SearchRun.run(
               @model,
               %{module: "CONJUNCT-SEARCH", initial: "a . show path 0", pattern: "c"},
               maude_path: path
             )
  end

  defp digest(bytes),
    do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp base_query do
    %{module: "CONJUNCT-SEARCH", initial: "a", pattern: "c", max_depth: 2, max_solutions: 2}
  end

  defp fake_maude(search_action, pid_file \\ nil) do
    path = Path.join(System.tmp_dir!(), "ex_maude_fake_#{System.unique_integer([:positive])}.sh")
    pid_line = if pid_file, do: "printf '%s' \"$$\" > '#{pid_file}'", else: ""

    File.write!(path, """
    #!/bin/sh
    if [ "$1" = "--version" ]; then printf 'fixture-maude 1\\n'; exit 0; fi
    #{pid_line}
    printf 'Maude> '
    while IFS= read -r line; do
      case "$line" in
        search*) #{search_action} ;;
        *) printf 'Maude> ' ;;
      esac
    done
    """)

    File.chmod!(path, 0o700)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp eventually(condition, attempts \\ 100)
  defp eventually(condition, 0), do: condition.()

  defp eventually(condition, attempts) do
    if condition.() do
      true
    else
      Process.sleep(10)
      eventually(condition, attempts - 1)
    end
  end
end
