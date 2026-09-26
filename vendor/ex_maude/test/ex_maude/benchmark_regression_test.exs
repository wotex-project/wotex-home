defmodule ExMaude.BenchmarkRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :benchmark
  @moduletag :tmp_dir
  @moduletag timeout: 120_000

  test "reports preserve every section and use the configured binary", %{tmp_dir: dir} do
    binary = Path.expand("../support/fake_benchmark_maude.sh", __DIR__)
    {output, status} = run_benchmark(binary, dir)
    assert status == 0, output
    assert output =~ "Maude found at: #{binary}"
    index = File.read!(Path.join(dir, "benchmarks.md"))

    for {section, scenario} <- [
          {"parser", "parse_search_results"},
          {"reductions", "reduce simple"},
          {"pool", "pool transaction"},
          {"concurrency", "parallel 5 reduces"}
        ] do
      assert index =~ "(#{section}.md)"
      assert File.read!(Path.join(dir, section <> ".md")) =~ scenario
    end
  end

  test "a successful transport carrying wrong results aborts measurement", %{tmp_dir: dir} do
    {output, status} = run_benchmark(Path.expand("../support/fake_maude.sh", __DIR__), dir)
    assert status != 0
    assert output =~ "MatchError"
  end

  test "bounded search benchmark retains correctness and timing evidence", %{tmp_dir: dir} do
    binary = ExMaude.Binary.find()
    assert binary, "selected Maude executable is required"

    {output, status} =
      System.cmd(System.find_executable("mix"), ["bench.search_run"],
        stderr_to_stdout: true,
        env: [
          {"MIX_ENV", "dev"},
          {"BENCH_BINARY", binary},
          {"BENCH_OUTPUT_DIR", dir},
          {"BENCH_SAMPLES", "3"}
        ]
      )

    assert status == 0, output

    report =
      dir
      |> Path.join("search_run.json")
      |> File.read!()
      |> Jason.decode!()

    assert report["schema"] == "ex_maude.search-run-benchmark.v1"
    assert report["termination"] == "completed_declared_bound"
    assert report["solutions_observed"] == 1
    assert report["states_explored"] == 3
    assert report["sample_count"] == 3
    assert length(report["durations_us"]) == 3
    assert Enum.all?(report["durations_us"], &(&1 > 0))
    assert report["model_digest"] =~ ~r/^sha256:[0-9a-f]{64}$/
    assert report["query_digest"] =~ ~r/^sha256:[0-9a-f]{64}$/
    assert report["executable_digest"] =~ ~r/^sha256:[0-9a-f]{64}$/
  end

  test "bounded search benchmark refuses plausible transport with wrong answers", %{tmp_dir: dir} do
    binary = Path.join(dir, "false-maude")

    File.write!(binary, """
    #!/bin/sh
    if [ "$1" = "--version" ]; then printf 'Maude 0.0\\n'; exit 0; fi
    printf 'Maude> '
    while IFS= read -r line; do
      printf 'result String: "wrong"\\nMaude> '
    done
    """)

    File.chmod!(binary, 0o755)

    {output, status} =
      System.cmd(System.find_executable("mix"), ["bench.search_run"],
        stderr_to_stdout: true,
        env: [
          {"MIX_ENV", "dev"},
          {"BENCH_BINARY", binary},
          {"BENCH_OUTPUT_DIR", dir},
          {"BENCH_SAMPLES", "3"}
        ]
      )

    assert status != 0
    assert output =~ "correctness preflight failed"
    refute File.exists?(Path.join(dir, "search_run.json"))
  end

  defp run_benchmark(binary, dir) do
    script =
      "Application.put_env(:ex_maude, :maude_path, System.fetch_env!(\"BENCH_BINARY\")); " <>
        "Code.require_file(\"bench/run.exs\")"

    System.cmd(System.find_executable("mix"), ["run", "-e", script],
      stderr_to_stdout: true,
      env: [
        {"MIX_ENV", "dev"},
        {"BENCH_BINARY", binary},
        {"BENCH_OUTPUT_DIR", dir},
        {"BENCH_TIME", "0.001"},
        {"BENCH_WARMUP", "0.0"},
        {"BENCH_MEMORY_TIME", "0.0"}
      ]
    )
  end
end
