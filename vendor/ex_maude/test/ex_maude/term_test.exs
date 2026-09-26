defmodule ExMaude.TermTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ExMaude.Term

  doctest ExMaude.Term

  describe "new/3" do
    test "creates term with value and sort" do
      term = Term.new("42", "Nat")

      assert term.value == "42"
      assert term.sort == "Nat"
      assert term.module == nil
      assert term.raw == nil
    end

    test "creates term with module option" do
      term = Term.new("true", "Bool", module: "BOOL")

      assert term.module == "BOOL"
    end

    test "creates term with raw option" do
      term = Term.new("6", "Nat", raw: "result Nat: 6")

      assert term.raw == "result Nat: 6"
    end

    test "creates term with all options" do
      term = Term.new("value", "Sort", module: "MOD", raw: "raw output")

      assert term.value == "value"
      assert term.sort == "Sort"
      assert term.module == "MOD"
      assert term.raw == "raw output"
    end
  end

  describe "parse/2" do
    test "parses simple result" do
      {:ok, term} = Term.parse("result Nat: 6")

      assert term.value == "6"
      assert term.sort == "Nat"
      assert term.raw == "result Nat: 6"
    end

    test "parses result with module" do
      {:ok, term} = Term.parse("result Bool: true", "BOOL")

      assert term.value == "true"
      assert term.sort == "Bool"
      assert term.module == "BOOL"
    end

    test "parses result with complex value" do
      {:ok, term} = Term.parse("result NatList: 1 2 3")

      assert term.value == "1 2 3"
      assert term.sort == "NatList"
    end

    test "parses result with operator expression" do
      {:ok, term} = Term.parse("result Nat: s(s(0))")

      assert term.value == "s(s(0))"
      assert term.sort == "Nat"
    end

    test "returns error for invalid output" do
      assert {:error, :no_result} = Term.parse("not a valid result")
    end

    test "returns error for empty string" do
      assert {:error, :no_result} = Term.parse("")
    end

    test "handles multiline result" do
      output = """
      reduce in NAT : 1 + 2 + 3 .
      rewrites: 3 in 0ms cpu (0ms real) (~ rewrites/second)
      result Nat: 6
      """

      {:ok, term} = Term.parse(output)
      assert term.value == "6"
      assert term.sort == "Nat"
    end
  end

  describe "sort?/2" do
    test "returns true for matching sort" do
      term = Term.new("42", "Nat")
      assert Term.sort?(term, "Nat") == true
    end

    test "returns false for non-matching sort" do
      term = Term.new("42", "Nat")
      assert Term.sort?(term, "Int") == false
    end

    test "is case-sensitive" do
      term = Term.new("true", "Bool")
      assert Term.sort?(term, "Bool") == true
      assert Term.sort?(term, "bool") == false
      assert Term.sort?(term, "BOOL") == false
    end
  end

  describe "to_integer/1" do
    test "converts Nat term to integer" do
      term = Term.new("42", "Nat")
      assert {:ok, 42} = Term.to_integer(term)
    end

    test "converts Int term to integer" do
      term = Term.new("-5", "Int")
      assert {:ok, -5} = Term.to_integer(term)
    end

    test "converts NzNat term to integer" do
      term = Term.new("100", "NzNat")
      assert {:ok, 100} = Term.to_integer(term)
    end

    test "converts NzInt term to integer" do
      term = Term.new("-1", "NzInt")
      assert {:ok, -1} = Term.to_integer(term)
    end

    test "converts zero" do
      term = Term.new("0", "Nat")
      assert {:ok, 0} = Term.to_integer(term)
    end

    test "returns error for Bool sort" do
      term = Term.new("true", "Bool")
      assert {:error, :not_numeric} = Term.to_integer(term)
    end

    test "returns error for String sort" do
      term = Term.new("hello", "String")
      assert {:error, :not_numeric} = Term.to_integer(term)
    end

    test "returns error for unparseable value" do
      term = Term.new("not-a-number", "Nat")
      assert {:error, :not_numeric} = Term.to_integer(term)
    end

    test "returns error for float value in Nat" do
      term = Term.new("3.14", "Nat")
      assert {:error, :not_numeric} = Term.to_integer(term)
    end
  end

  describe "to_boolean/1" do
    test "converts true Bool to true" do
      term = Term.new("true", "Bool")
      assert {:ok, true} = Term.to_boolean(term)
    end

    test "converts false Bool to false" do
      term = Term.new("false", "Bool")
      assert {:ok, false} = Term.to_boolean(term)
    end

    test "returns error for Nat sort" do
      term = Term.new("1", "Nat")
      assert {:error, :not_boolean} = Term.to_boolean(term)
    end

    test "returns error for non-boolean value in Bool sort" do
      term = Term.new("maybe", "Bool")
      assert {:error, :not_boolean} = Term.to_boolean(term)
    end

    test "returns error for String sort" do
      term = Term.new("true", "String")
      assert {:error, :not_boolean} = Term.to_boolean(term)
    end
  end

  describe "to_float/1" do
    test "converts Float term to float" do
      term = Term.new("3.14", "Float")
      assert {:ok, 3.14} = Term.to_float(term)
    end

    test "converts negative float" do
      term = Term.new("-2.5", "Float")
      assert {:ok, -2.5} = Term.to_float(term)
    end

    test "converts zero float" do
      term = Term.new("0.0", "Float")
      assert {:ok, result} = Term.to_float(term)
      assert result == 0.0
    end

    test "returns error for Nat sort" do
      term = Term.new("42", "Nat")
      assert {:error, :not_float} = Term.to_float(term)
    end

    test "returns error for unparseable value" do
      term = Term.new("not-a-float", "Float")
      assert {:error, :not_float} = Term.to_float(term)
    end
  end

  describe "to_string/1" do
    test "returns value as string" do
      term = Term.new("42", "Nat")
      assert Term.to_string(term) == "42"
    end

    test "returns complex value" do
      term = Term.new("s(s(0))", "Nat")
      assert Term.to_string(term) == "s(s(0))"
    end
  end

  describe "String.Chars protocol" do
    test "formats term as value : sort" do
      term = Term.new("42", "Nat")
      assert "#{term}" == "42 : Nat"
    end

    test "formats complex term" do
      term = Term.new("true and false", "Bool")
      assert "#{term}" == "true and false : Bool"
    end
  end

  describe "Inspect protocol" do
    test "formats term without module" do
      term = Term.new("42", "Nat")
      inspected = inspect(term)

      assert inspected == "#ExMaude.Term<42 : Nat>"
    end

    test "formats term with module" do
      term = Term.new("true", "Bool", module: "BOOL")
      inspected = inspect(term)

      assert inspected == "#ExMaude.Term<true : Bool in BOOL>"
    end
  end

  describe "parse/2 additional edge cases" do
    test "parses result with special characters in value" do
      {:ok, term} = Term.parse("result String: \"hello\\nworld\"")

      assert String.contains?(term.value, "hello")
    end

    test "parses result with parentheses in value" do
      {:ok, term} = Term.parse("result Expr: f(g(x, y), z)")

      assert term.value == "f(g(x, y), z)"
    end

    test "stores module in parsed term" do
      {:ok, term} = Term.parse("result Nat: 42", "NAT")

      assert term.module == "NAT"
    end

    test "stores raw output in parsed term" do
      raw = "result Bool: true"
      {:ok, term} = Term.parse(raw)

      assert term.raw == raw
    end
  end

  describe "to_integer/1 additional edge cases" do
    test "handles large positive integers" do
      term = Term.new("999999999", "Nat")
      assert {:ok, 999_999_999} = Term.to_integer(term)
    end

    test "handles large negative integers" do
      term = Term.new("-999999999", "Int")
      assert {:ok, -999_999_999} = Term.to_integer(term)
    end

    test "handles value with leading zeros" do
      term = Term.new("007", "Nat")
      assert {:ok, 7} = Term.to_integer(term)
    end

    test "rejects Float sort" do
      term = Term.new("3.14", "Float")
      assert {:error, :not_numeric} = Term.to_integer(term)
    end
  end

  describe "to_float/1 additional edge cases" do
    test "handles scientific notation" do
      term = Term.new("1.5e10", "Float")
      {:ok, float} = Term.to_float(term)
      assert float == 1.5e10
    end

    test "handles negative scientific notation" do
      term = Term.new("-2.5e-5", "Float")
      {:ok, float} = Term.to_float(term)
      assert float == -2.5e-5
    end
  end

  describe "sort?/2 additional edge cases" do
    test "handles complex sort names" do
      term = Term.new("empty", "List{Nat}")
      assert Term.sort?(term, "List{Nat}") == true
      assert Term.sort?(term, "List") == false
    end

    test "handles parameterized sorts" do
      term = Term.new("pair", "Pair{Nat, Bool}")
      assert Term.sort?(term, "Pair{Nat, Bool}") == true
    end
  end

  describe "struct fields" do
    test "enforces value and sort keys" do
      # These are required by @enforce_keys
      assert_raise ArgumentError, fn ->
        struct!(Term, [])
      end
    end

    test "allows creating struct with required keys" do
      term = struct!(Term, value: "test", sort: "Test")
      assert term.value == "test"
      assert term.sort == "Test"
    end
  end
end
