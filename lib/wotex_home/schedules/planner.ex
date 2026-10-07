defmodule WotexHome.Schedules.Planner do
  @moduledoc "Bounded pure single-schedule polling with a monotonic considered-through cursor; no Store mutation or trusted time."
  alias WotexHome.Schedules.{ClockSample, Codec, Occurrence, Recurrence, Tzif, Window}

  @maximum_due 253_402_300_739_999

  def plan(source, watermark, sample, boot, generation, now, zone \\ nil) do
    with {:ok, _} <- Codec.encode(source),
         :ok <- cadence(source, zone) do
      case source["trigger"] do
        ["countdown", _, _, _, _] ->
          countdown(source, watermark, sample, boot, generation, now)

        _ ->
          utc(source, watermark, sample, boot, generation, now, zone)
      end
    end
  end

  # Consecutive selected local dates are at least one day apart. The complete
  # pinned offset span therefore gives a conservative minimum UTC spacing.
  # A larger span needs a separate multi-candidate temporal profile.
  def cadence(source, zone \\ nil) do
    with :ok <- Recurrence.validate_source(source, zone) do
      case source["trigger"] do
        [kind | _] when kind in ["daily", "weekdays"] ->
          if match?(%Tzif{}, zone) and List.last(zone.offsets) - hd(zone.offsets) <= 86_340,
            do: :ok,
            else: {:error, :unsupported_temporal_cadence}

        ["once" | _] ->
          :ok

        _ ->
          if zone == nil, do: :ok, else: {:error, :unexpected_timezone_basis}
      end
    end
  end

  defp utc(source, watermark, sample, boot, generation, now, zone) do
    with true <- Codec.integer?(watermark, -1, @maximum_due),
         {:ok, {lower, upper}} <- ClockSample.advance(sample, boot, generation, now),
         cutoff = min(@maximum_due, max(watermark, lower - source["late_window_ms"])),
         {:ok, due} <- Recurrence.next(source, cutoff, zone) do
      missed = if cutoff > watermark, do: [watermark, cutoff]
      next_watermark = max(watermark, min(lower, @maximum_due))

      if due != nil and due <= lower do
        decision =
          if upper - lower <= 2 * source["uncertainty_tolerance_ms"] and
               upper < due + source["late_window_ms"],
             do: :eligible,
             else: :uncertain

        {:ok,
         %{
           decision: decision,
           coordinate: ["utc", due],
           watermark: next_watermark,
           missed_range: missed
         }}
      else
        {:ok,
         %{decision: :idle, coordinate: nil, watermark: next_watermark, missed_range: missed}}
      end
    else
      false -> {:error, :invalid_schedule_cursor}
      error -> error
    end
  end

  defp countdown(source, watermark, sample, boot, generation, now) do
    with true <- Codec.integer?(watermark, -1, Codec.maximum()),
         ["countdown", bound_boot, bound_generation, start, duration] <- source["trigger"],
         due = start + duration,
         {:ok, occurrence} <-
           Occurrence.build(source, 1, 1, ["countdown", bound_boot, bound_generation, due]),
         {:ok, decision} <- Window.check(source, occurrence, sample, boot, generation, now) do
      cond do
        due <= watermark ->
          {:ok,
           %{decision: :idle, coordinate: nil, watermark: max(watermark, now), missed_range: nil}}

        decision == :early ->
          {:ok,
           %{decision: :idle, coordinate: nil, watermark: max(watermark, now), missed_range: nil}}

        true ->
          {:ok,
           %{
             decision: decision,
             coordinate: occurrence["coordinate"],
             watermark: max(watermark, now),
             missed_range: nil
           }}
      end
    else
      false -> {:error, :invalid_schedule_cursor}
      error -> error
    end
  end
end
