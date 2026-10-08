defmodule WotexHome.Schedules.ActivationClock do
  @moduledoc "Canonical retained activation calculation. Decoding is historical correspondence, never host clock authority."
  alias WotexHome.{Id, Schedules.ClockSample, Schedules.Codec}
  alias WotexHome.Profiles.Codec, as: ProfileCodec
  alias WotexHome.Durable.Store.ClockContext
  alias WotexHome.Schedules.Planner
  @format "wotex-home.schedule-activation-clock.v1"
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

        _ ->
          {lower, upper} = snapshot.interval

          cond do
            upper - lower > 2 * source["uncertainty_tolerance_ms"] ->
              {:error, :clock_uncertain}

            upper > @maximum_due ->
              {:error, :schedule_elapsed}

            true ->
              {:ok, upper}
          end
      end
    end
  end

  def encode(snapshot, watermark) do
    with :ok <- snapshot?(snapshot),
         true <- Codec.integer?(watermark, 0, Codec.maximum()),
         {:ok, sample_document} <- ClockSample.encode(snapshot.sample),
         {:ok, sample} <- Codec.record(sample_document),
         document =
           JSON.encode!([
             @format,
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
    with {:ok, [@format, scope, sample, now, watermark]} <- Codec.record(document),
         true <- is_list(scope) and length(scope) == length(@scope),
         {:ok, sample} <- ClockSample.decode(JSON.encode!(sample)),
         scope = Map.new(Enum.zip(@scope, scope)),
         {:ok, interval} <-
           ClockSample.advance(sample, scope["store_boot_epoch"], scope["clock_generation"], now),
         snapshot = %{scope: scope, sample: sample, now_ms: now, interval: interval, reason: nil},
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
         true <- is_nil(snapshot.reason),
         true <- snapshot.sample["boot_epoch"] == snapshot.scope["store_boot_epoch"],
         true <- snapshot.sample["generation"] == snapshot.scope["clock_generation"],
         {:ok, interval} <-
           ClockSample.advance(
             snapshot.sample,
             snapshot.scope["store_boot_epoch"],
             snapshot.scope["clock_generation"],
             snapshot.now_ms
           ),
         true <- snapshot.interval == interval,
         do: :ok,
         else: (_ -> {:error, :temporal_clock_unavailable})
  rescue
    _ -> {:error, :temporal_clock_unavailable}
  end
end
