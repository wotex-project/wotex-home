defmodule ExMaude.Result.Reduction do
  @moduledoc """
  Result of a Maude reduce operation.

  This struct is useful when an application has raw, verbose Maude output and
  wants the normalized term together with rewrite and timing statistics.
  `ExMaude.reduce/3` itself returns only the normalized term string.

  ## Maude Output Format

  The parser expects Maude's standard reduction output format:

      reduce in NAT : 1 + 2 + 3 .
      rewrites: 3 in 0ms cpu (0ms real) (~ rewrites/second)
      result Nat: 6

  ## Examples

      output = "rewrites: 3 in 1ms cpu (1ms real)\\nresult Nat: 6"
      {:ok, result} = ExMaude.Result.Reduction.parse(output)
      result.term.value
      # => "6"
      result.rewrites
      # => 3

      # Create manually
      term = ExMaude.Term.new("6", "Nat")
      result = ExMaude.Result.Reduction.new(term, rewrites: 3, time_ms: 1)

  """

  alias ExMaude.Term

  @enforce_keys [:term]
  defstruct [:term, :rewrites, :time_ms]

  @type t :: %__MODULE__{
          term: Term.t(),
          rewrites: non_neg_integer() | nil,
          time_ms: non_neg_integer() | nil
        }

  @doc """
  Creates a new Reduction result.

  ## Examples

      term = ExMaude.Term.new("6", "Nat")
      result = ExMaude.Result.Reduction.new(term, rewrites: 3, time_ms: 1)
  """

  @spec new(Term.t(), keyword()) :: t()
  def new(%Term{} = term, opts \\ []) do
    %__MODULE__{
      term: term,
      rewrites: Keyword.get(opts, :rewrites),
      time_ms: Keyword.get(opts, :time_ms)
    }
  end

  @doc """
  Parses Maude reduction output into a Reduction result.

  Extracts the term, rewrite count, and timing information from
  Maude's verbose output.
  """
  @spec parse(String.t(), String.t() | nil) :: {:ok, t()} | {:error, term()}
  def parse(output, module \\ nil) do
    with {:ok, term} <- Term.parse(output, module) do
      {:ok,
       %__MODULE__{
         term: term,
         rewrites: parse_rewrites(output),
         time_ms: parse_time(output)
       }}
    end
  end

  defp parse_rewrites(output) do
    case Regex.run(~r/rewrites:\s*(\d+)/, output) do
      [_, count] -> String.to_integer(count)
      nil -> nil
    end
  end

  defp parse_time(output) do
    case Regex.run(~r/in\s*(\d+)ms/, output) do
      [_, ms] -> String.to_integer(ms)
      nil -> nil
    end
  end

  defimpl Inspect do
    @spec inspect(ExMaude.Result.Reduction.t(), Inspect.Opts.t()) :: String.t()
    def inspect(
          %ExMaude.Result.Reduction{term: term, rewrites: rewrites, time_ms: time_ms},
          _
        ) do
      parts =
        [
          "term: #{term.value} : #{term.sort}",
          if(rewrites, do: "rewrites: #{rewrites}"),
          if(time_ms, do: "time: #{time_ms}ms")
        ]
        |> Enum.reject(&is_nil/1)

      "#ExMaude.Result.Reduction<#{Enum.join(parts, ", ")}>"
    end
  end
end
