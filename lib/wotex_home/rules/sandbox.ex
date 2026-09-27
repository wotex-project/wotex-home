defmodule WotexHome.Rules.Sandbox do
  @moduledoc """
  Credential-free draft rule evaluator with bounded runtime prevention.

  This is not the admitted runtime. Callers must provide current facts and
  desired values; stale data must be supplied as unknown. Returned proposals
  have no outbox or driver capability.
  """

  alias WotexHome.Rules.{Event, Predicate, Rule}
  alias WotexHome.Semantics.Value

  @max_i64 9_223_372_036_854_775_807
  @enforce_keys [:rules, :last_fired_ms, :root_counts]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @spec new([Rule.t()]) :: {:ok, t()} | {:error, atom()}
  def new(rules) when is_list(rules) and length(rules) > 0 and length(rules) <= 64 do
    if Enum.all?(rules, &Rule.valid?/1) and unique_ids?(rules),
      do:
        {:ok,
         %__MODULE__{rules: Enum.sort_by(rules, & &1.id), last_fired_ms: %{}, root_counts: %{}}},
      else: {:error, :invalid_rule_set}
  end

  def new(_rules), do: {:error, :invalid_rule_set}

  @spec step(t(), Event.t(), map(), map(), non_neg_integer()) ::
          {:ok, map(), t()} | {:error, atom()}
  def step(%__MODULE__{} = sandbox, event, facts, desired, now_ms) do
    gate =
      if valid_state?(sandbox) do
        Map.new(sandbox.rules, fn rule -> {elem(rule.effect, 0), :allow} end)
      else
        %{}
      end

    step(sandbox, event, facts, desired, now_ms, gate)
  end

  def step(_sandbox, _event, _facts, _desired, _now_ms), do: {:error, :invalid_step}

  @doc "Step with an explicit current whole-Thing safety/override gate."
  @spec step(t(), Event.t(), map(), map(), non_neg_integer(), map()) ::
          {:ok, map(), t()} | {:error, atom()}
  def step(%__MODULE__{} = sandbox, %Event{} = event, facts, desired, now_ms, gate)
      when is_map(facts) and is_map(desired) and is_integer(now_ms) and now_ms >= 0 and
             now_ms <= @max_i64 and map_size(facts) <= 128 and map_size(desired) <= 128 do
    if not Event.valid?(event) or not valid_state?(sandbox) or not valid_gate?(sandbox, gate) do
      {:error, :invalid_step}
    else
      step_valid_event(sandbox, event, facts, desired, now_ms, gate)
    end
  end

  def step(_sandbox, _event, _facts, _desired, _now_ms, _gate), do: {:error, :invalid_step}

  defp step_valid_event(sandbox, event, facts, desired, now_ms, gate) do
    if map_size(sandbox.root_counts) >= 64 and
         not Map.has_key?(sandbox.root_counts, event.root_id) do
      {:error, :root_capacity}
    else
      {candidates, suppressed} =
        Enum.reduce(sandbox.rules, {[], %{}}, fn rule, {candidates, suppressed} ->
          case candidate(rule, event, facts, desired, now_ms, sandbox, gate) do
            {:ok, proposal} -> {[proposal | candidates], suppressed}
            {:skip, reason} -> {candidates, Map.put(suppressed, rule.id, reason)}
          end
        end)

      {proposals, conflicts, suppressed} = arbitrate(Enum.reverse(candidates), suppressed)

      {proposals, suppressed} =
        enforce_root_budget(
          proposals,
          sandbox.rules,
          Map.get(sandbox.root_counts, event.root_id, 0),
          suppressed
        )

      accepted_count = length(proposals)

      updated = %{
        sandbox
        | last_fired_ms:
            Enum.reduce(proposals, sandbox.last_fired_ms, fn proposal, acc ->
              Map.put(acc, proposal.rule_id, now_ms)
            end),
          root_counts:
            if(accepted_count > 0,
              do:
                Map.update(
                  sandbox.root_counts,
                  event.root_id,
                  accepted_count,
                  &(&1 + accepted_count)
                ),
              else: sandbox.root_counts
            )
      }

      {:ok,
       %{
         proposals: proposals,
         conflicts: conflicts,
         suppressed: suppressed,
         root_id: event.root_id
       }, updated}
    end
  end

  @spec finish_root(t(), String.t()) :: t()
  def finish_root(%__MODULE__{} = sandbox, root_id),
    do: %{sandbox | root_counts: Map.delete(sandbox.root_counts, root_id)}

  defp candidate(rule, event, facts, desired, now_ms, sandbox, gate) do
    {target_id, capability_key, value} = rule.effect
    root_count = Map.get(sandbox.root_counts, event.root_id, 0)
    last_fired = Map.get(sandbox.last_fired_ms, rule.id)

    cond do
      not trigger?(rule, event) ->
        {:skip, :trigger_not_matched}

      gate[target_id] != :allow ->
        {:skip, gate[target_id]}

      Predicate.evaluate(rule.predicate, facts) != true ->
        {:skip, :predicate_false_or_unknown}

      event.depth >= rule.causal_budget or root_count >= rule.causal_budget ->
        {:skip, :causal_budget_exhausted}

      is_integer(last_fired) and now_ms - last_fired < rule.cooldown_ms ->
        {:skip, :cooldown}

      same_known?(Map.get(desired, {target_id, capability_key}, :unknown), value) ->
        {:skip, :desired_noop}

      true ->
        {:ok,
         %{
           rule_id: rule.id,
           target_id: target_id,
           capability_key: capability_key,
           value: value,
           root_id: event.root_id,
           depth: event.depth + 1,
           ownership_ms: rule.ownership_ms
         }}
    end
  end

  defp trigger?(%Rule{id: id, trigger: {:explicit_request, nil}}, %Event{
         kind: :explicit_request,
         rule_id: id
       }),
       do: true

  defp trigger?(%Rule{trigger: {:rising_edge, fact}}, %Event{
         kind: :edge,
         origin: :reported,
         fact: fact,
         before: false,
         after_value: true
       }),
       do: true

  defp trigger?(%Rule{trigger: {:falling_edge, fact}}, %Event{
         kind: :edge,
         origin: :reported,
         fact: fact,
         before: true,
         after_value: false
       }),
       do: true

  defp trigger?(_rule, _event), do: false

  defp same_known?({:known, %Value{} = actual}, expected), do: actual == expected
  defp same_known?(_actual, _expected), do: false

  defp arbitrate(candidates, suppressed) do
    grouped = Enum.group_by(candidates, & &1.target_id)

    Enum.reduce(grouped, {[], [], suppressed}, fn {target_id, domain},
                                                  {accepted, conflicts, suppressed} ->
      effects = Enum.map(domain, &{&1.capability_key, &1.value}) |> Enum.uniq()

      if length(effects) == 1 do
        [winner | equivalent] = Enum.sort_by(domain, & &1.rule_id)

        suppressed =
          Enum.reduce(equivalent, suppressed, fn proposal, acc ->
            Map.put(acc, proposal.rule_id, :equivalent_effect)
          end)

        {[winner | accepted], conflicts, suppressed}
      else
        conflict = %{
          target_id: target_id,
          rule_ids: Enum.map(domain, & &1.rule_id) |> Enum.sort()
        }

        suppressed =
          Enum.reduce(domain, suppressed, fn proposal, acc ->
            Map.put(acc, proposal.rule_id, :effect_conflict)
          end)

        {accepted, [conflict | conflicts], suppressed}
      end
    end)
    |> then(fn {accepted, conflicts, suppressed} ->
      {Enum.sort_by(accepted, & &1.rule_id), Enum.sort_by(conflicts, & &1.target_id), suppressed}
    end)
  end

  defp unique_ids?(rules) do
    ids = Enum.map(rules, & &1.id)
    length(ids) == length(Enum.uniq(ids))
  end

  defp valid_state?(%__MODULE__{rules: rules, last_fired_ms: last_fired, root_counts: roots}) do
    is_list(rules) and length(rules) in 1..64 and Enum.all?(rules, &Rule.valid?/1) and
      unique_ids?(rules) and is_map(last_fired) and map_size(last_fired) <= 64 and
      Enum.all?(last_fired, fn {id, time} ->
        Enum.any?(rules, &(&1.id == id)) and is_integer(time) and time >= 0 and time <= @max_i64
      end) and is_map(roots) and map_size(roots) <= 64 and
      Enum.all?(roots, fn {root_id, count} ->
        WotexHome.Id.valid?(root_id) and is_integer(count) and count >= 0 and
          count <= @max_i64
      end)
  end

  defp valid_gate?(sandbox, gate) when is_map(gate) do
    targets = sandbox.rules |> Enum.map(&elem(&1.effect, 0)) |> Enum.uniq() |> Enum.sort()

    Enum.sort(Map.keys(gate)) == targets and
      Enum.all?(
        Map.values(gate),
        &(&1 in [:allow, :safety_denied, :safety_unknown, :operator_override])
      )
  end

  defp valid_gate?(_sandbox, _gate), do: false

  defp enforce_root_budget([], _rules, _root_count, suppressed), do: {[], suppressed}

  defp enforce_root_budget(proposals, rules, root_count, suppressed) do
    budgets = Map.new(rules, &{&1.id, &1.causal_budget})
    limit = proposals |> Enum.map(&Map.fetch!(budgets, &1.rule_id)) |> Enum.min()

    if root_count + length(proposals) <= limit do
      {proposals, suppressed}
    else
      suppressed =
        Enum.reduce(proposals, suppressed, fn proposal, acc ->
          Map.put(acc, proposal.rule_id, :causal_budget_exhausted)
        end)

      {[], suppressed}
    end
  end
end
