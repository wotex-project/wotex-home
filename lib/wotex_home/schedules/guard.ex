defmodule WotexHome.Schedules.Guard do
  @moduledoc "Closed pure temporal precedence. The Store must establish every input from current owned state."
  alias WotexHome.Schedules.Codec

  @booleans ~w(maintenance active_generation current_admission current_author current_target current_profile capacity_available considered)a
  @fields @booleans ++ [:invariant, :override, :window, :active_count]

  def decision(input) do
    if Codec.exact?(input, @fields) and Enum.all?(@booleans, &is_boolean(input[&1])) and
         input.invariant in [:allow, :deny, :unknown] and input.override in [:none, :live] and
         input.window in [:early, :eligible, :uncertain, :expired] and
         Codec.integer?(input.active_count, 0, 64) do
      {:ok, decide(input)}
    else
      {:error, :invalid_schedule_guards}
    end
  end

  defp decide(input) do
    cond do
      input.maintenance -> :maintenance_active
      input.active_count != 1 -> :composed_temporal_unsupported
      not input.active_generation -> :stale_rule_generation
      not input.current_admission -> :schedule_basis_changed
      not input.current_author -> :author_unavailable
      not input.current_target -> :permission_denied
      not input.current_profile -> :profile_unavailable
      input.invariant != :allow -> :invariant_unresolved
      input.override == :live -> :operator_override_active
      input.considered -> :occurrence_already_considered
      input.window == :early -> :occurrence_early
      input.window == :uncertain -> :clock_uncertain
      input.window == :expired -> :occurrence_expired
      not input.capacity_available -> :scheduler_capacity
      true -> :allow
    end
  end
end
