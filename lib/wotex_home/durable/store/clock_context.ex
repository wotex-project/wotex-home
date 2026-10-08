defmodule WotexHome.Durable.Store.ClockContext do
  @moduledoc "Lazy Store-owned receipt, temporal and timezone callbacks for one borrowed writer call. Legacy receipt clocks establish no temporal confidence."
  alias WotexHome.{
    Id,
    Schedules.ClockSample,
    Schedules.Codec,
    Schedules.TemporalBasis,
    Schedules.Tzif
  }

  alias WotexHome.Profiles.Codec, as: ProfileCodec
  @enforce_keys [:receipt, :temporal, :timezone]
  defstruct @enforce_keys

  @scope ~w(deployment_id owner_id authority_epoch store_boot_epoch clock_generation runtime_digest)
  @snapshot [:scope, :sample, :now_ms, :interval, :reason]

  def new(receipt, temporal, timezone)
      when is_function(receipt, 0) and is_function(temporal, 0) and is_function(timezone, 1),
      do: {:ok, %__MODULE__{receipt: receipt, temporal: temporal, timezone: timezone}}

  def new(_, _, _), do: {:error, :invalid_clock_context}

  def receipt(%__MODULE__{receipt: callback}) when is_function(callback, 0), do: callback.()
  def receipt(callback) when is_function(callback, 0), do: callback.()
  def receipt(_), do: {nil, -1}

  def temporal(%__MODULE__{} = context) do
    with before_read = receipt(context),
         {:ok, snapshot} <- context.temporal.(),
         after_read = receipt(context),
         :ok <- validate(snapshot, before_read, after_read),
         do: {:ok, snapshot}
  rescue
    _ -> unavailable()
  catch
    _, _ -> unavailable()
  end

  def temporal(_), do: unavailable()

  def timezone(%__MODULE__{} = context, source) do
    with {:ok, _} <- Codec.encode(source),
         {:ok, zone} <- context.timezone.(source),
         true <- zone?(source, zone),
         do: {:ok, zone},
         else: (_ -> {:error, :timezone_basis_changed})
  rescue
    _ -> {:error, :timezone_basis_changed}
  catch
    _, _ -> {:error, :timezone_basis_changed}
  end

  def timezone(_, _), do: {:error, :timezone_basis_changed}

  defp validate(snapshot, {boot, earlier}, {boot, later}) do
    with true <- Id.valid?(boot) and Codec.integer?(earlier, 0, Codec.maximum()),
         true <- Codec.integer?(later, earlier, Codec.maximum()),
         true <- Codec.exact?(snapshot, @snapshot),
         true <- Codec.exact?(snapshot.scope, @scope),
         true <-
           Enum.all?(
             ~w(deployment_id owner_id runtime_digest),
             &ProfileCodec.digest?(snapshot.scope[&1])
           ),
         true <-
           Enum.all?(
             ~w(authority_epoch clock_generation),
             &Codec.integer?(snapshot.scope[&1], 1, Codec.maximum())
           ),
         true <- snapshot.scope["store_boot_epoch"] == boot,
         true <- Codec.integer?(snapshot.now_ms, earlier, later),
         {:ok, _} <- ClockSample.encode(snapshot.sample),
         true <-
           snapshot.sample["boot_epoch"] == boot and
             snapshot.sample["generation"] == snapshot.scope["clock_generation"],
         true <- snapshot.sample["sampled_monotonic_ms"] <= snapshot.now_ms,
         :ok <- confidence(snapshot),
         do: :ok,
         else: (_ -> unavailable())
  end

  defp validate(_, _, _), do: unavailable()

  defp confidence(%{sample: %{"wall_confidence" => "qualified"}} = snapshot) do
    with true <- is_nil(snapshot.reason),
         {:ok, interval} <-
           ClockSample.advance(
             snapshot.sample,
             snapshot.scope["store_boot_epoch"],
             snapshot.scope["clock_generation"],
             snapshot.now_ms
           ),
         true <- interval == snapshot.interval,
         do: :ok,
         else: (_ -> unavailable())
  end

  defp confidence(%{
         sample: %{"wall_confidence" => "unqualified"},
         interval: nil,
         reason: :temporal_clock_unavailable
       }),
       do: :ok

  defp confidence(_), do: unavailable()

  defp zone?(source, nil), do: is_nil(TemporalBasis.timezone_digest(source))

  defp zone?(%{"trigger" => [kind, name, digest | _]}, %Tzif{} = zone)
       when kind in ["once", "daily", "weekdays"],
       do: zone.name == name and zone.digest == digest and Tzif.valid?(zone)

  defp zone?(_, _), do: false
  defp unavailable, do: {:error, :temporal_clock_unavailable}
end
