defmodule WotexHome.Rules.RuntimeGate do
  @moduledoc """
  Pure whole-Thing safety and operator-lease filter for draft proposals.

  The caller must derive invariants and leases from current authenticated
  authority. This map carries no command or transport capability.

  `decisions/5` returns a decision for each target in a proposed effect set.
  A denied or unknown invariant blocks the whole-Thing effect; an active
  operator lease can suppress competing automation. Rebuild the inputs from
  current state when the proposal reaches durable admission.
  """

  alias WotexHome.Id
  alias WotexHome.Rules.OverrideLease

  @max_i64 9_223_372_036_854_775_807

  @spec decisions(
          [String.t()],
          %{String.t() => :allow | :deny | :unknown},
          [OverrideLease.t()],
          non_neg_integer(),
          non_neg_integer()
        ) ::
          {:ok, %{String.t() => :allow | :safety_denied | :safety_unknown | :operator_override}}
          | {:error, atom()}
  def decisions(target_ids, invariants, leases, authority_epoch, now_ms)
      when is_list(target_ids) and is_map(invariants) and is_list(leases) and
             length(target_ids) <= 128 and length(leases) <= 128 and
             is_integer(authority_epoch) and authority_epoch >= 0 and
             authority_epoch <= @max_i64 and is_integer(now_ms) and now_ms >= 0 and
             now_ms <= @max_i64 do
    if Enum.all?(target_ids, &Id.valid?/1) and Enum.uniq(target_ids) == target_ids and
         Map.keys(invariants) |> Enum.sort() == Enum.sort(target_ids) and
         Enum.all?(Map.values(invariants), &(&1 in [:allow, :deny, :unknown])) and
         Enum.all?(leases, &OverrideLease.valid?/1) and
         Enum.all?(leases, &(&1.target_id in target_ids)) do
      active =
        leases
        |> Enum.filter(&OverrideLease.active?(&1, authority_epoch, now_ms))
        |> MapSet.new(& &1.target_id)

      {:ok,
       Map.new(target_ids, fn target_id ->
         decision =
           case invariants[target_id] do
             :deny -> :safety_denied
             :unknown -> :safety_unknown
             :allow -> if MapSet.member?(active, target_id), do: :operator_override, else: :allow
           end

         {target_id, decision}
       end)}
    else
      {:error, :invalid_runtime_gate}
    end
  end

  def decisions(_, _, _, _, _), do: {:error, :invalid_runtime_gate}
end
