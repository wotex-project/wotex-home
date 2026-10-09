defmodule WotexHome.Rules.ArbitrationReference do
  @moduledoc "Independent all-pairs reference for provided draft proposal sets; no admission or effects."
  alias WotexHome.Id
  alias WotexHome.Semantics.Value

  @fields ~w(rule_id target_id capability_key value root_id depth ownership_ms)a

  def batch(candidates, limit)
      when is_list(candidates) and length(candidates) <= 64 and is_integer(limit) and
             limit in 1..16 do
    if valid_set?(candidates) do
      ordered = Enum.sort_by(candidates, & &1.rule_id)

      conflicted =
        for left <- ordered,
            right <- ordered,
            left.target_id == right.target_id,
            left.capability_key != right.capability_key or left.value != right.value,
            into: MapSet.new(),
            do: left.target_id

      {proposals, _, suppressed} =
        Enum.reduce(ordered, {[], MapSet.new(), %{}}, fn candidate,
                                                         {accepted, seen, suppressed} ->
          cond do
            MapSet.member?(conflicted, candidate.target_id) ->
              {accepted, seen, Map.put(suppressed, candidate.rule_id, :effect_conflict)}

            MapSet.member?(seen, candidate.target_id) ->
              {accepted, seen, Map.put(suppressed, candidate.rule_id, :equivalent_effect)}

            true ->
              {accepted ++ [candidate], MapSet.put(seen, candidate.target_id), suppressed}
          end
        end)

      groups =
        for target <- ordered |> Enum.map(& &1.target_id) |> Enum.uniq() |> Enum.sort() do
          %{
            target_id: target,
            members: Enum.filter(ordered, &(&1.target_id == target)),
            state: if(MapSet.member?(conflicted, target), do: :conflict, else: :compatible)
          }
        end

      conflicts =
        for target <- Enum.sort(conflicted),
            do: %{
              target_id: target,
              rule_ids:
                for(candidate <- ordered, candidate.target_id == target, do: candidate.rule_id)
            }

      arbitration = %{
        proposals: proposals,
        conflicts: conflicts,
        suppressed: suppressed,
        groups: groups
      }

      eligible =
        for proposal <- proposals,
            do: Enum.find(groups, &(&1.target_id == proposal.target_id))

      {:ok,
       %{
         arbitration: arbitration,
         selected_groups: Enum.take(eligible, limit),
         capacity_blocked_groups: Enum.drop(eligible, limit)
       }}
    else
      invalid()
    end
  end

  def batch(_, _), do: invalid()

  defp valid_set?(candidates) do
    Enum.all?(candidates, &valid_proposal?/1) and
      Enum.map(candidates, & &1.rule_id) |> then(&(Enum.uniq(&1) == &1))
  end

  defp valid_proposal?(candidate) when is_map(candidate) do
    Enum.sort(Map.keys(candidate)) == Enum.sort(@fields) and
      Enum.all?(
        [candidate.rule_id, candidate.target_id, candidate.capability_key, candidate.root_id],
        &Id.valid?/1
      ) and
      is_integer(candidate.depth) and candidate.depth >= 1 and candidate.depth <= 32 and
      is_integer(candidate.ownership_ms) and candidate.ownership_ms >= 1 and
      candidate.ownership_ms <= 86_400_000 and
      match?(%Value{}, candidate.value) and map_size(candidate.value) == 3 and
      Value.valid?(candidate.value)
  end

  defp valid_proposal?(_), do: false
  defp invalid, do: {:error, :invalid_proposal_set}
end
