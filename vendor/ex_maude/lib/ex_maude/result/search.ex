defmodule ExMaude.Result.Search do
  @moduledoc """
  Result of a Maude search operation.

  A search result contains all solutions found, along with statistics
  about the search process like states explored and execution time.

  ## Structure

    * `:solutions` - List of `ExMaude.Result.Solution` structs
    * `:states_explored` - Total number of states visited during search
    * `:time_ms` - Time taken in milliseconds

  ## Search Arrow Types

  Maude supports different search strategies via arrow operators:

  | Arrow | Description |
  |-------|-------------|
  | `=>1` | One-step rewriting (exactly one rule application) |
  | `=>+` | One or more steps (at least one rule application) |
  | `=>*` | Zero or more steps (default, includes initial state) |
  | `=>!` | Normal form (only states with no applicable rules) |

  ## Maude Output Format

  The parser handles Maude's search output format:

      search [1, 100] in MOD : init =>* goal .

      Solution 1 (state 5)
      states: 42  rewrites: 156 in 10ms cpu
      X:Nat --> 42
      Y:Bool --> true

      No more solutions.

  ## State Space Concepts

    * **State number** - Unique identifier for each state in the search graph
    * **Solution number** - 1-indexed order in which solutions were found
    * **Substitution** - Variable bindings that make the pattern match

  ## Examples

      {:ok, output} = ExMaude.execute("search [3] in MOD : init =>* goal .")
      {:ok, result} = ExMaude.Result.Search.parse(output)
      length(result.solutions)  #=> 3
      result.states_explored    #=> 42

      ExMaude.Result.Search.found?(result)  #=> true

      first = ExMaude.Result.Search.first(result)
      first.substitution["X:Nat"]  #=> "42"

  ## See Also

    * `ExMaude.Result.Solution` - Individual solution representation
    * `ExMaude.Maude.search/4` - To perform searches
    * `ExMaude.Result.Reduction` - For reduction results
  """

  alias ExMaude.Result.Solution

  defstruct [:states_explored, :time_ms, solutions: []]

  @type t :: %__MODULE__{
          solutions: [Solution.t()],
          states_explored: non_neg_integer() | nil,
          time_ms: non_neg_integer() | nil
        }

  @doc """
  Creates a new Search result.

  ## Examples

      solutions = [ExMaude.Result.Solution.new(1, state_num: 5)]
      result = ExMaude.Result.Search.new(solutions, states_explored: 10)
  """
  @spec new([Solution.t()], keyword()) :: t()
  def new(solutions, opts \\ []) when is_list(solutions) do
    %__MODULE__{
      solutions: solutions,
      states_explored: Keyword.get(opts, :states_explored),
      time_ms: Keyword.get(opts, :time_ms)
    }
  end

  @doc """
  Parses Maude search output into a Search result.

  Uses `ExMaude.Parser.parse_search_results/1` to extract solutions,
  then enriches with statistics.
  """
  @spec parse(String.t()) :: {:ok, t()}
  def parse(output) do
    raw_solutions = ExMaude.Parser.parse_search_results(output)

    solutions =
      Enum.map(raw_solutions, fn raw ->
        Solution.new(raw.solution,
          state_num: raw.state_num,
          substitution: raw.substitution
        )
      end)

    {:ok,
     %__MODULE__{
       solutions: solutions,
       states_explored: parse_states_explored(output),
       time_ms: parse_time(output)
     }}
  end

  @doc """
  Returns the number of solutions found.
  """
  @spec solution_count(t()) :: non_neg_integer()
  def solution_count(%__MODULE__{solutions: solutions}) do
    length(solutions)
  end

  @doc """
  Checks if any solutions were found.
  """
  @spec found?(t()) :: boolean()
  def found?(%__MODULE__{solutions: solutions}) do
    solutions != []
  end

  @doc """
  Returns the first solution, or nil if none found.
  """
  @spec first(t()) :: Solution.t() | nil
  def first(%__MODULE__{solutions: []}), do: nil
  def first(%__MODULE__{solutions: [first | _]}), do: first

  @doc """
  Returns all variable bindings from all solutions.

  Useful when you want to see all possible values for a variable
  across all solutions.

  ## Examples

      result = %ExMaude.Result.Search{solutions: [
        %Solution{substitution: %{"X" => "1"}},
        %Solution{substitution: %{"X" => "2"}}
      ]}
      ExMaude.Result.Search.all_bindings(result, "X")  #=> ["1", "2"]
  """
  @spec all_bindings(t(), String.t()) :: [String.t()]
  def all_bindings(%__MODULE__{solutions: solutions}, var_name) do
    solutions
    |> Enum.map(&Solution.get_binding(&1, var_name))
    |> Enum.reject(&is_nil/1)
  end

  defp parse_states_explored(output) do
    case Regex.scan(~r/^states:\s*(\d+)/m, output) |> List.last() do
      [_, count] -> String.to_integer(count)
      nil -> nil
    end
  end

  defp parse_time(output) do
    case Regex.scan(~r/\bin\s*(\d+)ms/, output) |> List.last() do
      [_, ms] -> String.to_integer(ms)
      nil -> nil
    end
  end

  defimpl Inspect do
    @spec inspect(ExMaude.Result.Search.t(), Inspect.Opts.t()) :: String.t()
    def inspect(
          %ExMaude.Result.Search{solutions: sols, states_explored: states, time_ms: time},
          _
        ) do
      parts =
        [
          "#{length(sols)} solution(s)",
          if(states, do: "states: #{states}"),
          if(time, do: "time: #{time}ms")
        ]
        |> Enum.reject(&is_nil/1)

      "#ExMaude.Result.Search<#{Enum.join(parts, ", ")}>"
    end
  end
end
