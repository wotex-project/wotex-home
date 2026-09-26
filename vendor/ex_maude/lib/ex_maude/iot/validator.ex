defmodule ExMaude.IoT.Validator do
  @moduledoc """
  Validates IoT rule structures before conflict detection.

  This module provides validation for IoT rules, triggers, and actions
  before they are sent to Maude for conflict detection. Validation catches
  structural errors early with meaningful error messages.

  ## Overview

  Validation is performed automatically by `ExMaude.IoT.detect_conflicts/2`,
  but can also be called directly to check rules before submission:

      :ok = ExMaude.IoT.Validator.validate_rule(rule)
      {:error, errors} = ExMaude.IoT.Validator.validate_rule(%{})

  ## Required Rule Fields

  Every rule must have the following fields:

  | Field | Type | Description |
  |-------|------|-------------|
  | `:id` | `String.t()` | Unique rule identifier |
  | `:thing_id` | `String.t()` | Target device identifier |
  | `:trigger` | `trigger()` | Condition that activates the rule |
  | `:actions` | `[action()]` | List of actions to execute |
  | `:priority` | `integer()` | Optional priority (default: 1) |

  ## Trigger Validation

  Valid trigger formats:

  - `{:prop_eq, property, value}` - Property equals value
  - `{:prop_gt, property, number}` - Property greater than number
  - `{:prop_lt, property, number}` - Property less than number
  - `{:prop_gte, property, number}` - Property greater than or equal
  - `{:prop_lte, property, number}` - Property less than or equal
  - `{:env_eq, property, value}` - Environment equals value
  - `{:env_gt, property, number}` - Environment greater than number
  - `{:env_lt, property, number}` - Environment less than number
  - `{:always}` - Always triggered
  - `{:and, trigger, trigger}` - Logical AND
  - `{:or, trigger, trigger}` - Logical OR
  - `{:not, trigger}` - Logical NOT

  ## Action Validation

  Valid action formats:

  - `{:set_prop, thing_id, property, value}` - Set device property
  - `{:set_env, property, value}` - Set environment variable
  - `{:invoke, thing_id, action_name}` - Invoke device action

  ## Depth Limiting

  Nested triggers (`:and`, `:or`, `:not`) are limited to a maximum depth
  of 10 to prevent infinite recursion and stack overflow.

  ## Error Messages

  Validation errors are returned as a list of human-readable strings:

      {:error, [
        "missing required field: id",
        "missing required field: trigger",
        "invalid action format"
      ]}

  ## Batch Validation

  Use `validate_rules/1` to validate multiple rules at once:

      case ExMaude.IoT.Validator.validate_rules(rules) do
        :ok -> proceed()
        {:error, %{"rule-1" => ["invalid trigger format"]}} -> handle_errors()
      end

  ## See Also

  - `ExMaude.IoT` - High-level conflict detection API
  - `ExMaude.IoT.Encoder` - Encoding validated rules to Maude syntax
  """

  @max_trigger_depth 10

  @doc """
  Validates a rule structure.

  Returns `:ok` if the rule is valid, or `{:error, errors}` with a list
  of validation error messages.

  ## Examples

      iex> ExMaude.IoT.Validator.validate_rule(%{
      ...>   id: "my-rule",
      ...>   thing_id: "device-1",
      ...>   trigger: {:prop_eq, "state", true},
      ...>   actions: [{:set_prop, "device-1", "power", "on"}]
      ...> })
      :ok

      iex> ExMaude.IoT.Validator.validate_rule(%{})
      {:error,
       [
         "missing required field: id",
         "missing required field: thing_id",
         "missing required field: trigger",
         "missing required field: actions"
       ]}
  """
  @spec validate_rule(map()) :: :ok | {:error, [String.t()]}
  def validate_rule(rule) when is_map(rule) do
    errors =
      []
      |> validate_required(rule, :id, "id")
      |> validate_required(rule, :thing_id, "thing_id")
      |> validate_required(rule, :trigger, "trigger")
      |> validate_required(rule, :actions, "actions")
      |> validate_string_field(rule, :id, "id")
      |> validate_string_field(rule, :thing_id, "thing_id")
      |> validate_priority(Map.get(rule, :priority, 1))
      |> validate_trigger(Map.get(rule, :trigger), 0)
      |> validate_actions(Map.get(rule, :actions))

    case errors do
      [] -> :ok
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  def validate_rule(_), do: {:error, ["rule must be a map"]}

  @doc """
  Validates a list of rules.

  Returns `:ok` if all rules are valid, or `{:error, errors}` with a map
  of rule IDs to their validation errors. Errors sharing a key are combined.
  """
  @spec validate_rules([map()]) :: :ok | {:error, %{String.t() => [String.t()]}}
  def validate_rules(rules) when is_list(rules) and is_integer(length(rules)) do
    errors =
      rules
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {rule, idx}, acc ->
        case validate_rule(rule) do
          :ok ->
            acc

          {:error, errs} ->
            Map.update(acc, error_key(rule, idx), Enum.reverse(errs), &Enum.reverse(errs, &1))
        end
      end)
      |> Map.new(fn {key, errors} -> {key, Enum.reverse(errors)} end)

    errors = Map.merge(errors, ExMaude.Validation.duplicate_ids(rules), fn _, a, b -> a ++ b end)

    case errors do
      empty when map_size(empty) == 0 -> :ok
      _ -> {:error, errors}
    end
  end

  def validate_rules(_), do: {:error, %{"rules" => ["rules must be a list"]}}

  # Private validation functions

  defp validate_required(errors, map, key, name) do
    if Map.has_key?(map, key) and not is_nil(Map.get(map, key)) do
      errors
    else
      ["missing required field: #{name}" | errors]
    end
  end

  defp validate_string_field(errors, map, key, name) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) ->
        if valid_nonempty_string?(value),
          do: errors,
          else: ["#{name} must be a non-empty string" | errors]

      {:ok, nil} ->
        errors

      :error ->
        errors

      {:ok, _} ->
        ["#{name} must be a non-empty string" | errors]
    end
  end

  defp validate_priority(errors, priority) when is_integer(priority) and priority >= 0,
    do: errors

  defp validate_priority(errors, _),
    do: ["priority must be a non-negative integer" | errors]

  # Trigger validation with depth limiting to prevent infinite recursion
  defp validate_trigger(errors, _, depth) when depth > @max_trigger_depth do
    ["trigger nesting exceeds maximum depth of #{@max_trigger_depth}" | errors]
  end

  defp validate_trigger(errors, nil, 0), do: errors

  defp validate_trigger(errors, {:prop_eq, prop, value}, _) when is_binary(prop) do
    if valid_string?(prop),
      do: validate_value(errors, value),
      else: ["invalid trigger format" | errors]
  end

  defp validate_trigger(errors, {:prop_gt, prop, v}, _)
       when is_binary(prop) and is_number(v) do
    if valid_string?(prop), do: errors, else: ["invalid trigger format" | errors]
  end

  defp validate_trigger(errors, {:prop_lt, prop, v}, _)
       when is_binary(prop) and is_number(v) do
    if valid_string?(prop), do: errors, else: ["invalid trigger format" | errors]
  end

  defp validate_trigger(errors, {:prop_gte, prop, v}, _)
       when is_binary(prop) and is_number(v) do
    if valid_string?(prop), do: errors, else: ["invalid trigger format" | errors]
  end

  defp validate_trigger(errors, {:prop_lte, prop, v}, _)
       when is_binary(prop) and is_number(v) do
    if valid_string?(prop), do: errors, else: ["invalid trigger format" | errors]
  end

  defp validate_trigger(errors, {:env_eq, prop, value}, _) when is_binary(prop) do
    if valid_string?(prop),
      do: validate_value(errors, value),
      else: ["invalid trigger format" | errors]
  end

  defp validate_trigger(errors, {:env_gt, prop, v}, _)
       when is_binary(prop) and is_number(v) do
    if valid_string?(prop), do: errors, else: ["invalid trigger format" | errors]
  end

  defp validate_trigger(errors, {:env_lt, prop, v}, _)
       when is_binary(prop) and is_number(v) do
    if valid_string?(prop), do: errors, else: ["invalid trigger format" | errors]
  end

  defp validate_trigger(errors, {:always}, _), do: errors

  defp validate_trigger(errors, {:and, t1, t2}, depth) do
    errors
    |> validate_trigger(t1, depth + 1)
    |> validate_trigger(t2, depth + 1)
  end

  defp validate_trigger(errors, {:or, t1, t2}, depth) do
    errors
    |> validate_trigger(t1, depth + 1)
    |> validate_trigger(t2, depth + 1)
  end

  defp validate_trigger(errors, {:not, t}, depth), do: validate_trigger(errors, t, depth + 1)
  defp validate_trigger(errors, _, _), do: ["invalid trigger format" | errors]

  defp validate_actions(errors, nil), do: errors

  defp validate_actions(errors, actions) when is_list(actions) and is_integer(length(actions)) do
    Enum.reduce(actions, errors, &validate_action/2)
  end

  defp validate_actions(errors, _), do: ["actions must be a list" | errors]

  defp validate_action({:set_prop, thing_id, prop, value}, errors)
       when is_binary(thing_id) and is_binary(prop) do
    if valid_string?(thing_id) and valid_string?(prop),
      do: validate_value(errors, value),
      else: ["invalid action format" | errors]
  end

  defp validate_action({:set_env, prop, value}, errors) when is_binary(prop) do
    if valid_string?(prop),
      do: validate_value(errors, value),
      else: ["invalid action format" | errors]
  end

  defp validate_action({:invoke, thing_id, action}, errors)
       when is_binary(thing_id) and is_binary(action) do
    if valid_string?(thing_id) and valid_string?(action),
      do: errors,
      else: ["invalid action format" | errors]
  end

  defp validate_action(_, errors), do: ["invalid action format" | errors]

  defp validate_value(errors, value) when is_binary(value) do
    if valid_string?(value),
      do: errors,
      else: ["value must be a boolean, number, string, or atom" | errors]
  end

  defp validate_value(errors, value)
       when is_boolean(value) or is_number(value),
       do: errors

  defp validate_value(errors, value) when is_atom(value),
    do: validate_value(errors, Atom.to_string(value))

  defp validate_value(errors, _),
    do: ["value must be a boolean, number, string, or atom" | errors]

  defp error_key(%{id: id}, index) when is_binary(id) do
    if valid_nonempty_string?(id), do: id, else: "rule_#{index}"
  end

  defp error_key(_, index), do: "rule_#{index}"

  defp valid_nonempty_string?(value), do: valid_string?(value) and value != ""
  defp valid_string?(value), do: ExMaude.Validation.string?(value)
end
