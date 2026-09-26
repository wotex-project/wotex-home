defmodule ExMaude.Result.Solution do
  @moduledoc """
  A single solution from a Maude search operation.

  Each solution represents a state that matches the search pattern,
  along with the state number in the search graph and any variable
  substitutions that make the pattern match.

  ## Structure

    * `:number` - The solution number (1-indexed)
    * `:state_num` - The state number in the search graph
    * `:term` - The matching term (optional)
    * `:substitution` - Map of variable names to their bound values

  ## Variable Naming Conventions

  Maude variables include their sort in the name for disambiguation:

  | Variable | Description |
  |----------|-------------|
  | `X:Nat` | A natural number variable named X |
  | `S:State` | A state variable named S |
  | `L:List{Nat}` | A list of naturals variable named L |

  When accessing substitutions, use the full variable name including sort:

      solution.substitution["X:Nat"]  # Correct
      solution.substitution["X"]      # Won't match

  ## Substitution Format

  The substitution map contains variable bindings parsed from Maude output:

      Solution 1 (state 5)
      X:Nat --> 42
      Y:Bool --> true

  Becomes:

      %{"X:Nat" => "42", "Y:Bool" => "true"}

  ## Examples

      solution = %ExMaude.Result.Solution{
        number: 1,
        state_num: 5,
        substitution: %{"S:State" => "active"}
      }

      # Access bindings
      ExMaude.Result.Solution.get_binding(solution, "S:State")  #=> "active"

      # Check if has bindings
      ExMaude.Result.Solution.has_bindings?(solution)  #=> true

  ## See Also

    * `ExMaude.Result.Search` - Container for multiple solutions
    * `ExMaude.Maude.search/4` - To perform searches
  """

  alias ExMaude.Term

  @enforce_keys [:number]
  defstruct [:number, :state_num, :term, substitution: %{}]

  @type t :: %__MODULE__{
          number: pos_integer(),
          state_num: non_neg_integer() | nil,
          term: Term.t() | nil,
          substitution: %{String.t() => String.t()}
        }

  @doc """
  Creates a new Solution struct.

  ## Examples

      solution = ExMaude.Result.Solution.new(1, state_num: 5, substitution: %{"X" => "42"})
  """
  @spec new(pos_integer(), keyword()) :: t()
  def new(number, opts \\ []) when is_integer(number) and number > 0 do
    %__MODULE__{
      number: number,
      state_num: Keyword.get(opts, :state_num),
      term: Keyword.get(opts, :term),
      substitution: Keyword.get(opts, :substitution, %{})
    }
  end

  @doc """
  Gets a substitution value by variable name.

  ## Examples

      solution = ExMaude.Result.Solution.new(1, substitution: %{"X:Nat" => "42"})
      ExMaude.Result.Solution.get_binding(solution, "X:Nat")  #=> "42"
      ExMaude.Result.Solution.get_binding(solution, "Y:Nat")  #=> nil
  """
  @spec get_binding(t(), String.t()) :: String.t() | nil
  def get_binding(%__MODULE__{substitution: sub}, var_name) do
    Map.get(sub, var_name)
  end

  @doc """
  Checks if the solution has any variable bindings.
  """
  @spec has_bindings?(t()) :: boolean()
  def has_bindings?(%__MODULE__{substitution: sub}) do
    map_size(sub) > 0
  end

  defimpl Inspect do
    @spec inspect(ExMaude.Result.Solution.t(), Inspect.Opts.t()) :: String.t()
    def inspect(%ExMaude.Result.Solution{number: num, state_num: state, substitution: sub}, _) do
      bindings = Enum.map_join(sub, ", ", fn {k, v} -> "#{k} = #{v}" end)

      parts =
        [
          "##{num}",
          if(state, do: "state: #{state}"),
          if(bindings != "", do: bindings)
        ]
        |> Enum.reject(&is_nil/1)

      "#ExMaude.Result.Solution<#{Enum.join(parts, ", ")}>"
    end
  end
end
