defmodule ExMaude.AI.ConflictParser do
  @moduledoc """
  Parses Maude conflict-detection output from `ai-rules.maude` into
  Elixir structures.

  Companion to `ExMaude.IoT.ConflictParser`. Handles the additional
  conflict types and the `aiConflictSingle` constructor (single-rule
  conflicts like sovereignty violations and approval-gate bypasses).

  ## Maude output format

  Maude returns AI conflicts in two shapes:

      result AIConflictSet: noAIConflict

      result AIConflictSet: aiConflict(toolCallConflict,
        aiRule("rule-1", ...),
        aiRule("rule-2", ...),
        "Same agent, same tool, conflicting required arguments")

      result AIConflictSet: aiConflictSingle(sovereigntyViolation,
        aiRule("rule-3", ...),
        "Tool invocation routes through forbidden jurisdiction")

  Multiple conflicts are joined with the `||c||` operator:

      aiConflict(...) ||c|| aiConflictSingle(...) ||c|| aiConflict(...)

  ## Conflict type mapping

  | Maude constructor | Elixir atom |
  |---|---|
  | `toolCallConflict` | `:tool_call_conflict` |
  | `capabilityShadowing` | `:capability_shadowing` |
  | `packToolCompositionMismatch` | `:pack_tool_composition_mismatch` |
  | `sovereigntyViolation` | `:sovereignty_violation` |
  | `authorityEscalation` | `:authority_escalation` |
  | `approvalGateBypass` | `:approval_gate_bypass` |
  | `agentLoopCascade` | `:agent_loop_cascade` |
  """

  @type conflict_type ::
          :tool_call_conflict
          | :capability_shadowing
          | :pack_tool_composition_mismatch
          | :sovereignty_violation
          | :authority_escalation
          | :approval_gate_bypass
          | :agent_loop_cascade
          | :unknown_conflict

  @type conflict :: %{
          required(:type) => conflict_type(),
          required(:reason) => String.t(),
          required(:rule1) => String.t(),
          optional(:rule2) => String.t() | nil
        }

  @doc """
  Parses Maude output to extract AI conflict information.

  Returns an empty list if no conflicts are found, or a list of
  conflict maps. Pairwise conflicts include both `:rule1` and
  `:rule2`; single-rule conflicts include only `:rule1` and a `nil`
  `:rule2`.

  ## Examples

      iex> ExMaude.AI.ConflictParser.parse_conflicts("result AIConflictSet: noAIConflict")
      []

      iex> output =
      ...>   ~s|aiConflictSingle(sovereigntyViolation, aiRule("r3", | <>
      ...>     ~s|agent(tenant("acme"), "ag-1"), alwaysP, nilInvocation, noCap, 0, 1), | <>
      ...>     ~s|"Tool invocation routes through forbidden jurisdiction")|
      ...>
      ...> ExMaude.AI.ConflictParser.parse_conflicts(output)
      [
        %{
          type: :sovereignty_violation,
          rule1: "r3",
          rule2: nil,
          reason: "Tool invocation routes through forbidden jurisdiction"
        }
      ]
  """
  @spec parse_conflicts(String.t()) :: [conflict()]
  def parse_conflicts(output) do
    cond do
      String.contains?(output, "noAIConflict") and
        not String.contains?(output, "aiConflict(") and
          not String.contains?(output, "aiConflictSingle(") ->
        []

      String.contains?(output, "aiConflict(") or
          String.contains?(output, "aiConflictSingle(") ->
        parse_conflict_list(output)

      true ->
        []
    end
  end

  @doc "Parses a complete conflict result, returning an error for malformed or unreduced output."
  @spec parse_result(String.t()) :: {:ok, [conflict()]} | {:error, ExMaude.Error.t()}
  def parse_result(output),
    do: ExMaude.ConflictOutput.parse(output, "noAIConflict", "||c||", &parse_complete/1)

  defp parse_complete(expression) do
    alias ExMaude.ConflictOutput, as: Output

    with {:ok, [type, first, second, reason]} <- Output.arguments(expression, "aiConflict"),
         parsed_type when parsed_type != :unknown_conflict <- parse_conflict_type(type),
         {:ok, first_id} <- Output.rule_id(first, "aiRule", 7),
         {:ok, second_id} <- Output.rule_id(second, "aiRule", 7),
         {:ok, reason} <- Output.string(reason) do
      %{type: parsed_type, rule1: first_id, rule2: second_id, reason: reason}
    else
      _ -> parse_complete_single(expression)
    end
  end

  defp parse_complete_single(expression) do
    alias ExMaude.ConflictOutput, as: Output

    with {:ok, [type, rule, reason]} <- Output.arguments(expression, "aiConflictSingle"),
         parsed_type when parsed_type != :unknown_conflict <- parse_conflict_type(type),
         {:ok, id} <- Output.rule_id(rule, "aiRule", 7),
         {:ok, reason} <- Output.string(reason) do
      %{type: parsed_type, rule1: id, rule2: nil, reason: reason}
    else
      _ -> nil
    end
  end

  defp parse_conflict_list(output) do
    pairwise = ExMaude.Balanced.extract(output, "aiConflict(")
    single = ExMaude.Balanced.extract(output, "aiConflictSingle(")

    (Enum.map(pairwise, &parse_pairwise/1) ++ Enum.map(single, &parse_single/1))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp parse_pairwise(conflict_str) do
    type_match = Regex.run(~r/aiConflict\(\s*(\w+)\s*,/s, conflict_str)

    rule_ids =
      ExMaude.Syntax.captured_strings(
        ~r/aiRule\(\s*"((?:\\.|[^"\\])*)"/s,
        conflict_str
      )

    reason = extract_reason(conflict_str)

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

  defp parse_single(conflict_str) do
    type_match = Regex.run(~r/aiConflictSingle\(\s*(\w+)\s*,/s, conflict_str)

    rule_ids =
      ExMaude.Syntax.captured_strings(
        ~r/aiRule\(\s*"((?:\\.|[^"\\])*)"/s,
        conflict_str
      )

    reason = extract_reason(conflict_str)

    case {type_match, rule_ids, reason} do
      {[_, type], [rule1 | _], reason} when not is_nil(reason) ->
        %{
          type: parse_conflict_type(type),
          rule1: rule1,
          rule2: nil,
          reason: reason
        }

      _ ->
        nil
    end
  end

  defp extract_reason(conflict_str) do
    conflict_str
    |> ExMaude.Syntax.quoted_strings()
    |> List.last()
  end

  defp parse_conflict_type("toolCallConflict"), do: :tool_call_conflict
  defp parse_conflict_type("capabilityShadowing"), do: :capability_shadowing
  defp parse_conflict_type("packToolCompositionMismatch"), do: :pack_tool_composition_mismatch
  defp parse_conflict_type("sovereigntyViolation"), do: :sovereignty_violation
  defp parse_conflict_type("authorityEscalation"), do: :authority_escalation
  defp parse_conflict_type("approvalGateBypass"), do: :approval_gate_bypass
  defp parse_conflict_type("agentLoopCascade"), do: :agent_loop_cascade
  defp parse_conflict_type(_), do: :unknown_conflict
end
