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
