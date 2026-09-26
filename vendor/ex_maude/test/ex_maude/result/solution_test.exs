defmodule ExMaude.Result.SolutionTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ExMaude.Result.Solution
  alias ExMaude.Term

  doctest ExMaude.Result.Solution

  describe "new/2" do
    test "creates solution with number" do
      solution = Solution.new(1)

      assert solution.number == 1
      assert solution.state_num == nil
      assert solution.term == nil
      assert solution.substitution == %{}
    end

    test "creates solution with state_num" do
      solution = Solution.new(1, state_num: 5)

      assert solution.state_num == 5
    end

    test "creates solution with term" do
      term = Term.new("active", "State")
      solution = Solution.new(1, term: term)

      assert solution.term == term
    end

    test "creates solution with substitution" do
      sub = %{"X:Nat" => "42", "Y:Bool" => "true"}
      solution = Solution.new(1, substitution: sub)

      assert solution.substitution == sub
    end

    test "creates solution with all options" do
      term = Term.new("done", "State")
      sub = %{"N" => "5"}
      solution = Solution.new(3, state_num: 10, term: term, substitution: sub)

      assert solution.number == 3
      assert solution.state_num == 10
      assert solution.term == term
      assert solution.substitution == sub
    end
  end

  describe "get_binding/2" do
    test "returns value for existing variable" do
      solution = Solution.new(1, substitution: %{"X:Nat" => "42"})

      assert Solution.get_binding(solution, "X:Nat") == "42"
    end

    test "returns nil for non-existing variable" do
      solution = Solution.new(1, substitution: %{"X:Nat" => "42"})

      assert Solution.get_binding(solution, "Y:Nat") == nil
    end

    test "returns nil for empty substitution" do
      solution = Solution.new(1)

      assert Solution.get_binding(solution, "X") == nil
    end

    test "handles multiple bindings" do
      sub = %{"A" => "1", "B" => "2", "C" => "3"}
      solution = Solution.new(1, substitution: sub)

      assert Solution.get_binding(solution, "A") == "1"
      assert Solution.get_binding(solution, "B") == "2"
      assert Solution.get_binding(solution, "C") == "3"
    end
  end

  describe "has_bindings?/1" do
    test "returns true when substitution has entries" do
      solution = Solution.new(1, substitution: %{"X" => "1"})

      assert Solution.has_bindings?(solution) == true
    end

    test "returns false when substitution is empty" do
      solution = Solution.new(1)

      assert Solution.has_bindings?(solution) == false
    end

    test "returns false when substitution is explicitly empty" do
      solution = Solution.new(1, substitution: %{})

      assert Solution.has_bindings?(solution) == false
    end

    test "returns true with multiple bindings" do
      solution = Solution.new(1, substitution: %{"A" => "1", "B" => "2"})

      assert Solution.has_bindings?(solution) == true
    end
  end

  describe "Inspect protocol" do
    test "formats solution with just number" do
      solution = Solution.new(1)
      inspected = inspect(solution)

      assert inspected == "#ExMaude.Result.Solution<#1>"
    end

    test "formats solution with state" do
      solution = Solution.new(2, state_num: 5)
      inspected = inspect(solution)

      assert inspected == "#ExMaude.Result.Solution<#2, state: 5>"
    end

    test "formats solution with bindings" do
      solution = Solution.new(1, substitution: %{"X" => "42"})
      inspected = inspect(solution)

      assert inspected == "#ExMaude.Result.Solution<#1, X = 42>"
    end

    test "formats solution with state and bindings" do
      solution = Solution.new(3, state_num: 10, substitution: %{"Y" => "true"})
      inspected = inspect(solution)

      assert inspected == "#ExMaude.Result.Solution<#3, state: 10, Y = true>"
    end

    test "formats solution with multiple bindings" do
      solution = Solution.new(1, substitution: %{"A" => "1", "B" => "2"})
      inspected = inspect(solution)

      # Order may vary, so check contains both
      assert String.contains?(inspected, "#1")
      assert String.contains?(inspected, "A = 1")
      assert String.contains?(inspected, "B = 2")
    end
  end
end
