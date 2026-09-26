defmodule ExMaude.IoT.ConflictParser do
  @moduledoc """
  Parses Maude conflict detection output into Elixir structures.

  This module handles extracting conflict information from Maude's output format,
  including balanced parenthesis parsing for nested conflict expressions.

  ## Overview

  After Maude processes a conflict detection command, it returns output in a
  specific format. This module parses that output into structured Elixir maps.

  ## Maude Output Format

  Maude returns conflict information in this format:

      result ConflictSet: noConflict

      result ConflictSet: conflict(stateConflict,
        rule("motion-light", ...),
        rule("night-mode", ...),
        "Both rules modify the same property with different values")

  Multiple conflicts are separated by `|`:

      conflict(...) | conflict(...) | conflict(...)

  ## Conflict Types

  The parser recognizes four conflict types from the AutoIoT paper:

  | Maude Type | Elixir Atom | Description |
  |------------|-------------|-------------|
  | `stateConflict` | `:state_conflict` | Same device, incompatible states |
  | `envConflict` | `:env_conflict` | Opposing environmental effects |
  | `stateCascade` | `:state_cascade` | Rule output triggers conflicting rule |
  | `stateEnvCascade` | `:state_env_cascade` | Combined cascading effects |

  ## Parsed Output

  Each conflict is parsed into a map:

      %{
        type: :state_conflict,
        rule1: "motion-light",
        rule2: "night-mode",
        reason: "Both rules modify the same property with different values"
      }

  ## Parsing Algorithm

  The parser uses balanced parenthesis tracking to handle nested expressions:

  1. Locate `conflict(` markers in the output
  2. Track parenthesis depth to find matching close paren
  3. Extract conflict type, rule IDs, and reason from each conflict
  4. Deduplicate results (Maude may report same conflict multiple ways)

  ## Edge Cases

  - Returns empty list `[]` for `noConflict` output
  - Returns empty list for output without `conflict(` markers
  - Skips malformed conflict expressions that can't be parsed
  - Handles whitespace and newlines in Maude output

  ## Usage

  This module is used internally by `ExMaude.IoT.detect_conflicts/2`:

      # Internal usage
      conflicts = ExMaude.IoT.ConflictParser.parse_conflicts(maude_output)
      # => [%{type: :state_conflict, rule1: "r1", rule2: "r2", reason: "..."}]

  ## See Also

  - `ExMaude.IoT` - High-level conflict detection API
  - `ExMaude.IoT.Encoder` - Encoding rules to Maude syntax
  - [AutoIoT Paper](https://arxiv.org/abs/2411.10665) - Conflict type definitions
  """

  @type conflict_type :: :state_conflict | :env_conflict | :state_cascade | :state_env_cascade

  @type conflict :: %{
          type: conflict_type(),
          rule1: String.t(),
          rule2: String.t(),
          reason: String.t()
        }

  @doc """
  Parses Maude output to extract conflict information.

  Returns an empty list if no conflicts are found, or a list of conflict maps.

  ## Examples

      iex> ExMaude.IoT.ConflictParser.parse_conflicts("result ConflictSet: noConflict")
      []

      iex> output =
      ...>   ~s|result ConflictSet: conflict(stateConflict, | <>
      ...>     ~s|rule("r1", thing("a"), always, nil, 1), | <>
      ...>     ~s|rule("r2", thing("a"), always, nil, 1), "Conflicting state changes")|
      ...>
      ...> ExMaude.IoT.ConflictParser.parse_conflicts(output)
      [%{type: :state_conflict, rule1: "r1", rule2: "r2", reason: "Conflicting state changes"}]
  """
  @spec parse_conflicts(String.t()) :: [conflict()]
  def parse_conflicts(output) do
    cond do
      String.contains?(output, "noConflict") and not String.contains?(output, "conflict(") ->
        []

      String.contains?(output, "conflict(") ->
        parse_conflict_list(output)

      true ->
        []
    end
  end

  @doc "Parses a complete conflict result, returning an error for malformed or unreduced output."
  @spec parse_result(String.t()) :: {:ok, [conflict()]} | {:error, ExMaude.Error.t()}
  def parse_result(output),
    do: ExMaude.ConflictOutput.parse(output, "noConflict", "|", &parse_complete/1)

  defp parse_complete(expression) do
    alias ExMaude.ConflictOutput, as: Output

    with {:ok, [type, first, second, reason]} <- Output.arguments(expression, "conflict"),
         parsed_type when parsed_type != :unknown_conflict <- parse_conflict_type(type),
         {:ok, first_id} <- Output.rule_id(first, "rule", 5),
         {:ok, second_id} <- Output.rule_id(second, "rule", 5),
         {:ok, reason} <- Output.string(reason) do
      %{type: parsed_type, rule1: first_id, rule2: second_id, reason: reason}
    else
      _ -> nil
    end
  end

  defp parse_conflict_list(output) do
    output
    |> ExMaude.Balanced.extract("conflict(")
    |> Enum.map(&parse_single_conflict/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp parse_single_conflict(conflict_str) do
    type_match = Regex.run(~r/conflict\(\s*(\w+)\s*,/s, conflict_str)

    rule_ids =
      ExMaude.Syntax.captured_strings(
        ~r/rule\(\s*"((?:\\.|[^"\\])*)"/s,
        conflict_str
      )

    reason =
      conflict_str
      |> ExMaude.Syntax.quoted_strings()
      |> List.last()

    case {type_match, rule_ids, reason} do
      {[_, type], [rule1, rule2 | _], reason} when not is_nil(reason) ->
        %{
          type: parse_conflict_type(type),
          rule1: rule1,
          rule2: rule2,
          reason: reason
        }

      _ ->
        nil
    end
  end

  defp parse_conflict_type("stateConflict"), do: :state_conflict
  defp parse_conflict_type("envConflict"), do: :env_conflict
  defp parse_conflict_type("stateCascade"), do: :state_cascade
  defp parse_conflict_type("stateEnvCascade"), do: :state_env_cascade
  defp parse_conflict_type(_), do: :unknown_conflict
end
