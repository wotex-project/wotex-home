defmodule WotexHome.Lifx.ColorPlan do
  @moduledoc """
  Pure translation of one typed partial Light colour request into complete HSBK.

  All three baseline colour reports must come from the same fresh, correlated
  LightState event. This module constructs no packet and grants no authority.
  The caller must serialize the whole-light effect domain and recheck the
  baseline before a claimed command is handed to a transport.
  """

  alias WotexHome.Durable.Registry
  alias WotexHome.Id
  alias WotexHome.Mutation
  alias WotexHome.Semantics.{Capability, Observation, Thing, Value}

  @keys ~w(colour_hsv brightness colour_temperature)
  @max_i64 9_223_372_036_854_775_807

  @enforce_keys [
    :thing_id,
    :operation_id,
    :declaration_digest,
    :baseline,
    :baseline_raw_hsbk,
    :raw_hsbk,
    :requested
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @spec new(Thing.t(), Mutation.t(), map(), String.t(), non_neg_integer()) ::
          {:ok, t()} | {:error, atom()}
  def new(%Thing{role: "Light"} = thing, %Mutation{} = mutation, reports, boot_epoch, now_ms)
      when is_map(reports) do
    with {:ok, document} <- Registry.encode_thing(thing),
         true <-
           Mutation.valid?(mutation) and mutation.target_id == thing.id and
             mutation.capability_key in @keys,
         true <- Id.valid?(boot_epoch) and valid_time?(now_ms),
         {:ok, target_capability} <- Thing.capability(thing, mutation.capability_key),
         true <- Capability.supports?(target_capability, "write"),
         {:ok, requested} <- Value.new(mutation.value),
         true <- Capability.accepts?(target_capability, requested),
         {:ok, baseline_values, baseline} <- baseline(thing, reports, boot_epoch, now_ms) do
      selected =
        case {mutation.capability_key, requested} do
          {"brightness", %Value{kind: :fraction, data: level}} ->
            %{baseline_values | brightness: level}

          {"colour_hsv", %Value{kind: :hsv, data: {new_hue, new_saturation}}} ->
            %{baseline_values | hue: new_hue, saturation: new_saturation}

          {"colour_temperature", %Value{kind: :kelvin, data: new_kelvin}} ->
            %{baseline_values | saturation: 0, kelvin: new_kelvin}
        end

      raw = raw_hsbk(selected)

      {:ok,
       %__MODULE__{
         thing_id: thing.id,
         operation_id: mutation.operation_id,
         declaration_digest: :crypto.hash(:sha256, document),
         baseline: baseline,
         baseline_raw_hsbk: raw_hsbk(baseline_values),
         raw_hsbk: raw,
         requested: mutation.capability_key
       }}
    else
      _ -> {:error, :color_plan_unavailable}
    end
  end

  def new(_thing, _mutation, _reports, _boot_epoch, _now_ms),
    do: {:error, :color_plan_unavailable}

  @doc "Rebuild the plan from current declared state and require exact identity before handoff."
  @spec recheck(t(), Thing.t(), Mutation.t(), map(), String.t(), non_neg_integer()) ::
          :ok | {:error, :color_plan_stale}
  def recheck(%__MODULE__{} = plan, thing, mutation, reports, boot_epoch, now_ms) do
    case new(thing, mutation, reports, boot_epoch, now_ms) do
      {:ok, ^plan} -> :ok
      _ -> {:error, :color_plan_stale}
    end
  end

  def recheck(_plan, _thing, _mutation, _reports, _boot_epoch, _now_ms),
    do: {:error, :color_plan_stale}

  @doc "Whether the requested complete wire value already equals the fresh reported baseline."
  @spec no_effect?(t()) :: boolean()
  def no_effect?(%__MODULE__{baseline_raw_hsbk: baseline, raw_hsbk: desired}),
    do: baseline == desired

  defp baseline(thing, reports, boot_epoch, now_ms) do
    if Enum.sort(Map.keys(reports)) == Enum.sort(@keys) do
      @keys
      |> Enum.reduce_while({:ok, %{}, []}, fn key, {:ok, values, stamps} ->
        with {:ok, capability} <- Thing.capability(thing, key),
             true <- Capability.supports?(capability, "read"),
             %Observation{} = observation <- Map.fetch!(reports, key),
             true <- Observation.valid?(observation, capability),
             true <- observation.trust == "unauthenticated_local",
             {:ok, value} <-
               Observation.current_value(observation, capability, boot_epoch, now_ms) do
          stamp =
            {observation.source_epoch, observation.source_sequence, observation.boot_epoch,
             observation.received_time_utc_ms, observation.received_monotonic_ms}

          {:cont, {:ok, Map.put(values, key, value), [stamp | stamps]}}
        else
          _ -> {:halt, {:error, :invalid_baseline}}
        end
      end)
      |> case do
        {:ok, values, [stamp, second, third]} when stamp == second and second == third ->
          {:ok,
           %{
             hue: elem(values["colour_hsv"].data, 0),
             saturation: elem(values["colour_hsv"].data, 1),
             brightness: values["brightness"].data,
             kelvin: values["colour_temperature"].data
           }, stamp}

        _ ->
          {:error, :invalid_baseline}
      end
    else
      {:error, :invalid_baseline}
    end
  end

  defp hue_raw(hue_mdeg), do: rem(div(hue_mdeg * 65_536 + 180_000, 360_000), 65_536)
  defp fraction_raw(ppm), do: div(ppm * 65_535 + 500_000, 1_000_000)

  defp raw_hsbk(values) do
    %{
      hue: hue_raw(values.hue),
      saturation: fraction_raw(values.saturation),
      brightness: fraction_raw(values.brightness),
      kelvin: values.kelvin
    }
  end

  defp valid_time?(time), do: is_integer(time) and time >= 0 and time <= @max_i64
end
