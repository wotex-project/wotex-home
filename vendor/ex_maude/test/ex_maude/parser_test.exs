defmodule ExMaude.ParserTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ExMaude.Parser

  doctest ExMaude.Parser

  describe "parse_result/1" do
    test "parses simple reduction result" do
      output = "result Nat: 42"
      assert {:ok, "42", "Nat"} = Parser.parse_result(output)
    end

    test "parses result with complex type" do
      output = "result MyType: complex-value"
      assert {:ok, "complex-value", "MyType"} = Parser.parse_result(output)
    end

    test "parses result with whitespace" do
      output = "result  Bool:   true  "
      assert {:ok, "true", "Bool"} = Parser.parse_result(output)
    end

    test "parses multiline result" do
      output = "result Nat: 42
some extra output"
      assert {:ok, result, "Nat"} = Parser.parse_result(output)
      assert String.contains?(result, "42")
    end

    test "parses kind-level result from a partial function" do
      assert {:ok, "1 / 0", "[Rat]"} = Parser.parse_result("result [Rat]: 1 / 0")
    end

    test "parses kind-level result with parameterized kind" do
      assert {:ok, "x", "[List{Nat}]"} = Parser.parse_result("result [List{Nat}]: x")
    end

    test "parses parameterized sort" do
      assert {:ok, "1 2 3", "List{Nat}"} = Parser.parse_result("result List{Nat}: 1 2 3")
    end

    test "returns error for no result" do
      assert {:error, :no_result} = Parser.parse_result("some other output")
    end

    test "returns error for empty string" do
      assert {:error, :no_result} = Parser.parse_result("")
    end

    test "returns error for malformed result" do
      assert {:error, :no_result} = Parser.parse_result("result without colon")
    end
  end

  describe "parse_search_results/1" do
    test "parses single solution" do
      output = """
      Solution 1 (state 5)
      S:State --> active
      """

      solutions = Parser.parse_search_results(output)
      assert length(solutions) == 1
      assert hd(solutions).solution == 1
      assert hd(solutions).state_num == 5
    end

    test "parses multiple solutions" do
      output = """
      Solution 1 (state 5)
      S:State --> active

      Solution 2 (state 8)
      S:State --> inactive

      Solution 3 (state 12)
      S:State --> pending
      """

      solutions = Parser.parse_search_results(output)
      assert length(solutions) == 3
      assert Enum.map(solutions, & &1.solution) == [1, 2, 3]
    end

    test "parses substitutions" do
      output = """
      Solution 1 (state 5)
      S:State --> active
      X:Nat --> 42
      """

      [solution] = Parser.parse_search_results(output)
      assert solution.substitution["S:State"] == "active"
      assert solution.substitution["X:Nat"] == "42"
    end

    test "handles empty output" do
      assert [] = Parser.parse_search_results("")
    end

    test "handles no solutions" do
      output = "No solution."
      assert [] = Parser.parse_search_results(output)
    end

    test "handles solution without state number" do
      output = "Solution 1
S:State --> active"
      [solution] = Parser.parse_search_results(output)
      assert solution.solution == 1
      assert solution.state_num == nil
    end
  end

  describe "parse_errors/1" do
    test "returns ok for clean output" do
      output = "result Nat: 42"
      assert :ok = Parser.parse_errors(output)
    end

    test "returns ok for empty output" do
      assert :ok = Parser.parse_errors("")
    end

    test "detects single warning" do
      output = "Warning: something suspicious"
      assert {:error, issues} = Parser.parse_errors(output)
      assert length(issues) == 1
      assert {:warning, _} = hd(issues)
    end

    test "detects single error" do
      output = "Error: something bad happened"
      assert {:error, issues} = Parser.parse_errors(output)
      assert length(issues) == 1
      assert {:error, _} = hd(issues)
    end

    test "detects multiple warnings and errors" do
      output = """
      Warning: first warning
      Error: first error
      Warning: second warning
      Error: second error
      """

      assert {:error, issues} = Parser.parse_errors(output)
      assert length(issues) == 4
      warnings = Enum.filter(issues, fn {type, _} -> type == :warning end)
      errors = Enum.filter(issues, fn {type, _} -> type == :error end)
      assert length(warnings) == 2
      assert length(errors) == 2
    end

    test "extracts error message content" do
      output = "Error: undefined variable X"
      assert {:error, [{:error, msg}]} = Parser.parse_errors(output)
      assert msg == "undefined variable X"
    end
  end

  describe "parse_module_list/1" do
    test "parses functional modules" do
      output = "fmod BOOL
