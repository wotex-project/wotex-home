defmodule ExMaude.Parser do
  @moduledoc """
  Parser for Maude command output.

  This module provides functions to parse various Maude command outputs
  into structured Elixir data. It handles the text-based responses from
  Maude and converts them into maps, lists, and tuples that are easier
  to work with in Elixir.

  ## Supported Output Formats

  The parser handles several types of Maude output:

    * **Reduction/Rewrite results** - `result Type: value` format
    * **Search solutions** - Multiple solutions with substitutions
    * **Error messages** - Warnings and errors from Maude
    * **Module listings** - Lists of loaded modules
    * **Term parsing** - Basic AST representation of Maude terms

  ## Usage

  This module is primarily used internally by `ExMaude.Maude` and `ExMaude.Server`,
  but can be used directly for custom output parsing:

      # Parse a reduce result
      {:ok, "42", "Nat"} = ExMaude.Parser.parse_result("result Nat: 42")

      # Parse search output
      solutions = ExMaude.Parser.parse_search_results(maude_output)

      # Check for errors in output
      :ok = ExMaude.Parser.parse_errors(clean_output)
      {:error, issues} = ExMaude.Parser.parse_errors("Error: bad input")

  ## Limitations

  The term parser (`parse_term/1`) provides basic parsing but does not handle
  all Maude syntax or module-defined operator precedence. Nested prefix
  applications and quoted arguments are supported. Use Maude's own `parse`
  command when the module's full grammar is required.
  """

  @doc """
  Parses search command output into a list of solutions.

  ## Examples

      iex> output =
      ...>   "Solution 1 (state 5)\\nS:State --> active\\n\\nSolution 2 (state 8)\\nS:State --> inactive\\n"
      ...>
      ...> ExMaude.Parser.parse_search_results(output)
      [
        %{solution: 1, state_num: 5, substitution: %{"S:State" => "active"}},
        %{solution: 2, state_num: 8, substitution: %{"S:State" => "inactive"}}
      ]
  """
  @spec parse_search_results(String.t()) :: list(map())
  def parse_search_results(output) do
    ~r/^Solution (\d+)(?: \(state \d+\))?[ \t]*\r?$/m
    |> Regex.scan(output, return: :index)
    |> Enum.chunk_every(2, 1, [nil])
    |> Enum.map(fn [current, following] ->
      [{start, _}, {number_start, number_length}] = current
      finish = if following, do: elem(hd(following), 0), else: byte_size(output)

      number =
        output
        |> binary_part(number_start, number_length)
        |> String.to_integer()

      parse_solution(binary_part(output, start, finish - start), number)
    end)
  end

  @doc """
  Parses a reduce/rewrite result to extract the value.

  ## Examples

      iex> ExMaude.Parser.parse_result("result Nat: 6")
      {:ok, "6", "Nat"}

      iex> ExMaude.Parser.parse_result("result Bool: true")
      {:ok, "true", "Bool"}

  Maude prints a kind instead of a sort when a term doesn't reduce to a
  well-sorted value — partial functions are the everyday trigger:

      iex> ExMaude.Parser.parse_result("result [Rat]: 1 / 0")
      {:ok, "1 / 0", "[Rat]"}
  """
  @spec parse_result(String.t()) :: {:ok, String.t(), String.t()} | {:error, :no_result}
  def parse_result(output) do
    # Allow parameterized sorts like `List{Nat}` and kinds like `[Rat]`.
    case Regex.run(~r/^result[ \t]+([^:\r\n]+):[ \t]*(.+)/ms, output) do
      [_, type, value] -> {:ok, String.trim(value), String.trim(type)}
      nil -> {:error, :no_result}
    end
  end

  @doc """
  Parses a backend's raw command output into the public response shape.

  This is the single source of truth for how Maude's text output is turned
  into `{:ok, value}` / `{:error, %ExMaude.Error{}}` — every backend should
  funnel its stdout through this helper to keep the public contract stable.

  The input is the text emitted between two `Maude>` prompts, with the
  trailing prompt already stripped.

  ## Examples

      iex> ExMaude.Parser.parse_backend_response("result Nat: 6")
      {:ok, "6"}

      iex> ExMaude.Parser.parse_backend_response("")
      {:ok, ""}

      iex> {:error, err} = ExMaude.Parser.parse_backend_response("Warning: module FOO not found")
      ...> err.type
      :module_not_found
  """
  @spec parse_backend_response(String.t()) :: {:ok, String.t()} | {:error, ExMaude.Error.t()}
  def parse_backend_response(output) when is_binary(output) do
    trimmed = String.trim(output)

    cond do
      maude_error?(trimmed) ->
        {:error, ExMaude.Error.from_output(trimmed)}

      String.contains?(trimmed, "result") ->
        case parse_result(trimmed) do
          {:ok, value, _} -> {:ok, value}
          {:error, :no_result} -> {:ok, trimmed}
        end

      true ->
        {:ok, trimmed}
    end
  end

  defp maude_error?(output) do
    # Quoted term data and echoed commands may contain diagnostic words.
    unquoted = Regex.replace(~r/"(?:\\.|[^"\\])*"/s, output, "")

    Regex.match?(
      ~r/^(?:Error:|Warning:|Advisory:|No parse for term|no module\s+\S+|module\s+\S+\s+not found|syntax error)/mi,
      unquoted
    )
  end

  @doc """
  Parses error messages from Maude output.

  ## Examples

      iex> ExMaude.Parser.parse_errors("Warning: blah\\nError: something bad")
      {:error, [warning: "blah", error: "something bad"]}
  """
  @spec parse_errors(String.t()) :: :ok | {:error, nonempty_list({:warning | :error, String.t()})}
  def parse_errors(output) do
    warnings =
      ~r/^Warning:[ \t]*(.+)/m
      |> Regex.scan(output)
      |> Enum.map(fn [_, msg] -> {:warning, String.trim(msg)} end)

    errors =
      ~r/^Error:[ \t]*(.+)/m
      |> Regex.scan(output)
      |> Enum.map(fn [_, msg] -> {:error, String.trim(msg)} end)

    case warnings ++ errors do
      [] -> :ok
      issues -> {:error, issues}
    end
  end

  @doc """
  Parses module list output.

  ## Examples

      iex> output = "fmod BOOL\\nfmod NAT\\nmod MY-MOD\\n"
      ...> ExMaude.Parser.parse_module_list(output)
      [
        %{type: :fmod, name: "BOOL"},
        %{type: :fmod, name: "NAT"},
        %{type: :mod, name: "MY-MOD"}
      ]
  """
  @spec parse_module_list(String.t()) :: list(map())
  def parse_module_list(output) do
    ~r/(fmod|mod|fth|th|view)\s+(\S+)/m
    |> Regex.scan(output)
    |> Enum.map(fn [_, type, name] ->
      %{type: parse_module_type(type), name: name}
    end)
  end

  # Whitelist to avoid dynamic atom creation from untrusted input. The regex
  # in parse_module_list/1 already gates these strings; the catch-all clause
  # is defense-in-depth.
  defp parse_module_type("fmod"), do: :fmod
  defp parse_module_type("mod"), do: :mod
  defp parse_module_type("fth"), do: :fth
  defp parse_module_type("th"), do: :th
  defp parse_module_type("view"), do: :view
  defp parse_module_type(_), do: :unknown

  @doc """
  Parses a Maude term into an Elixir term structure.

  This provides a basic AST representation of Maude terms.

  ## Examples

      iex> ExMaude.Parser.parse_term("s(s(0))")
      {:app, "s", [{:app, "s", [{:const, "0"}]}]}

      iex> ExMaude.Parser.parse_term("true and false")
      {:app, "and", [{:const, "true"}, {:const, "false"}]}
  """
  @spec parse_term(String.t()) :: {:const, String.t()} | {:app, String.t(), list()}
  def parse_term(input) do
    input
    |> String.trim()
    |> do_parse_term()
  end

  defp parse_solution(text, index) do
    state_num =
      case Regex.run(~r/\ASolution \d+ \(state (\d+)\)/, text) do
        [_, num] -> String.to_integer(num)
        nil -> nil
      end

    substitution =
      ~r/(\S+)\s*-->\s*(.+)/m
      |> Regex.scan(text)
      |> Map.new(fn [_, var, value] -> {String.trim(var), String.trim(value)} end)

    %{solution: index, state_num: state_num, substitution: substitution}
  end

  defp do_parse_term(input) do
    cond do
      match = Regex.run(~r/^(\w+)\(\)$/, input) ->
        [_, func] = match
        {:app, func, []}

      match = Regex.run(~r/^(\w+)\((.+)\)$/, input) ->
        [_, func, args_str] = match
        parse_application(input, func, args_str)

      match = Regex.run(~r/^(.+?)\s+(and|or|xor|\+|\*|-|\/|<|>|<=|>=|==|neq)\s+(.+)$/, input) ->
        [_, left, op, right] = match
        {:app, op, [do_parse_term(left), do_parse_term(right)]}

      true ->
        {:const, input}
    end
  end

  # Split only between arguments, preserving nested terms and quoted commas.
  defp parse_application(input, func, args_str) do
    case ExMaude.Balanced.split(args_str) do
      {:ok, args} -> {:app, func, Enum.map(args, &parse_one_arg/1)}
      :error -> {:const, input}
    end
  end

  defp parse_one_arg(arg) do
    arg
    |> String.trim()
    |> do_parse_term()
  end
end
