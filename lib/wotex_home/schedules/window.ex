defmodule WotexHome.Schedules.Window do
  @moduledoc "Pure zero-early half-open occurrence window check; eligibility is never admission or dispatch permission."
  alias WotexHome.Schedules.{ClockSample, Codec, Occurrence}

  def check(source, occurrence, sample, boot, generation, now) do
    if Occurrence.current?(occurrence, source) do
      check_coordinate(source, occurrence["coordinate"], sample, boot, generation, now)
    else
      {:error, :schedule_occurrence_mismatch}
    end
  end

  defp check_coordinate(source, ["utc", due], sample, boot, generation, now) do
    with :ok <- utc_coordinate(source["trigger"], due) do
      with {:ok, {lower, upper}} <- ClockSample.advance(sample, boot, generation, now) do
        finish = due + source["late_window_ms"]

        cond do
          upper - lower > 2 * source["uncertainty_tolerance_ms"] -> {:ok, :uncertain}
          upper < due -> {:ok, :early}
          lower >= finish -> {:ok, :expired}
          lower >= due and upper < finish -> {:ok, :eligible}
          true -> {:ok, :uncertain}
        end
      end
    end
  end

  defp check_coordinate(
         source,
         ["countdown", bound_boot, bound_generation, due],
         sample,
         boot,
         generation,
         now
       ) do
    with ["countdown", ^bound_boot, ^bound_generation, start, duration] <- source["trigger"],
         true <- due == start + duration,
         {:ok, _} <- ClockSample.encode(sample),
         true <- Codec.integer?(now, 0, Codec.maximum()) do
      cond do
        boot != bound_boot or sample["boot_epoch"] != boot ->
          {:error, :old_boot}

        generation != bound_generation or sample["generation"] != generation ->
          {:error, :clock_changed}

        now < sample["sampled_monotonic_ms"] ->
          {:error, :clock_rollback}

        not sample["monotonic_continuous"] ->
          {:error, :clock_discontinuous}

        now - sample["sampled_monotonic_ms"] > sample["maximum_age_ms"] ->
          {:error, :clock_stale}

        now < due ->
          {:ok, :early}

        now >= due + source["late_window_ms"] ->
          {:ok, :expired}

        true ->
          {:ok, :eligible}
      end
    else
      _ -> {:error, :schedule_coordinate_mismatch}
    end
  end

  defp utc_coordinate(["once", _, _, _, _, due], due), do: :ok

  defp utc_coordinate(["interval", anchor, period, start, finish], due) do
    if due >= anchor and due >= start and (finish == nil or due < finish) and
         rem(due - anchor, period) == 0,
       do: :ok,
       else: {:error, :schedule_coordinate_mismatch}
  end

  defp utc_coordinate([kind | _], _) when kind in ["daily", "weekdays"],
    do: {:error, :timezone_basis_required}

  defp utc_coordinate(_, _), do: {:error, :schedule_coordinate_mismatch}
end
