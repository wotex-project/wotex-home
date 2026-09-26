defmodule ExMaude.ParserBench do
  @moduledoc """
  Parser-focused benchmark suite for ExMaude.

  This benchmark suite focuses exclusively on the `ExMaude.Parser` module,
  measuring the performance of converting Maude's text output into structured
  Elixir data. No Maude installation is required to run these benchmarks.

  ## Why Benchmark the Parser?

  The parser sits in the critical path of every Maude operation. When you call
  `ExMaude.reduce/3` or `ExMaude.search/4`, the results must be parsed before
  being returned to your application. Parser performance matters because:

    1. **High-frequency operations** - Applications performing many reductions
       (e.g., batch processing, validation loops) will parse thousands of results

    2. **Search result scaling** - Search operations can return many solutions,
       each requiring parsing of state numbers and substitution bindings

    3. **Memory efficiency** - Regex-based parsing can create intermediate strings;
       understanding memory allocation helps optimize for memory-constrained environments

    4. **Baseline comparison** - Knowing parser overhead helps distinguish between
       "Maude is slow" vs "our parsing is slow" when profiling

  ## Running This Benchmark

      mix run bench/parser_bench.exs

  ## Benchmark Categories

  ### Search Results Parsing

  Tests `ExMaude.Parser.parse_search_results/1` with varying result sizes:

    - **small (1 solution)** - Baseline single-solution parsing
    - **medium (3 solutions)** - Typical search result size
    - **large (20 solutions)** - Stress test with many solutions

  This reveals how parsing scales with result count. Linear scaling is expected;
  worse than linear indicates regex backtracking or inefficient list operations.

  ### Result Parsing

  Tests `ExMaude.Parser.parse_result/1` for reduce/rewrite output:

    - **simple result** - Basic `result Nat: 42` format
    - **complex result** - Nested term in result value

  This is the most frequently called parser function since every reduce/rewrite
  operation uses it. Should be extremely fast (sub-microsecond).

  ### Module List Parsing

  Tests `ExMaude.Parser.parse_module_list/1` for `show modules` output:

    - **small (2 modules)** - Minimal module list
    - **large (100 modules)** - Production-scale module count

  Module listing is less frequent but tests regex performance on repeated patterns.

  ### Term Parsing

  Tests `ExMaude.Parser.parse_term/1` for Maude term to Elixir AST conversion:

    - **simple term** - Single constructor `s(0)`
    - **nested term** - Multiple levels of nesting with siblings
    - **deep term (10 levels)** - Deep nesting stress test

  Term parsing uses recursive descent. Deep terms reveal stack usage patterns
  and potential optimization opportunities for tail-call elimination.

  ### Error Parsing

  Tests `ExMaude.Parser.parse_errors/1` for warning/error detection:

    - **clean output** - No errors (fast path)
    - **with warning** - Single warning to extract
    - **multiple errors** - Multiple warnings and errors

  Error parsing runs on every response to detect Maude errors. The "clean output"
  case should be highly optimized since it's the common path.

  ## Interpreting Results

  Expected performance characteristics:

    - All operations should be in microseconds (µs), not milliseconds
    - Memory allocation should scale linearly with input size
    - `parse_result` should be the fastest (simplest regex)
    - `parse_search_results` with large input tests regex engine efficiency

  If you see unexpectedly slow parsing:

    1. Check for regex catastrophic backtracking
    2. Consider using NimbleParsec for complex grammars
    3. Profile with `:fprof` to find hot spots
  """

  @doc """
  Runs all parser benchmarks.
  """
  def run do
    IO.puts("ExMaude Parser Benchmarks")
    IO.puts("=========================")
    IO.puts("")

    search_results_benchmarks()
    result_parsing_benchmarks()
    module_list_benchmarks()
    term_parsing_benchmarks()
    error_parsing_benchmarks()

    IO.puts("")
    IO.puts("Benchmark complete!")
  end

  defp search_results_benchmarks do
    small_search = """
    Solution 1 (state 5)
    S:State --> active
    """

    medium_search = """
    Solution 1 (state 5)
    S:State --> active
    X:Nat --> 42

    Solution 2 (state 8)
    S:State --> inactive
    X:Nat --> 0

    Solution 3 (state 12)
    S:State --> pending
    X:Nat --> 100
    """

    large_search =
      Enum.map_join(1..20, "\n\n", fn i ->
        """
        Solution #{i} (state #{i * 5})
        S:State --> state_#{i}
        X:Nat --> #{i * 100}
        Y:Bool --> #{rem(i, 2) == 0}
        """
      end)

    IO.puts("--- Search Results Parsing ---")
    IO.puts("")

    Benchee.run(
      %{
        "small (1 solution)" => fn -> ExMaude.Parser.parse_search_results(small_search) end,
        "medium (3 solutions)" => fn -> ExMaude.Parser.parse_search_results(medium_search) end,
        "large (20 solutions)" => fn -> ExMaude.Parser.parse_search_results(large_search) end
      },
      warmup: 2,
      time: 5,
      memory_time: 2,
      formatters: [Benchee.Formatters.Console]
    )
  end

  defp result_parsing_benchmarks do
    IO.puts("")
    IO.puts("--- Result Parsing ---")
    IO.puts("")

    Benchee.run(
      %{
        "simple result" => fn -> ExMaude.Parser.parse_result("result Nat: 42") end,
        "complex result" => fn -> ExMaude.Parser.parse_result("result MyType: complex(a, b, c)") end
      },
      warmup: 2,
      time: 5,
      memory_time: 2,
      formatters: [Benchee.Formatters.Console]
    )
  end

  defp module_list_benchmarks do
    small_module_list = """
    fmod BOOL
    fmod NAT
    """

    large_module_list =
      Enum.map_join(1..100, "\n", fn i ->
        "fmod MODULE_#{i}"
      end)

    IO.puts("")
    IO.puts("--- Module List Parsing ---")
    IO.puts("")

    Benchee.run(
      %{
        "small (2 modules)" => fn -> ExMaude.Parser.parse_module_list(small_module_list) end,
        "large (100 modules)" => fn -> ExMaude.Parser.parse_module_list(large_module_list) end
      },
      warmup: 2,
      time: 5,
      memory_time: 2,
      formatters: [Benchee.Formatters.Console]
    )
  end

  defp term_parsing_benchmarks do
    simple_term = "s(0)"
    nested_term = "f(g(h(a, b), i(c, d)), j(k(e), l(m(n, o))))"
    deep_term = Enum.reduce(1..10, "x", fn _, acc -> "f(" <> acc <> ")" end)

    IO.puts("")
    IO.puts("--- Term Parsing ---")
    IO.puts("")

    Benchee.run(
      %{
        "simple term" => fn -> ExMaude.Parser.parse_term(simple_term) end,
        "nested term" => fn -> ExMaude.Parser.parse_term(nested_term) end,
        "deep term (10 levels)" => fn -> ExMaude.Parser.parse_term(deep_term) end
      },
      warmup: 2,
      time: 5,
      memory_time: 2,
      formatters: [Benchee.Formatters.Console]
    )
  end

  defp error_parsing_benchmarks do
    clean_output = "result Nat: 42"

    warning_output = """
    Warning: something suspicious
    result Nat: 42
    """

    error_output = """
    Error: bad input
    Warning: also this
    Error: and this
    """

    IO.puts("")
    IO.puts("--- Error Parsing ---")
    IO.puts("")

    Benchee.run(
      %{
        "clean output" => fn -> ExMaude.Parser.parse_errors(clean_output) end,
        "with warning" => fn -> ExMaude.Parser.parse_errors(warning_output) end,
        "multiple errors" => fn -> ExMaude.Parser.parse_errors(error_output) end
      },
      warmup: 2,
      time: 5,
      memory_time: 2,
      formatters: [Benchee.Formatters.Console]
    )
  end
end

ExMaude.ParserBench.run()
