defmodule ExMaude.Result.SearchTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ExMaude.Result.{Search, Solution}

  doctest ExMaude.Result.Search

  describe "new/2" do
    test "creates search with empty solutions" do
      result = Search.new([])

      assert result.solutions == []
      assert result.states_explored == nil
      assert result.time_ms == nil
    end

    test "creates search with solutions" do
      solutions = [Solution.new(1), Solution.new(2)]
      result = Search.new(solutions)

      assert result.solutions == solutions
    end

    test "creates search with states_explored" do
      result = Search.new([], states_explored: 42)

      assert result.states_explored == 42
    end

    test "creates search with time_ms" do
      result = Search.new([], time_ms: 100)

      assert result.time_ms == 100
    end

    test "creates search with all options" do
      solutions = [Solution.new(1, state_num: 5)]
      result = Search.new(solutions, states_explored: 10, time_ms: 50)

      assert length(result.solutions) == 1
      assert result.states_explored == 10
      assert result.time_ms == 50
    end
  end

  describe "parse/1" do
    test "parses search with no solutions" do
      output = """
      search in MY-MOD : init =>* goal .
      No solution.
      states: 5
      """

      {:ok, result} = Search.parse(output)

      assert result.solutions == []
    end

    test "parses search with single solution" do
      output = """
      search in MY-MOD : init =>* X:State .
      Solution 1 (state 3)
      X:State --> active
      """

      {:ok, result} = Search.parse(output)

      assert length(result.solutions) == 1
      [sol] = result.solutions
      assert sol.number == 1
      assert sol.state_num == 3
      assert sol.substitution == %{"X:State" => "active"}
    end

    test "parses search with multiple solutions" do
      output = """
      search in MY-MOD : init =>* X:Nat .
      Solution 1 (state 2)
      X:Nat --> 1

      Solution 2 (state 4)
      X:Nat --> 2

      Solution 3 (state 6)
      X:Nat --> 3
      """

      {:ok, result} = Search.parse(output)

      assert length(result.solutions) == 3
      assert Enum.map(result.solutions, & &1.number) == [1, 2, 3]
    end

    test "parses search with states explored" do
      output = """
      search in MOD : init =>* goal .
      Solution 1 (state 5)
      states: 10
      """

      {:ok, result} = Search.parse(output)

      assert result.states_explored == 10
    end

    test "parses search with timing" do
      output = """
      search in MOD : init =>* goal .
      Solution 1 (state 1)
      in 25ms cpu
      """

      {:ok, result} = Search.parse(output)

      assert result.time_ms == 25
    end

    test "parses search with multiple substitutions" do
      output = """
      Solution 1 (state 5)
      X:Nat --> 42
      Y:Bool --> true
      Z:String --> "hello"
      """

      {:ok, result} = Search.parse(output)

      [sol] = result.solutions
      assert sol.substitution["X:Nat"] == "42"
      assert sol.substitution["Y:Bool"] == "true"
      assert sol.substitution["Z:String"] == "\"hello\""
    end
  end

  describe "solution_count/1" do
    test "returns 0 for empty solutions" do
      result = Search.new([])

      assert Search.solution_count(result) == 0
    end

    test "returns count for single solution" do
      result = Search.new([Solution.new(1)])

      assert Search.solution_count(result) == 1
    end

    test "returns count for multiple solutions" do
      solutions = [Solution.new(1), Solution.new(2), Solution.new(3)]
      result = Search.new(solutions)

      assert Search.solution_count(result) == 3
    end
  end

  describe "found?/1" do
    test "returns false for no solutions" do
      result = Search.new([])

      assert Search.found?(result) == false
    end

    test "returns true for one solution" do
      result = Search.new([Solution.new(1)])

      assert Search.found?(result) == true
    end

    test "returns true for multiple solutions" do
      result = Search.new([Solution.new(1), Solution.new(2)])

      assert Search.found?(result) == true
    end
  end

  describe "first/1" do
    test "returns nil for no solutions" do
      result = Search.new([])

      assert Search.first(result) == nil
    end

    test "returns first solution" do
      sol1 = Solution.new(1, state_num: 5)
      sol2 = Solution.new(2, state_num: 10)
      result = Search.new([sol1, sol2])

      assert Search.first(result) == sol1
    end
  end

  describe "all_bindings/2" do
    test "returns empty list for no solutions" do
      result = Search.new([])

      assert Search.all_bindings(result, "X") == []
    end

    test "returns empty list when variable not found" do
      solutions = [
        Solution.new(1, substitution: %{"Y" => "1"})
      ]

      result = Search.new(solutions)

      assert Search.all_bindings(result, "X") == []
    end

    test "returns all values for variable" do
      solutions = [
        Solution.new(1, substitution: %{"X" => "1"}),
        Solution.new(2, substitution: %{"X" => "2"}),
        Solution.new(3, substitution: %{"X" => "3"})
      ]

      result = Search.new(solutions)

      assert Search.all_bindings(result, "X") == ["1", "2", "3"]
    end

    test "filters out solutions without the variable" do
      solutions = [
        Solution.new(1, substitution: %{"X" => "1"}),
        Solution.new(2, substitution: %{"Y" => "2"}),
        Solution.new(3, substitution: %{"X" => "3"})
      ]

      result = Search.new(solutions)

      assert Search.all_bindings(result, "X") == ["1", "3"]
    end
  end

  describe "Inspect protocol" do
    test "formats search with no solutions" do
      result = Search.new([])
      inspected = inspect(result)

      assert inspected == "#ExMaude.Result.Search<0 solution(s)>"
    end

    test "formats search with solutions" do
      result = Search.new([Solution.new(1), Solution.new(2)])
      inspected = inspect(result)

      assert inspected == "#ExMaude.Result.Search<2 solution(s)>"
    end

    test "formats search with states" do
      result = Search.new([], states_explored: 42)
      inspected = inspect(result)

      assert inspected == "#ExMaude.Result.Search<0 solution(s), states: 42>"
    end

    test "formats search with time" do
      result = Search.new([], time_ms: 100)
      inspected = inspect(result)

      assert inspected == "#ExMaude.Result.Search<0 solution(s), time: 100ms>"
    end

    test "formats search with all stats" do
      result = Search.new([Solution.new(1)], states_explored: 10, time_ms: 50)
      inspected = inspect(result)

      assert inspected == "#ExMaude.Result.Search<1 solution(s), states: 10, time: 50ms>"
    end
  end

  test "statistics describe the final search progress" do
    output =
      "Solution 1 (state 1)\nstates: 2 rewrites: 3 in 1ms cpu\nSolution 2 (state 5)\nstates: 6 rewrites: 8 in 4ms cpu\n"

    assert {:ok, %{states_explored: 6, time_ms: 4}} = ExMaude.Result.Search.parse(output)
  end
end
