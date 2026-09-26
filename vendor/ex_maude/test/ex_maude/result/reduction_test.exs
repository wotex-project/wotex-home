defmodule ExMaude.Result.ReductionTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ExMaude.Result.Reduction
  alias ExMaude.Term

  doctest ExMaude.Result.Reduction

  describe "new/2" do
    test "creates reduction with term" do
      term = Term.new("6", "Nat")
      result = Reduction.new(term)

      assert result.term == term
      assert result.rewrites == nil
      assert result.time_ms == nil
    end

    test "creates reduction with rewrites option" do
      term = Term.new("6", "Nat")
      result = Reduction.new(term, rewrites: 3)

      assert result.rewrites == 3
    end

    test "creates reduction with time_ms option" do
      term = Term.new("6", "Nat")
      result = Reduction.new(term, time_ms: 5)

      assert result.time_ms == 5
    end

    test "creates reduction with all options" do
      term = Term.new("42", "Nat")
      result = Reduction.new(term, rewrites: 10, time_ms: 2)

      assert result.term.value == "42"
      assert result.rewrites == 10
      assert result.time_ms == 2
    end
  end

  describe "parse/2" do
    test "parses simple reduction output" do
      output = "result Nat: 6"
      {:ok, result} = Reduction.parse(output)

      assert result.term.value == "6"
      assert result.term.sort == "Nat"
    end

    test "parses reduction with rewrites" do
      output = """
      reduce in NAT : 1 + 2 + 3 .
      rewrites: 3 in 0ms cpu (0ms real) (~ rewrites/second)
      result Nat: 6
      """

      {:ok, result} = Reduction.parse(output)

      assert result.term.value == "6"
      assert result.rewrites == 3
    end

    test "parses reduction with timing" do
      output = """
      reduce in NAT : 1 + 2 .
      rewrites: 1 in 5ms cpu (5ms real) (200 rewrites/second)
      result Nat: 3
      """

      {:ok, result} = Reduction.parse(output)

      assert result.time_ms == 5
    end

    test "parses reduction with module" do
      output = "result Bool: true"
      {:ok, result} = Reduction.parse(output, "BOOL")

      assert result.term.module == "BOOL"
    end

    test "returns error for invalid output" do
      assert {:error, :no_result} = Reduction.parse("not a valid result")
    end

    test "handles zero rewrites" do
      output = """
      rewrites: 0 in 0ms cpu
      result Nat: 0
      """

      {:ok, result} = Reduction.parse(output)

      assert result.rewrites == 0
      assert result.time_ms == 0
    end

    test "handles large rewrite count" do
      output = """
      rewrites: 1000000 in 1234ms cpu
      result Nat: 42
      """

      {:ok, result} = Reduction.parse(output)

      assert result.rewrites == 1_000_000
      assert result.time_ms == 1234
    end
  end

  describe "Inspect protocol" do
    test "formats reduction without stats" do
      term = Term.new("6", "Nat")
      result = Reduction.new(term)
      inspected = inspect(result)

      assert inspected == "#ExMaude.Result.Reduction<term: 6 : Nat>"
    end

    test "formats reduction with rewrites" do
      term = Term.new("6", "Nat")
      result = Reduction.new(term, rewrites: 3)
      inspected = inspect(result)

      assert inspected == "#ExMaude.Result.Reduction<term: 6 : Nat, rewrites: 3>"
    end

    test "formats reduction with time" do
      term = Term.new("6", "Nat")
      result = Reduction.new(term, time_ms: 5)
      inspected = inspect(result)

      assert inspected == "#ExMaude.Result.Reduction<term: 6 : Nat, time: 5ms>"
    end

    test "formats reduction with all stats" do
      term = Term.new("42", "Nat")
      result = Reduction.new(term, rewrites: 10, time_ms: 2)
      inspected = inspect(result)

      assert inspected == "#ExMaude.Result.Reduction<term: 42 : Nat, rewrites: 10, time: 2ms>"
    end
  end
end
