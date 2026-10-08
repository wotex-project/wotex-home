defmodule WotexHome.Schedules.ActivationClock do
  @moduledoc "Canonical retained activation calculation. Decoding is historical correspondence, never host clock authority."
  alias WotexHome.{Id, Schedules.ClockSample, Schedules.Codec}
  alias WotexHome.Profiles.Codec, as: ProfileCodec
  alias WotexHome.Durable.Store.ClockContext
  alias WotexHome.Schedules.Planner
  @format "wotex-home.schedule-activation-clock.v1"
  @monotonic_format "wotex-home.schedule-activation-monotonic-clock.v1"
  @scope ~w(deployment_id owner_id authority_epoch store_boot_epoch clock_generation runtime_digest)
  @maximum_due 253_402_300_739_999

  def capture(source, clock) do
    with {:ok, snapshot} <- ClockContext.temporal(clock),
         {:ok, zone} <- ClockContext.timezone(clock, source),
         :ok <- Planner.cadence(source, zone),
         {:ok, watermark} <- initial(source, snapshot),
         {:ok, document} <- encode(snapshot, watermark),
         do: {:ok, document, watermark},
         else: (error -> error)
  end

  def initial(source, snapshot) do
    with {:ok, _} <- Codec.encode(source), :ok <- snapshot?(snapshot) do
      case source["trigger"] do
        ["countdown", boot, generation, start, duration] ->
          cond do
            boot != snapshot.scope["store_boot_epoch"] -> {:error, :old_boot}
            generation != snapshot.scope["clock_generation"] -> {:error, :clock_changed}
            start > snapshot.now_ms -> {:error, :schedule_basis_changed}
            start + duration <= snapshot.now_ms -> {:error, :schedule_elapsed}
            true -> {:ok, snapshot.now_ms}
          end

        _ when snapshot.interval != nil ->
          {lower, upper} = snapshot.interval

          cond do
            upper - lower > 2 * source["uncertainty_tolerance_ms"] ->
              {:error, :clock_uncertain}

            upper > @maximum_due ->
              {:error, :schedule_elapsed}

            true ->
              {:ok, upper}
          end

        _ ->
          {:error, :temporal_clock_unavailable}
      end
    end
  end

  @doc "Current source-specific clock correspondence; a countdown deadline need not still be in the future."
  def ready(source, snapshot) do
    with {:ok, _} <- Codec.encode(source), :ok <- snapshot?(snapshot) do
      case source["trigger"] do
        ["countdown", boot, generation, _, _] ->
          cond do
            boot != snapshot.scope["store_boot_epoch"] -> {:error, :old_boot}
            generation != snapshot.scope["clock_generation"] -> {:error, :clock_changed}
            true -> :ok
          end

        _ ->
          if snapshot.interval == nil, do: {:error, :temporal_clock_unavailable}, else: :ok
      end
    end
  end

  @doc "Owned current readiness, separate from the original activation boundary."
  def current(source, clock) do
    with {:ok, snapshot} <- ClockContext.temporal(clock),
         {:ok, zone} <- ClockContext.timezone(clock, source),
         :ok <- Planner.cadence(source, zone),
         :ok <- ready(source, snapshot),
         :ok <- current_boundary(source, snapshot),
         do: {:ok, snapshot}
  end

  defp current_boundary(%{"trigger" => ["countdown" | _]}, _), do: :ok

  defp current_boundary(source, snapshot) do
    with {:ok, _} <- initial(source, snapshot), do: :ok
  end

  def encode(snapshot, watermark) do
    with :ok <- snapshot?(snapshot),
         true <- Codec.integer?(watermark, 0, Codec.maximum()),
         {:ok, sample_document} <- ClockSample.encode(snapshot.sample),
         {:ok, sample} <- Codec.record(sample_document),
         document =
           JSON.encode!([
             format(snapshot),
             Enum.map(@scope, &snapshot.scope[&1]),
             sample,
             snapshot.now_ms,
             watermark
           ]),
         true <- byte_size(document) <= 4_096,
         do: {:ok, document},
         else: (_ -> {:error, :invalid_schedule_activation_clock})
  end

  def decode(document) do
    with {:ok, [format, scope, sample, now, watermark]} <- Codec.record(document),
         true <- format in [@format, @monotonic_format],
         true <- is_list(scope) and length(scope) == length(@scope),
         {:ok, sample} <- ClockSample.decode(JSON.encode!(sample)),
         scope = Map.new(Enum.zip(@scope, scope)),
         {:ok, interval, reason} <- retained_confidence(format, sample, scope, now),
         snapshot = %{
           scope: scope,
           sample: sample,
           now_ms: now,
           interval: interval,
           reason: reason
         },
         {:ok, ^document} <- encode(snapshot, watermark),
         do: {:ok, snapshot, watermark},
         else: (_ -> {:error, :invalid_schedule_activation_clock})
  end

  defp snapshot?(snapshot) do
    with true <- Codec.exact?(snapshot, [:scope, :sample, :now_ms, :interval, :reason]),
         true <- Codec.exact?(snapshot.scope, @scope),
         true <-
           Enum.all?(
             ~w(deployment_id owner_id runtime_digest),
             &ProfileCodec.digest?(snapshot.scope[&1])
           ),
         true <- Id.valid?(snapshot.scope["store_boot_epoch"]),
         true <-
           Enum.all?(
             ~w(authority_epoch clock_generation),
             &Codec.integer?(snapshot.scope[&1], 1, Codec.maximum())
           ),
         true <- snapshot.sample["boot_epoch"] == snapshot.scope["store_boot_epoch"],
         true <- snapshot.sample["generation"] == snapshot.scope["clock_generation"],
         {:ok, interval, reason} <-
           retained_confidence(format(snapshot), snapshot.sample, snapshot.scope, snapshot.now_ms),
         true <- snapshot.interval == interval,
         true <- snapshot.reason == reason,
         do: :ok,
         else: (_ -> {:error, :temporal_clock_unavailable})
  rescue
    _ -> {:error, :temporal_clock_unavailable}
  end

  defp format(%{sample: %{"wall_confidence" => "unqualified"}}), do: @monotonic_format
  defp format(_), do: @format

  defp retained_confidence(@format, %{"wall_confidence" => "qualified"} = sample, scope, now) do
    with {:ok, interval} <-
           ClockSample.advance(sample, scope["store_boot_epoch"], scope["clock_generation"], now),
         do: {:ok, interval, nil}
  end

  defp retained_confidence(
         @monotonic_format,
         %{"wall_confidence" => "unqualified"} = sample,
         scope,
         now
       ) do
    with {:ok, ^now} <-
           ClockSample.monotonic(
             sample,
             scope["store_boot_epoch"],
             scope["clock_generation"],
             now
           ),
         do: {:ok, nil, :temporal_clock_unavailable}
  end

  defp retained_confidence(_, _, _, _), do: {:error, :temporal_clock_unavailable}
end
