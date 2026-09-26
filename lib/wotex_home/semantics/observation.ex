defmodule WotexHome.Semantics.Observation do
  @moduledoc """
  Reported evidence with explicit trust, quality and boot-scoped freshness.

  A valid report is not physical proof. An old, unknown or wrong-boot report
  never becomes a current false or zero.
  """

  alias WotexHome.Id
  alias WotexHome.Semantics.{Capability, Value}

  @keys ~w(thing_id capability_key value quality trust source_epoch source_sequence boot_epoch source_time_utc_ms received_time_utc_ms received_monotonic_ms)
  @trust ~w(unauthenticated_local authenticated_device bridge_attested synthetic_lab)
  @enforce_keys [
    :thing_id,
    :capability_key,
    :value,
    :quality,
    :trust,
    :source_epoch,
    :source_sequence,
    :boot_epoch,
    :source_time_utc_ms,
    :received_time_utc_ms,
    :received_monotonic_ms
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @spec new(map(), Capability.t()) :: {:ok, t()} | {:error, atom()}
  def new(input, %Capability{} = capability) when is_map(input) do
    with :ok <- closed(input),
         :ok <- identity(input, capability),
         :ok <- metadata(input),
         {:ok, value} <- value(input, capability) do
      {:ok,
       struct!(__MODULE__,
         thing_id: input["thing_id"],
         capability_key: input["capability_key"],
         value: value,
         quality: input["quality"],
         trust: input["trust"],
         source_epoch: input["source_epoch"],
         source_sequence: input["source_sequence"],
         boot_epoch: input["boot_epoch"],
         source_time_utc_ms: input["source_time_utc_ms"],
         received_time_utc_ms: input["received_time_utc_ms"],
         received_monotonic_ms: input["received_monotonic_ms"]
       )}
    end
  end

  def new(_input, _capability), do: {:error, :invalid_observation}

  @spec current_value(t(), Capability.t(), String.t(), non_neg_integer()) ::
          {:ok, Value.t()} | :unknown
  def current_value(
        %__MODULE__{quality: "reported", value: %Value{} = value} = observation,
        %Capability{} = capability,
        boot_epoch,
        now_monotonic_ms
      )
      when is_integer(now_monotonic_ms) do
    elapsed = now_monotonic_ms - observation.received_monotonic_ms

    if observation.boot_epoch == boot_epoch and observation.thing_id == capability.thing_id and
         observation.capability_key == capability.key and elapsed >= 0 and
         elapsed <= capability.freshness_ms,
       do: {:ok, value},
       else: :unknown
  end

  def current_value(_observation, _capability, _boot_epoch, _now), do: :unknown

  defp closed(input) do
    if Enum.sort(Map.keys(input)) == Enum.sort(@keys),
      do: :ok,
      else: {:error, :invalid_fields}
  end

  defp identity(input, capability) do
    if input["thing_id"] == capability.thing_id and input["capability_key"] == capability.key and
         Id.valid?(input["source_epoch"]) and Id.valid?(input["boot_epoch"]),
       do: :ok,
       else: {:error, :invalid_identity}
  end

  defp metadata(input) do
    if input["quality"] in ["reported", "unknown"] and input["trust"] in @trust and
         nonnegative_integer?(input["source_sequence"]) and
         (is_nil(input["source_time_utc_ms"]) or nonnegative_integer?(input["source_time_utc_ms"])) and
         nonnegative_integer?(input["received_time_utc_ms"]) and
         nonnegative_integer?(input["received_monotonic_ms"]),
       do: :ok,
       else: {:error, :invalid_metadata}
  end

  defp value(%{"quality" => "unknown", "value" => nil}, _capability), do: {:ok, nil}

  defp value(%{"quality" => "reported", "value" => raw}, capability) do
    with {:ok, value} <- Value.new(raw),
         true <- Capability.accepts?(capability, value) do
      {:ok, value}
    else
      _ -> {:error, :invalid_value}
    end
  end

  defp value(_input, _capability), do: {:error, :invalid_value}

  defp nonnegative_integer?(value), do: is_integer(value) and value >= 0
end
