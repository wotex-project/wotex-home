defmodule WotexHome.Schedules.SourceCorrespondence do
  @moduledoc """
  Finite window/cursor correspondence over the actual admitted source parameters.

  Calendar coordinates are supplied by the independently parsed raw-byte reference
  after finite phase/date-branch correspondence with the production recurrence.
  It supplies neither clock confidence nor autonomous execution authority.
  """
  alias WotexHome.Schedules.{CalendarCorrespondence, Codec, Occurrence, Planner, Window}

  @maximum_due 253_402_300_739_999
  @maximum_utc 253_402_300_799_999
  @boot "boot:source-correspondence"

  def check(source, zone \\ nil) do
    with {:ok, _} <- Codec.encode(source),
         :ok <- Planner.cadence(source, zone),
         {:ok, coordinates} <- coordinates(source, zone),
         :ok <- windows(source, zone, coordinates),
         :ok <- cursors(source, zone, coordinates),
         do: :ok
  end

  defp coordinates(%{"trigger" => ["countdown", boot, generation, start, duration]}, _),
    do: {:ok, [["countdown", boot, generation, start + duration]]}

  defp coordinates(%{"trigger" => ["interval" | _]} = source, _),
    do: {:ok, interval_coordinates(source, -1, [], 4)}

  defp coordinates(source, zone), do: CalendarCorrespondence.coordinates(source, zone)

  defp interval_coordinates(_, _, coordinates, 0), do: Enum.reverse(coordinates)

  defp interval_coordinates(source, after_ms, coordinates, remaining) do
    case reference_due(source, [], after_ms) do
      nil -> Enum.reverse(coordinates)
      due -> interval_coordinates(source, due, [["utc", due] | coordinates], remaining - 1)
    end
  end

  defp windows(source, zone, coordinates) do
    Enum.reduce_while(coordinates, :ok, fn coordinate, :ok ->
      case window(source, zone, coordinate) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp window(source, zone, ["utc", due] = coordinate) do
    {:ok, occurrence} = Occurrence.build(source, 1, 1, coordinate)
    finish = due + source["late_window_ms"]
    tolerance = source["uncertainty_tolerance_ms"]
    lower_points = Enum.uniq([due - 1, due, due + 1, finish - 1, finish, finish + 1])
    widths = Enum.uniq([0, 1, 2 * tolerance, 2 * tolerance + 1, source["late_window_ms"]])

    for lower <- lower_points,
        width <- widths,
        lower >= 0 and lower + width <= @maximum_utc,
        reduce: :ok do
      :ok ->
        upper = lower + width
        expected = utc_window(lower, upper, due, finish, tolerance)
        {clock, now} = utc_sample(lower, upper)

        compare(
          Window.check(source, occurrence, clock, @boot, 1, now, zone),
          {:ok, expected}
        )

      error ->
        error
    end
  end

  defp window(source, zone, ["countdown", boot, generation, due] = coordinate) do
    {:ok, occurrence} = Occurrence.build(source, 1, 1, coordinate)
    [_, _, _, start, _] = source["trigger"]
    finish = due + source["late_window_ms"]
    changed_boot = if boot == @boot, do: "boot:other-correspondence", else: @boot
    changed_generation = if generation == Codec.maximum(), do: 1, else: generation + 1

    checks = [
      {boot, generation, start - 1, {:error, :clock_rollback}},
      {boot, generation, due - 1, {:ok, :early}},
      {boot, generation, due, {:ok, :eligible}},
      {boot, generation, finish - 1, {:ok, :eligible}},
      {boot, generation, finish, {:ok, :expired}},
      {changed_boot, generation, due, {:error, :old_boot}},
      {boot, changed_generation, due, {:error, :clock_changed}}
    ]

    Enum.reduce_while(checks, :ok, fn {current_boot, current_generation, now, expected}, :ok ->
      if now < 0 do
        {:cont, :ok}
      else
        clock = monotonic_sample(boot, generation, max(start, now))
        expected = monotonic_expected(clock, now, expected)

        case compare(
               Window.check(
                 source,
                 occurrence,
                 clock,
                 current_boot,
                 current_generation,
                 now,
                 zone
               ),
               expected
             ) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end
    end)
  end

  # Independent containment formulation, retaining the precision-first ordering.
  defp utc_window(lower, upper, due, finish, tolerance) do
    case {upper - lower <= 2 * tolerance, upper < due, lower >= finish,
          lower >= due and upper < finish} do
      {false, _, _, _} -> :uncertain
      {true, true, _, _} -> :early
      {true, _, true, _} -> :expired
      {true, _, _, true} -> :eligible
      _ -> :uncertain
    end
  end

  defp cursors(%{"trigger" => ["countdown", boot, generation, start, _]} = source, zone, [c]) do
    [_, _, _, due] = c
    finish = due + source["late_window_ms"]

    for watermark <- Enum.uniq([start, due - 1, due, finish]),
        now <- Enum.uniq([start, due - 1, due, finish - 1, finish]),
        reduce: :ok do
      :ok ->
        phase = if now < due, do: :early, else: if(now < finish, do: :eligible, else: :expired)
        selected = watermark < due and phase != :early

        expected = %{
          decision: if(selected, do: phase, else: :idle),
          coordinate: if(selected, do: c),
          watermark: max(watermark, now),
          missed_range: nil
        }

        clock = monotonic_sample(boot, generation, now)

        compare(
          Planner.plan(
            source,
            watermark,
            clock,
            boot,
            generation,
            now,
            zone
          ),
          monotonic_expected(clock, now, {:ok, expected})
        )

      error ->
        error
    end
  end

  defp cursors(source, zone, coordinates) do
    # Keep the final supplied coordinate as lookahead for minimum-cadence cases.
    probes = if length(coordinates) > 1, do: Enum.drop(coordinates, -1), else: coordinates

    points =
      Enum.flat_map(probes, fn ["utc", due] ->
        [
          due - 1,
          due,
          due + 1,
          due + source["late_window_ms"] - 1,
          due + source["late_window_ms"]
        ]
      end)

    points = if points == [], do: empty_points(source), else: points
    points = Enum.uniq(Enum.filter(points, &(&1 >= 0 and &1 <= @maximum_utc)))
    watermarks = Enum.uniq([-1 | Enum.filter(points, &(&1 <= @maximum_due))])
    tolerance = source["uncertainty_tolerance_ms"]

    for watermark <- watermarks,
        lower <- points,
        width <- Enum.uniq([0, 2 * tolerance, 2 * tolerance + 1]),
        lower + width <= @maximum_utc,
        reduce: :ok do
      :ok ->
        expected = utc_plan(source, coordinates, watermark, lower, lower + width)
        {clock, now} = utc_sample(lower, lower + width)

        compare(
          Planner.plan(source, watermark, clock, @boot, 1, now, zone),
          {:ok, expected}
        )

      error ->
        error
    end
  end

  defp empty_points(%{"trigger" => ["interval", _, _, start, finish]}),
    do: [0, start - 1, start, finish || @maximum_due, @maximum_due]

  defp empty_points(%{"trigger" => ["daily", _, _, _, start, finish]}),
    do: [0, start - 1, start, finish || @maximum_due, @maximum_due]

  defp empty_points(%{"trigger" => ["weekdays", _, _, _, _, start, finish]}),
    do: [0, start - 1, start, finish || @maximum_due, @maximum_due]

  defp utc_plan(source, coordinates, watermark, lower, upper) do
    cutoff = min(@maximum_due, max(watermark, lower - source["late_window_ms"]))
    due = reference_due(source, coordinates, cutoff)
    selected = due != nil and due <= lower

    %{
      decision:
        if(selected,
          do:
            if(
              upper - lower <= 2 * source["uncertainty_tolerance_ms"] and
                upper < due + source["late_window_ms"],
              do: :eligible,
              else: :uncertain
            ),
          else: :idle
        ),
      coordinate: if(selected, do: ["utc", due]),
      watermark: max(watermark, min(lower, @maximum_due)),
      missed_range: if(cutoff > watermark, do: [watermark, cutoff])
    }
  end

  defp reference_due(%{"trigger" => ["interval", anchor, period, start, finish]}, _, cutoff) do
    # Strict-after floor arithmetic, separate from the production ceiling formula.
    previous = max(start - 1, cutoff)
    index = if previous < anchor, do: 0, else: div(previous - anchor, period) + 1
    due = anchor + index * period
    if due <= @maximum_due and (finish == nil or due < finish), do: due
  end

  defp reference_due(_source, coordinates, cutoff),
    do: Enum.find_value(coordinates, fn ["utc", due] -> if due > cutoff, do: due end)

  defp compare(value, value), do: :ok
  defp compare(_, _), do: {:error, :source_correspondence_failed}

  defp sample(lower, upper) do
    %{
      "source_id" => "clock:source-correspondence",
      "qualification_digest" => String.duplicate("a", 64),
      "boot_epoch" => @boot,
      "generation" => 1,
      "sampled_monotonic_ms" => 0,
      "utc_lower_ms" => lower,
      "utc_upper_ms" => upper,
      "maximum_age_ms" => 600_000,
      "drift_ppm" => 0,
      "wall_confidence" => "qualified",
      "monotonic_continuous" => true
    }
  end

  defp utc_sample(lower, upper) do
    elapsed = max(0, upper - @maximum_due)
    {sample(lower - elapsed, upper - elapsed), elapsed}
  end

  defp monotonic_expected(clock, now, {:ok, _} = expected) do
    if now - clock["sampled_monotonic_ms"] > clock["maximum_age_ms"],
      do: {:error, :clock_stale},
      else: expected
  end

  defp monotonic_expected(_, _, expected), do: expected

  defp monotonic_sample(boot, generation, now) do
    %{
      sample(0, 0)
      | "boot_epoch" => boot,
        "generation" => generation,
        "sampled_monotonic_ms" => min(now, Codec.maximum() - 600_600),
        "utc_lower_ms" => nil,
        "utc_upper_ms" => nil,
        "wall_confidence" => "unqualified"
    }
  end
end
