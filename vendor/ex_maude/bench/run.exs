defmodule ExMaude.Bench do
  @moduledoc """
  Measures parsing, Maude commands, pool overhead, and five-command concurrency.

  Run with `mix bench`. Reports are machine- and workload-specific; short Maude
  reductions may cost less than task scheduling, so parallelism is not assumed
  to improve throughput. `BENCH_TIME`, `BENCH_WARMUP`, `BENCH_MEMORY_TIME` (seconds),
  and `BENCH_OUTPUT_DIR` override measurement settings and the report location.
  """

  @doc """
  Runs the complete benchmark suite.

  Executes parser benchmarks unconditionally, then runs Maude integration
  benchmarks if Maude is available on the system.
  """
  def run do
    IO.puts("ExMaude Benchmark Suite")
    IO.puts("=======================")
    IO.puts("")

    parser_benchmarks()

    maude_path = ExMaude.Binary.find()

    if maude_path do
      IO.puts("Maude found at: " <> maude_path)

      {:ok, supervisor} =
        Supervisor.start_link([ExMaude.Pool.child_spec(maude_path: maude_path, use_pty: false)],
          strategy: :one_for_one
        )

      try do
        maude_benchmarks()
      after
        Supervisor.stop(supervisor)
      end
    else
      IO.puts("WARNING: Maude not found. Install with: mix maude.install")
    end

    write_index()
  end

  defp parser_benchmarks do
    IO.puts("")
    IO.puts("--- Parser Benchmarks ---")
    IO.puts("")

    search_output = """
    Solution 1 (state 5)
    S:State --> active

    Solution 2 (state 8)
    S:State --> inactive
    """

    reduce_output = "result Nat: 12345"

    module_list = """
    fmod BOOL
    fmod NAT
    mod MY-MOD
    """

    complex_term = "f(g(h(a, b)), j(k(e)))"

    Benchee.run(
      %{
        "parse_search_results" => fn -> ExMaude.Parser.parse_search_results(search_output) end,
        "parse_result" => fn -> {:ok, _, _} = ExMaude.Parser.parse_result(reduce_output) end,
        "parse_module_list" => fn -> ExMaude.Parser.parse_module_list(module_list) end,
        "parse_term" => fn -> ExMaude.Parser.parse_term(complex_term) end,
        "parse_errors" => fn -> ExMaude.Parser.parse_errors("result Nat: 42") end
      },
      warmup: seconds("BENCH_WARMUP", 2),
      time: seconds("BENCH_TIME", 5),
      memory_time: seconds("BENCH_MEMORY_TIME", 2),
      formatters: [
        Benchee.Formatters.Console,
        {Benchee.Formatters.Markdown,
         file: report_path("parser"),
         description: """
         # ExMaude Performance Benchmarks

         Run on #{DateTime.utc_now() |> DateTime.to_string()}.
         Values below measure this machine and process configuration.

         ## Parser Benchmarks (Pure Elixir, No Maude Required)
         """}
      ]
    )
  end

  defp maude_benchmarks do
    IO.puts("")
    IO.puts("--- Maude Reduce Benchmarks ---")
    IO.puts("")

    Benchee.run(
      %{
        "reduce simple" => fn -> {:ok, "2"} = ExMaude.reduce("NAT", "1 + 1") end,
        "reduce medium" => fn -> {:ok, "30240"} = ExMaude.reduce("NAT", "10 * 9 * 8 * 7 * 6") end,
        "reduce bool" => fn -> {:ok, "false"} = ExMaude.reduce("BOOL", "true and false") end
      },
      warmup: seconds("BENCH_WARMUP", 2),
      time: seconds("BENCH_TIME", 10),
      memory_time: seconds("BENCH_MEMORY_TIME", 2),
      formatters: [
        Benchee.Formatters.Console,
        {Benchee.Formatters.Markdown,
         file: report_path("reductions"),
         description: """
         ## Maude Reduce Benchmarks

         Full round-trip time for term reduction including IPC overhead.
         """}
      ]
    )

    IO.puts("")
    IO.puts("--- Pool Benchmarks ---")
    IO.puts("")

    Benchee.run(
      %{
        "pool transaction" => fn ->
          {:ok, "2"} =
            ExMaude.Pool.transaction(fn worker ->
              ExMaude.Server.execute(worker, "reduce in NAT : 1 + 1 .")
            end)
        end,
        "pool status" => fn -> ExMaude.Pool.status() end
      },
      warmup: seconds("BENCH_WARMUP", 2),
      time: seconds("BENCH_TIME", 5),
      formatters: [
        Benchee.Formatters.Console,
        {Benchee.Formatters.Markdown,
         file: report_path("pool"),
         description: """
         ## Pool Benchmarks

         Poolboy worker pool operation overhead.
         """}
      ]
    )

    IO.puts("")
    IO.puts("--- Concurrency Benchmarks ---")
    IO.puts("")

    Benchee.run(
      %{
        "sequential 5 reduces" => fn ->
          for _ <- 1..5, do: {:ok, "2"} = ExMaude.reduce("NAT", "1 + 1")
        end,
        "parallel 5 reduces" => fn ->
          1..5
          |> Task.async_stream(fn _ -> ExMaude.reduce("NAT", "1 + 1") end, max_concurrency: 4)
          |> Enum.each(fn {:ok, {:ok, "2"}} -> :ok end)
        end
      },
      warmup: seconds("BENCH_WARMUP", 2),
      time: seconds("BENCH_TIME", 10),
      formatters: [
        Benchee.Formatters.Console,
        {Benchee.Formatters.Markdown,
         file: report_path("concurrency"),
         description: """
         ## Concurrency Benchmarks

         Compares task scheduling and pool checkout overhead for five short reductions.
         Results depend on the workload, pool size, and available CPU cores.
         """}
      ]
    )
  end

  defp seconds(name, default), do: String.to_float(System.get_env(name, "#{default}.0"))

  defp report_path(name) do
    Path.join(System.get_env("BENCH_OUTPUT_DIR", "bench/output"), name <> ".md")
  end

  defp write_index do
    links =
      for name <- ["parser", "reductions", "pool", "concurrency"],
          File.exists?(report_path(name)) do
        "- [#{String.capitalize(name)}](#{name}.md)"
      end

    File.write!(
      report_path("benchmarks"),
      "# ExMaude benchmarks\n\nRun with `mix bench`. Each section has its own report.\n\n" <>
        Enum.join(links, "\n") <> "\n"
    )
  end
end

ExMaude.Bench.run()