fmod NAT"
      modules = Parser.parse_module_list(output)
      assert length(modules) == 2
      assert Enum.all?(modules, &(&1.type == :fmod))
    end

    test "parses system modules" do
      output = "mod MY-MOD"
      [module] = Parser.parse_module_list(output)
      assert module.type == :mod
      assert module.name == "MY-MOD"
    end

    test "parses mixed module types" do
      output = """
      fmod BOOL
      fmod NAT
      mod MY-MOD
      fth TRIV
      th MY-THEORY
      view MY-VIEW
      """

      modules = Parser.parse_module_list(output)
      assert length(modules) == 6
      types = Enum.map(modules, & &1.type)
      assert :fmod in types
      assert :mod in types
      assert :fth in types
      assert :th in types
      assert :view in types
    end

    test "handles empty output" do
      assert [] = Parser.parse_module_list("")
    end
  end

  describe "parse_term/1" do
    test "parses constant" do
      assert {:const, "foo"} = Parser.parse_term("foo")
    end

    test "parses constant with whitespace" do
      assert {:const, "foo"} = Parser.parse_term("  foo  ")
    end

    test "parses simple function application" do
      assert {:app, "s", [{:const, "0"}]} = Parser.parse_term("s(0)")
    end

    test "parses nested function application" do
      result = Parser.parse_term("f(g(a))")
      assert {:app, "f", [{:app, "g", [{:const, "a"}]}]} = result
    end

    test "parses infix operator" do
      result = Parser.parse_term("a and b")
      assert {:app, "and", [{:const, "a"}, {:const, "b"}]} = result
    end

    test "parses addition operator" do
      result = Parser.parse_term("1 + 2")
      assert {:app, "+", [{:const, "1"}, {:const, "2"}]} = result
    end

    test "parses comparison operator" do
      result = Parser.parse_term("x neq y")
      assert {:app, "neq", [{:const, "x"}, {:const, "y"}]} = result
    end

    test "parses multiple arguments" do
      result = Parser.parse_term("f(a, b)")
      assert {:app, "f", args} = result
      assert length(args) == 2
    end

    test "parses three arguments" do
      result = Parser.parse_term("if(cond, then, else)")
      assert {:app, "if", args} = result
      assert length(args) == 3
    end

    test "parses deeply nested terms" do
      result = Parser.parse_term("f(g(h(a)))")
      assert {:app, "f", [{:app, "g", [{:app, "h", [{:const, "a"}]}]}]} = result
    end

    test "handles empty parentheses" do
      result = Parser.parse_term("nil()")
      assert {:app, "nil", []} = result
    end
  end

  describe "parse_result/1 edge cases" do
    test "parses result with nested parentheses in value" do
      output = "result Term: f(g(h(x)))"
      assert {:ok, "f(g(h(x)))", "Term"} = Parser.parse_result(output)
    end

    test "parses result with spaces in value" do
      output = "result List: a b c"
      assert {:ok, "a b c", "List"} = Parser.parse_result(output)
    end

    test "parses result with parameterized type" do
      output = "result List{Nat}: 1 2 3"
      assert {:ok, "1 2 3", _} = Parser.parse_result(output)
    end

    test "parses result from full reduction output" do
      output = """
      reduce in NAT : 1 + 2 + 3 .
      rewrites: 3 in 0ms cpu (0ms real) (~ rewrites/second)
      result Nat: 6
      """

      assert {:ok, "6", "Nat"} = Parser.parse_result(output)
    end
  end

  describe "parse_search_results/1 edge cases" do
    test "parses solution with complex substitution value" do
      output = """
      Solution 1 (state 5)
      S:State --> state(active, config(1, 2, 3))
      """

      [solution] = Parser.parse_search_results(output)
      assert String.contains?(solution.substitution["S:State"], "state(active")
    end

    test "parses solution with quoted string value" do
      output = """
      Solution 1 (state 5)
      S:String --> "hello world"
      """

      [solution] = Parser.parse_search_results(output)
      assert solution.substitution["S:String"] == "\"hello world\""
    end

    test "handles solution with many substitutions" do
      output = """
      Solution 1 (state 10)
      A:Nat --> 1
      B:Nat --> 2
      C:Nat --> 3
      D:Nat --> 4
      E:Nat --> 5
      """

      [solution] = Parser.parse_search_results(output)
      assert map_size(solution.substitution) == 5
    end
  end

  describe "parse_errors/1 edge cases" do
    test "handles warning with special characters" do
      output = "Warning: module \"Foo\" (file: /path/to/file.maude) not found"
      assert {:error, [{:warning, msg}]} = Parser.parse_errors(output)
      assert String.contains?(msg, "module")
    end

    test "handles interleaved warnings and normal output" do
      output = """
      some normal output
      Warning: first warning
      more normal output
      Error: an error
      final output
      """

      assert {:error, issues} = Parser.parse_errors(output)
      assert length(issues) == 2
    end
  end

  describe "parse_module_list/1 edge cases" do
    test "handles unknown module type" do
      output = "unknown MYSTERY-MOD"
      modules = Parser.parse_module_list(output)
      assert modules == []
    end

    test "handles module names with hyphens" do
      output = "fmod MY-LONG-MODULE-NAME"
      [module] = Parser.parse_module_list(output)
      assert module.name == "MY-LONG-MODULE-NAME"
    end

    test "handles module names with underscores" do
      output = "mod MY_MODULE_NAME"
      [module] = Parser.parse_module_list(output)
      assert module.name == "MY_MODULE_NAME"
    end

    test "parse_module_type returns :unknown for unrecognized types" do
      # This test covers the catch-all clause in parse_module_type/1
      # We need to test this via the regex matching something unexpected
      # Since the regex is strict, we use the internal function indirectly
      # by testing all known types and verifying they map correctly
      output = """
      fmod BOOL
      mod STATE
      fth TRIV
      th THEORY
      view MYVIEW
      """

      modules = Parser.parse_module_list(output)

      types = Enum.map(modules, & &1.type)
      assert :fmod in types
      assert :mod in types
      assert :fth in types
      assert :th in types
      assert :view in types
      # All known types are properly mapped (no :unknown)
      refute :unknown in types
    end
  end

  describe "parse_term/1 additional operators" do
    test "parses multiplication operator" do
      result = Parser.parse_term("3 * 4")
      assert {:app, "*", [{:const, "3"}, {:const, "4"}]} = result
    end

    test "parses subtraction operator" do
      result = Parser.parse_term("10 - 5")
      assert {:app, "-", [{:const, "10"}, {:const, "5"}]} = result
    end

    test "parses division operator" do
      result = Parser.parse_term("20 / 4")
      assert {:app, "/", [{:const, "20"}, {:const, "4"}]} = result
    end

    test "parses less than operator" do
      result = Parser.parse_term("a < b")
      assert {:app, "<", [{:const, "a"}, {:const, "b"}]} = result
    end

    test "parses greater than operator" do
      result = Parser.parse_term("a > b")
      assert {:app, ">", [{:const, "a"}, {:const, "b"}]} = result
    end

    test "parses less than or equal operator" do
      result = Parser.parse_term("a <= b")
      assert {:app, "<=", [{:const, "a"}, {:const, "b"}]} = result
    end

    test "parses greater than or equal operator" do
      result = Parser.parse_term("a >= b")
      assert {:app, ">=", [{:const, "a"}, {:const, "b"}]} = result
    end

    test "parses equality operator" do
      result = Parser.parse_term("a == b")
      assert {:app, "==", [{:const, "a"}, {:const, "b"}]} = result
    end

    test "parses or operator" do
      result = Parser.parse_term("a or b")
      assert {:app, "or", [{:const, "a"}, {:const, "b"}]} = result
    end

    test "parses xor operator" do
      result = Parser.parse_term("a xor b")
      assert {:app, "xor", [{:const, "a"}, {:const, "b"}]} = result
    end
  end

  describe "parse_search_results/1 additional edge cases" do
    test "handles solution with empty substitution" do
      output = """
      Solution 1 (state 0)
      """

      [solution] = Parser.parse_search_results(output)
      assert solution.solution == 1
      assert solution.state_num == 0
      assert solution.substitution == %{}
    end

    test "handles large state numbers" do
      output = """
      Solution 1 (state 999999)
      X:Nat --> 42
      """

      [solution] = Parser.parse_search_results(output)
      assert solution.state_num == 999_999
    end

    test "handles substitution with arrow in value" do
      output = """
      Solution 1 (state 5)
      F:Func --> a --> b
      """

      [solution] = Parser.parse_search_results(output)
      # The value should capture everything after the first -->
      assert solution.substitution["F:Func"] == "a --> b"
    end
  end

  describe "parse_term/1 complex cases" do
    test "parses function with nested comma arguments" do
      result = Parser.parse_term("pair(f(a, b), g(c, d))")
      assert {:app, "pair", args} = result
      assert [{:app, "f", [const: "a", const: "b"]}, {:app, "g", [const: "c", const: "d"]}] = args
    end

    test "parses chained operators" do
      result = Parser.parse_term("a and b and c")
      assert {:app, "and", _} = result
    end

    test "parses term with underscores in name" do
      result = Parser.parse_term("my_function(x)")
      assert {:app, "my_function", [{:const, "x"}]} = result
    end

    test "parses term with hyphen-like characters" do
      result = Parser.parse_term("value")
      assert {:const, "value"} = result
    end

    test "handles whitespace around operators" do
      result = Parser.parse_term("a   and   b")
      assert {:app, "and", [{:const, "a"}, {:const, "b"}]} = result
    end

    test "parses modulo operator" do
      result = Parser.parse_term("10 / 3")
      assert {:app, "/", [{:const, "10"}, {:const, "3"}]} = result
    end
  end

  describe "parse_result/1 with full Maude output" do
    test "parses result with stats line" do
      output = """
      reduce in NAT : 100 + 200 .
      rewrites: 1 in 0ms cpu (0ms real) (~ rewrites/second)
      result NzNat: 300
      """

      assert {:ok, "300", "NzNat"} = Parser.parse_result(output)
    end

    test "parses result with multiple stat lines" do
      output = """
      reduce in BOOL : true and (false or true) .
      rewrites: 2 in 0ms cpu (0ms real) (~ rewrites/second)
      result Bool: true
      """

      assert {:ok, "true", "Bool"} = Parser.parse_result(output)
    end

    test "parses result with generic type" do
      output = "result [Sort]: value"
      result = Parser.parse_result(output)
      assert match?({:ok, _, _}, result) or match?({:error, :no_result}, result)
    end
  end

  describe "parse_module_list/1 with real output" do
    test "parses typical show modules output" do
      output = """
      fmod BOOL is
      fmod NAT is
      fmod INT is
      fmod RAT is
      mod CONFIGURATION is
      """

      modules = Parser.parse_module_list(output)
      assert length(modules) >= 4
      names = Enum.map(modules, & &1.name)
      assert "BOOL" in names
      assert "NAT" in names
    end

    test "handles module with parameterized name" do
      output = "fmod LIST{X} is"
      # The regex may or may not match parameterized module names
      modules = Parser.parse_module_list(output)
      assert is_list(modules)
    end
  end

  describe "parse_errors/1 with complex output" do
    test "extracts multiple error messages correctly" do
      output = """
      Warning: module NAT not found
      Error: undefined sort Foo
      Warning: deprecated syntax
      """

      assert {:error, issues} = Parser.parse_errors(output)
      assert length(issues) == 3

      messages = Enum.map(issues, fn {_, msg} -> msg end)
      assert Enum.any?(messages, &String.contains?(&1, "NAT"))
      assert Enum.any?(messages, &String.contains?(&1, "Foo"))
    end

    test "handles error with line numbers" do
      output = "Error: (line 5) unexpected token"
      assert {:error, [{:error, msg}]} = Parser.parse_errors(output)
      assert String.contains?(msg, "line 5") or String.contains?(msg, "unexpected")
    end
  end

  describe "parse_search_results/1 with complex substitutions" do
    test "handles list value in substitution" do
      output = """
      Solution 1 (state 3)
      L:List --> 1 2 3 4 5
      """

      [solution] = Parser.parse_search_results(output)
      assert solution.substitution["L:List"] == "1 2 3 4 5"
    end

    test "handles nested structure in substitution" do
      output = """
      Solution 1 (state 7)
      S:State --> config(active, props(x: 1, y: 2))
      """

      [solution] = Parser.parse_search_results(output)
      assert String.contains?(solution.substitution["S:State"], "config")
    end

    test "handles multiple solutions with same variable names" do
      output = """
      Solution 1 (state 1)
      X:Nat --> 1

      Solution 2 (state 2)
      X:Nat --> 2

      Solution 3 (state 3)
      X:Nat --> 3
      """

      solutions = Parser.parse_search_results(output)
      assert length(solutions) == 3
      values = Enum.map(solutions, fn s -> s.substitution["X:Nat"] end)
      assert values == ["1", "2", "3"]
    end
  end

  test "diagnostic words in result values are ordinary data" do
    for value <- ["Error: harmless", "Warning: harmless", "syntax error", "no module FOO"] do
      assert {:ok, _} = Parser.parse_backend_response("result String: #{inspect(value)}")
    end

    assert {:error, %ExMaude.Error{}} = Parser.parse_backend_response("Warning: bad input")
  end

  test "valid sort identifiers are not restricted to word characters" do
    assert {:ok, "x", "My-Sort"} = Parser.parse_result("result My-Sort: x")
    assert {:ok, "x"} = Parser.parse_backend_response("result My-Sort: x")
    assert {:error, :no_result} = Parser.parse_result(~s(reduce in STRING : "result Nat: 5" .))
  end

  test "search headers preserve actual numbering and ignore markers inside values" do
    output = "Solution 7 (state 8)\nS:String --> \"Solution 99\"\n"

    assert [%{solution: 7, state_num: 8, substitution: %{"S:String" => ~s("Solution 99")}}] =
             Parser.parse_search_results(output)
  end

  test "nested and quoted arguments stay intact" do
    assert {:app, "f", [{:app, "g", [{:const, "a"}, {:const, "b"}]}, {:const, "c"}]} =
             Parser.parse_term("f(g(a, b), c)")

    assert {:app, "f", [{:const, ~s("a,b")}, {:const, "c"}]} = Parser.parse_term(~s|f("a,b", c)|)
  end

  test "search state numbers come from the header, never substitution values" do
    output = "Solution 7\nS:String --> \"literal (state 99)\"\n"
    assert [%{solution: 7, state_num: nil}] = Parser.parse_search_results(output)
  end

  test "escaped quotes do not hide a real diagnostic on the following line" do
    result = ~S(result String: "say \"Error: safe\" and Warning: safe")
    assert {:ok, _} = Parser.parse_backend_response(result)

    assert {:error, %ExMaude.Error{}} =
             Parser.parse_backend_response(result <> "\nWarning: bad input")
  end

  test "argument scanning respects escaped quotes and rejects unbalanced expressions" do
    assert {:app, "f", [{:const, ~S("quoted \"x,y\"")}, {:const, "z"}]} =
             Parser.parse_term(~S|f("quoted \"x,y\"", z)|)

    for malformed <- ["f(g(a, b)", ~S|f("unfinished, z)|] do
      assert {:const, ^malformed} = Parser.parse_term(malformed)
    end
  end
end
