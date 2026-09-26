defmodule ExMaude.Bench.SearchRun do
  @moduledoc """
  Correctness-gated smoke measurement for one isolated bounded search.

  Run with `mix bench.search_run`. `BENCH_BINARY`, `BENCH_SAMPLES` and
  `BENCH_OUTPUT_DIR` select the executable, sample count and output location.
  No latency threshold is asserted: the report retains observed durations.
  """

  alias ExMaude.Verification.SearchRun

  @model """
  mod BENCH-SEARCH is
    sort State .
    ops a b c : -> State [ctor] .
    rl [to-b] : a => b .
    rl [to-c] : b => c .
  endm
  """
  @query %{
    module: "BENCH-SEARCH",
    initial: "a",
    pattern: "c",
    max_depth: 5,
    max_solutions: 5
  }

  def run do
    path = System.get_env("BENCH_BINARY") || ExMaude.Binary.find()
    path || raise "Maude executable is required for search benchmark"
    samples = System.get_env("BENCH_SAMPLES", "5") |> String.to_integer()
    samples in 1..100 || raise "BENCH_SAMPLES must be between 1 and 100"

    preflight = checked_run(path)

    durations =
      for _ <- 1..samples do
        started = System.monotonic_time()
        receipt = checked_run(path)
        receipt.model_digest == preflight.model_digest || raise "model digest changed"
        receipt.query_digest == preflight.query_digest || raise "query digest changed"
        System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond)
      end

    report = %{
      schema: "ex_maude.search-run-benchmark.v1",
      captured_at_utc: DateTime.utc_now() |> DateTime.to_iso8601(),
      executable_digest: preflight.executable_digest,
      executable_version: preflight.executable_version,
      model_digest: preflight.model_digest,
      query_digest: preflight.query_digest,
      parser_version: preflight.parser_version,
      backend: "port",
      termination: "completed_declared_bound",
      solutions_observed: 1,
      states_explored: 3,
      sample_count: samples,
      durations_us: durations,
      median_us: median(durations),
      environment: %{
        os: :os.type() |> inspect(),
        elixir: System.version(),
        otp: :erlang.system_info(:otp_release) |> List.to_string(),
        schedulers: System.schedulers_online()
      }
    }

    directory = System.get_env("BENCH_OUTPUT_DIR", "bench/output")
    File.mkdir_p!(directory)
    output = Path.join(directory, "search_run.json")
    File.write!(output, Jason.encode!(report, pretty: true) <> "\n")
    IO.puts("SearchRun correctness passed; #{samples} samples retained at #{output}")
  end

  defp checked_run(path) do
    case SearchRun.run(@model, @query, maude_path: path) do
      {:ok,
       %{
         termination: :completed_declared_bound,
         solutions: [%{state_num: 2}],
         states_explored: 3,
         trace: %{state_num: 2, bytes: bytes, digest: digest}
       } = receipt} ->
        String.contains?(bytes, "state 0, State: a") || raise "initial state missing"
        String.contains?(bytes, "state 2, State: c") || raise "terminal state missing"
        digest == sha256(bytes) || raise "trace digest mismatch"
        receipt

      result ->
        raise "search benchmark correctness preflight failed: #{inspect(result)}"
    end
  end

  defp median(values) do
    sorted = Enum.sort(values)
    Enum.at(sorted, div(length(sorted), 2))
  end

  defp sha256(bytes),
    do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end

ExMaude.Bench.SearchRun.run()
