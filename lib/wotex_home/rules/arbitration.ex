defmodule WotexHome.Rules.Arbitration do
  @moduledoc """
  Pure arbitration of a complete bounded set of equal-authority draft proposals.

  Coupled capabilities share a whole-Thing domain. Every domain is resolved
  before an optional batch cutoff; incompatible effects have no winner. A
  compatible group's representative is deterministic, and all original members
  remain available for subsequent authority and causal checks.

  These results contain no admission, lease, receipt or transport authority.
  The caller must establish complete-set membership and current permissions.
  """
  alias WotexHome.Id
  alias WotexHome.Semantics.Value

  @fields ~w(rule_id target_id capability_key value root_id depth ownership_ms)a

  def resolve(candidates) when is_list(candidates) and length(candidates) <= 64 do
    if Enum.all?(candidates, &proposal?/1) and
         length(Enum.uniq_by(candidates, & &1.rule_id)) == length(candidates) do
      groups =
        candidates
        |> Enum.group_by(& &1.target_id)
        |> Enum.map(fn {target, members} ->
          members = Enum.sort_by(members, & &1.rule_id)
          effects = Enum.uniq_by(members, &{&1.capability_key, &1.value})

          %{
            target_id: target,
            members: members,
            state: if(length(effects) == 1, do: :compatible, else: :conflict)
          }
        end)
        |> Enum.sort_by(& &1.target_id)

      {proposals, conflicts, suppressed} =
        Enum.reduce(groups, {[], [], %{}}, fn group, {accepted, conflicts, suppressed} ->
          case group.state do
            :compatible ->
              [representative | equivalent] = group.members
              suppressed = suppress(equivalent, :equivalent_effect, suppressed)
              {[representative | accepted], conflicts, suppressed}

            :conflict ->
              conflict = %{
                target_id: group.target_id,
                rule_ids: Enum.map(group.members, & &1.rule_id)
              }

              {accepted, [conflict | conflicts],
               suppress(group.members, :effect_conflict, suppressed)}
          end
        end)

      {:ok,
       %{
         proposals: Enum.sort_by(proposals, & &1.rule_id),
         conflicts: Enum.sort_by(conflicts, & &1.target_id),
         suppressed: suppressed,
         groups: groups
       }}
    else
      invalid()
    end
  end

  def resolve(_), do: invalid()

  @doc "Resolve all domains before selecting up to sixteen independent compatible groups."
  def batch(candidates, limit \\ 16)

  def batch(candidates, limit) when is_integer(limit) and limit in 1..16 do
    with {:ok, arbitration} <- resolve(candidates) do
      compatible =
        arbitration.groups
        |> Enum.filter(&(&1.state == :compatible))
        |> Enum.sort_by(fn group -> hd(group.members).rule_id end)

      {selected, blocked} = Enum.split(compatible, limit)

      {:ok,
       %{
         arbitration: arbitration,
         selected_groups: selected,
         capacity_blocked_groups: blocked
       }}
    end
  end

  def batch(_, _), do: invalid()

  defp proposal?(proposal) when is_map(proposal) and map_size(proposal) == 7 do
    Enum.sort(Map.keys(proposal)) == Enum.sort(@fields) and
      Enum.all?(~w(rule_id target_id capability_key root_id)a, &Id.valid?(proposal[&1])) and
      is_integer(proposal.depth) and proposal.depth in 1..32 and
      is_integer(proposal.ownership_ms) and proposal.ownership_ms in 1..86_400_000 and
      is_struct(proposal.value, Value) and map_size(proposal.value) == 3 and
      Value.valid?(proposal.value)
  end

  defp proposal?(_), do: false

  defp suppress(proposals, reason, suppressed),
    do: Enum.reduce(proposals, suppressed, &Map.put(&2, &1.rule_id, reason))

  defp invalid, do: {:error, :invalid_proposal_set}
end
