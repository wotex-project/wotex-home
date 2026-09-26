defmodule ExMaude.AI.Validator do
  @moduledoc """
  Validates AI rule structures before encoding to Maude.

  Companion to `ExMaude.IoT.Validator`. Catches shape errors,
  unsupported predicate types, and obviously-malformed values
  before they reach the Maude port worker. Validation here is
  cheap; rejecting at this layer avoids the cost of a Maude round
  trip for a malformed rule.

  An AI rule is a map with these required fields:

    - `:id` — non-empty string
    - `:agent_id` — `{tenant_id :: String.t(), agent_name :: String.t()}`
    - `:trigger` — predicate (see Encoder docs for predicate shapes)
    - `:invocations` — list of tool invocations (may be empty)

  Optional fields:

    - `:capability_grants` — list of `{:cap, name, shape}` or bare strings
    - `:authority_required` — non-negative integer (default 0)
    - `:priority` — non-negative integer (default 1)
  """

  @jurisdictions [:eu, :us, :cn, :ch, :uk, :ca, :au, :other]
  @subjurisdictions [:de, :fr, :es, :it, :nl, :se, :fi, :dk, :pl, :be, :ie, :pt, :at]
  @all_jurisdictions @jurisdictions ++ @subjurisdictions

  @doc """
  Validates a single AI rule.

  Returns `:ok` on success, or `{:error, [error_msg]}` listing all
  validation failures.

  ## Examples

      iex> ExMaude.AI.Validator.validate_rule(%{
      ...>   id: "r1",
      ...>   agent_id: {"acme", "ag-1"},
      ...>   trigger: {:always},
      ...>   invocations: []
      ...> })
      :ok

      iex> ExMaude.AI.Validator.validate_rule(%{})
      {:error,
       [
         "missing required field: id",
         "missing required field: agent_id",
         "missing required field: trigger",
         "missing required field: invocations"
       ]}

      iex> rule = %{
      ...>   id: "r1",
      ...>   agent_id: {"acme", "ag-1"},
      ...>   trigger: {:contains, "x", "y"},
      ...>   invocations: []
      ...> }
      ...>
      ...> ExMaude.AI.Validator.validate_rule(rule)
      {:error, ["trigger: unsupported :contains predicate; ai-rules.maude does not implement it"]}
  """
  @spec validate_rule(term()) :: :ok | {:error, [String.t()]}
  def validate_rule(rule) when is_map(rule) do
    errors =
      []
      |> validate_required_fields(rule)
      |> validate_id(rule)
      |> validate_agent_id(rule)
      |> validate_trigger(rule)
      |> validate_invocations(rule)
      |> validate_capability_grants(rule)
      |> validate_authority_required(rule)
      |> validate_priority(rule)

    case errors do
      [] -> :ok
      errs -> {:error, Enum.reverse(errs)}
    end
  end

  def validate_rule(_), do: {:error, ["rule must be a map"]}

  @doc """
  Validates a list of rules. Returns `:ok` if all rules pass, or
  `{:error, %{rule_id => errors}}` mapping failing rule ids to
  their error lists. Errors sharing a key are combined.
  """
  @spec validate_rules([term()]) :: :ok | {:error, %{String.t() => [String.t()]}}
  def validate_rules(rules) when is_list(rules) and is_integer(length(rules)) do
    failures =
      rules
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {rule, idx}, acc ->
        case validate_rule(rule) do
          :ok ->
            acc

          {:error, errs} ->
            Map.update(acc, rule_error_id(rule, idx), Enum.reverse(errs), &Enum.reverse(errs, &1))
        end
      end)
      |> Map.new(fn {key, errors} -> {key, Enum.reverse(errors)} end)

    failures =
      Map.merge(failures, ExMaude.Validation.duplicate_ids(rules), fn _, a, b -> a ++ b end)

    if failures == %{}, do: :ok, else: {:error, failures}
  end

  def validate_rules(_), do: {:error, %{"rules" => ["rules must be a list"]}}

  defp validate_required_fields(errors, rule) do
    [:id, :agent_id, :trigger, :invocations]
    |> Enum.reduce(errors, fn field, acc ->
      if Map.has_key?(rule, field), do: acc, else: ["missing required field: #{field}" | acc]
    end)
  end

  defp validate_id(errors, %{id: id}) when is_binary(id) do
    if valid_nonempty_string?(id), do: errors, else: ["id must be a non-empty string" | errors]
  end

  defp validate_id(errors, %{id: _}), do: ["id must be a non-empty string" | errors]
  defp validate_id(errors, _), do: errors

  defp validate_agent_id(errors, %{agent_id: {tenant_id, agent_name}}) do
    if valid_nonempty_string?(tenant_id) and valid_nonempty_string?(agent_name) do
      errors
    else
      ["agent_id must be a {tenant_id, agent_name} tuple of non-empty strings" | errors]
    end
  end

  defp validate_agent_id(errors, %{agent_id: _}) do
    ["agent_id must be a {tenant_id, agent_name} tuple of non-empty strings" | errors]
  end

  defp validate_agent_id(errors, _), do: errors

  defp validate_trigger(errors, %{trigger: trigger}) do
    case validate_predicate(trigger) do
      :ok -> errors
      {:error, msg} -> ["trigger: #{msg}" | errors]
    end
  end

  defp validate_trigger(errors, _), do: errors

  defp validate_invocations(errors, %{invocations: invocations})
       when is_list(invocations) and is_integer(length(invocations)) do
    invocations
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {inv, idx}, acc ->
      case validate_invocation(inv) do
        :ok -> acc
        {:error, msg} -> ["invocation[#{idx}]: #{msg}" | acc]
      end
    end)
  end

  defp validate_invocations(errors, %{invocations: _}) do
    ["invocations must be a list" | errors]
  end

  defp validate_invocations(errors, _), do: errors

  defp validate_capability_grants(errors, %{capability_grants: grants})
       when is_list(grants) and is_integer(length(grants)) do
    grants
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {grant, idx}, acc ->
      case validate_capability(grant) do
        :ok -> acc
        {:error, msg} -> ["capability_grants[#{idx}]: #{msg}" | acc]
      end
    end)
  end

  defp validate_capability_grants(errors, %{capability_grants: _}) do
    ["capability_grants must be a list" | errors]
  end

  defp validate_capability_grants(errors, _), do: errors

  defp validate_authority_required(errors, %{authority_required: a})
       when is_integer(a) and a >= 0,
       do: errors

  defp validate_authority_required(errors, %{authority_required: _}) do
    ["authority_required must be a non-negative integer" | errors]
  end

  defp validate_authority_required(errors, _), do: errors

  defp validate_priority(errors, %{priority: p}) when is_integer(p) and p >= 0, do: errors

  defp validate_priority(errors, %{priority: _}) do
    ["priority must be a non-negative integer" | errors]
  end

  defp validate_priority(errors, _), do: errors

  @doc false
  @spec validate_predicate(term()) :: :ok | {:error, String.t()}
  def validate_predicate(predicate), do: validate_predicate(predicate, 0)

  defp validate_predicate(_, depth) when depth > 10,
    do: {:error, "predicate nesting exceeds maximum depth of 10"}

  defp validate_predicate({:always}, _), do: :ok

  defp validate_predicate({prop_op, key, value}, _)
       when prop_op in [:prop_eq, :prop_gt, :prop_lt, :prop_gte, :prop_lte] do
    if valid_string?(key),
      do: validate_value(value),
      else: invalid_predicate({prop_op, key, value})
  end

  defp validate_predicate({:capability_required, name}, _) do
    if valid_nonempty_string?(name),
      do: :ok,
      else: invalid_predicate({:capability_required, name})
  end

  defp validate_predicate({:capability_granted, name}, _) do
    if valid_nonempty_string?(name),
      do: :ok,
      else: invalid_predicate({:capability_granted, name})
  end

  defp validate_predicate({:budget_within, scope, {:interval, lo, hi}} = predicate, _) do
    if valid_string?(scope) and is_integer(lo) and is_integer(hi) and lo >= 0 and hi >= lo,
      do: :ok,
      else: invalid_predicate(predicate)
  end

  defp validate_predicate({:authority_at_least, n}, _) when is_integer(n) and n >= 0, do: :ok
  defp validate_predicate({:authority_required, n}, _) when is_integer(n) and n >= 0, do: :ok

  defp validate_predicate({:jurisdiction_allowed, j}, _) when j in @all_jurisdictions,
    do: :ok

  defp validate_predicate({:jurisdiction_forbidden, j}, _) when j in @all_jurisdictions,
    do: :ok

  defp validate_predicate({:latency_at_most, ms}, _) when is_integer(ms) and ms >= 0, do: :ok

  defp validate_predicate({:and, p1, p2}, depth) do
    with :ok <- validate_predicate(p1, depth + 1) do
      validate_predicate(p2, depth + 1)
    end
  end

  defp validate_predicate({:or, p1, p2}, depth) do
    with :ok <- validate_predicate(p1, depth + 1) do
      validate_predicate(p2, depth + 1)
    end
  end

  defp validate_predicate({:not, p}, depth), do: validate_predicate(p, depth + 1)

  defp validate_predicate({:contains, _, _}, _),
    do: {:error, "unsupported :contains predicate; ai-rules.maude does not implement it"}

  defp validate_predicate({:matches, _, _}, _),
    do: {:error, "unsupported :matches predicate; ai-rules.maude does not implement it"}

  defp validate_predicate(other, _),
    do: {:error, "unsupported predicate shape: #{inspect(other)}"}

  @doc false
  @spec validate_invocation(term()) :: :ok | {:error, String.t()}
  def validate_invocation({:invoke_tool, name, args, cap_required, jurisdiction} = invocation) do
    if valid_nonempty_string?(name) and is_map(args) and not is_struct(args) and
         valid_nonempty_string?(cap_required) and jurisdiction in @all_jurisdictions do
      case validate_arg_map(args) do
        :ok -> :ok
        {:error, msg} -> {:error, "invoke_tool args: #{msg}"}
      end
    else
      {:error, "unsupported invocation shape: #{inspect(invocation)}"}
    end
  end

  def validate_invocation({:require_approval, class} = invocation) do
    if valid_nonempty_string?(class),
      do: :ok,
      else: {:error, "unsupported invocation shape: #{inspect(invocation)}"}
  end

  def validate_invocation(other), do: {:error, "unsupported invocation shape: #{inspect(other)}"}

  defp validate_arg_map(args) when is_map(args) do
    result = Enum.reduce_while(args, :ok, fn {k, v}, _ -> validate_arg_entry(k, v) end)

    if result == :ok and map_size(args) != length(Enum.uniq_by(Map.keys(args), &to_string/1)),
      do: {:error, "argument keys must be unique after string conversion"},
      else: result
  end

  defp rule_error_id(%{id: id}, _) when is_binary(id) and id != "", do: id
  defp rule_error_id(_, idx), do: "<index #{idx}>"

  defp validate_arg_entry(key, value) do
    if valid_arg_key?(key) do
      validate_arg_value(key, value)
    else
      {:halt, {:error, "unsupported argument key: #{inspect(key)}"}}
    end
  end

  defp validate_arg_value(key, value) do
    case validate_value(value) do
      :ok -> {:cont, :ok}
      {:error, msg} -> {:halt, {:error, "key #{inspect(key)}: #{msg}"}}
    end
  end

  @doc false
  @spec validate_capability(term()) :: :ok | {:error, String.t()}
  def validate_capability({:cap, name, shape} = capability) do
    if valid_nonempty_string?(name) and valid_string?(shape),
      do: :ok,
      else: {:error, "unsupported capability shape: #{inspect(capability)}"}
  end

  def validate_capability(name) when is_binary(name) do
    if valid_nonempty_string?(name),
      do: :ok,
      else: {:error, "unsupported capability shape: #{inspect(name)}"}
  end

  def validate_capability(other), do: {:error, "unsupported capability shape: #{inspect(other)}"}

  @doc false
  @spec validate_value(term()) :: :ok | {:error, String.t()}
  def validate_value({:str, s}) when is_binary(s) do
    if valid_string?(s), do: :ok, else: invalid_value({:str, s})
  end

  def validate_value({:int, n}) when is_integer(n), do: :ok
  def validate_value({:bool, b}) when is_boolean(b), do: :ok

  def validate_value({:interval, lo, hi})
      when is_integer(lo) and is_integer(hi) and lo >= 0 and hi >= lo,
      do: :ok

  def validate_value({:jurisdiction, j}) when j in @all_jurisdictions, do: :ok
  def validate_value(nil), do: :ok

  def validate_value(s) when is_binary(s) do
    if valid_string?(s), do: :ok, else: invalid_value(s)
  end

  def validate_value(n) when is_integer(n), do: :ok
  def validate_value(b) when is_boolean(b), do: :ok

  def validate_value(other), do: invalid_value(other)

  @doc false
  @spec validate_jurisdictions(term()) :: :ok | {:error, ExMaude.Error.t()}
  def validate_jurisdictions(jurisdictions)
      when is_list(jurisdictions) and is_integer(length(jurisdictions)) do
    if Enum.all?(jurisdictions, &(&1 in @all_jurisdictions)) do
      :ok
    else
      {:error,
       ExMaude.Error.new(
         :validation,
         "jurisdictions must use the supported Maude jurisdiction enumeration"
       )}
    end
  end

  def validate_jurisdictions(_) do
    {:error, ExMaude.Error.new(:validation, "jurisdictions must be a list")}
  end

  defp valid_arg_key?(key) when is_atom(key), do: valid_string?(Atom.to_string(key))
  defp valid_arg_key?(key), do: valid_string?(key)

  defp valid_nonempty_string?(value), do: valid_string?(value) and value != ""
  defp valid_string?(value), do: ExMaude.Validation.string?(value)

  defp invalid_predicate(predicate),
    do: {:error, "unsupported predicate shape: #{inspect(predicate)}"}

  defp invalid_value(value), do: {:error, "unsupported value shape: #{inspect(value)}"}
end
