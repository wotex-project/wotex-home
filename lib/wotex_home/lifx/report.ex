defmodule WotexHome.Lifx.Report do
  @moduledoc """
  Pure conversion of a correlated LIFX light reply into Home reports.

  The caller has already checked the UDP endpoint, target and in-boot ledger.
  This module accepts only the capabilities declared by the qualified Thing.
  A LIFX packet sequence is eight-bit; the caller supplies a monotonic Home
  report sequence and rotates its source epoch before that sequence resets.

  `from_response/3` maps the supported LightState or power response into
  typed observations after all transport checks have passed. Give it the
  current qualified Thing and trusted receive metadata; missing capabilities
  stay absent instead of being inferred from a vendor packet.
  """

  alias WotexHome.Durable.Registry
  alias WotexHome.Semantics.{Capability, Observation, Thing}

  @meta_keys ~w(source_epoch source_sequence boot_epoch received_time_utc_ms received_monotonic_ms)
  @u16_max 65_535

  @spec from_response(Thing.t(), map(), map()) ::
          {:ok, [Observation.t()]} | {:error, atom()}
  def from_response(%Thing{role: "Light"} = thing, response, metadata)
      when is_map(response) and is_map(metadata) do
    with {:ok, _document} <- Registry.encode_thing(thing),
         true <- Enum.sort(Map.keys(metadata)) == Enum.sort(@meta_keys),
         {:ok, values} <- values(response),
         {:ok, observations} <- observations(thing, values, metadata) do
      {:ok, observations}
    else
      _ -> {:error, :invalid_lifx_report}
    end
  end

  def from_response(_thing, _response, _metadata), do: {:error, :invalid_lifx_report}

  defp values(%{kind: :light_power, on?: on?, raw_level: level} = response)
       when map_size(response) == 3 and is_boolean(on?) and is_integer(level) and
              level >= 0 and level <= @u16_max do
    if on? == (level != 0),
      do: {:ok, [{"power", %{"type" => "boolean", "value" => on?}}]},
      else: {:error, :invalid_lifx_report}
  end

  defp values(
         %{
           kind: :light_state,
           hue: hue,
           saturation: saturation,
           brightness: brightness,
           kelvin: kelvin,
           power_on?: on?,
           raw_power: power,
           label: label
         } = response
       )
       when map_size(response) == 8 and is_boolean(on?) and is_binary(label) and
              byte_size(label) <= 32 and is_integer(hue) and hue >= 0 and hue <= @u16_max and
              is_integer(saturation) and saturation >= 0 and saturation <= @u16_max and
              is_integer(brightness) and brightness >= 0 and brightness <= @u16_max and
              is_integer(kelvin) and kelvin >= 0 and kelvin <= @u16_max and
              is_integer(power) and power >= 0 and power <= @u16_max do
    if on? == (power != 0) do
      {:ok,
       [
         {"power", %{"type" => "boolean", "value" => on?}},
         {"brightness", %{"type" => "fraction", "ppm" => fraction(brightness)}},
         {"colour_hsv",
          %{
            "type" => "hsv",
            "hue_mdeg" => div(hue * 360_000, 65_536),
            "saturation_ppm" => fraction(saturation)
          }},
         {"colour_temperature", %{"type" => "kelvin", "kelvin" => kelvin}}
       ]}
    else
      {:error, :invalid_lifx_report}
    end
  end

  defp values(_response), do: {:error, :invalid_lifx_report}

  defp fraction(raw), do: div(raw * 1_000_000 + div(@u16_max, 2), @u16_max)

  defp observations(thing, values, metadata) do
    Enum.reduce_while(values, {:ok, []}, fn {key, value}, {:ok, acc} ->
      case Thing.capability(thing, key) do
        {:ok, %Capability{} = capability} ->
          input = %{
            "thing_id" => thing.id,
            "capability_key" => key,
            "value" => value,
            "quality" => "reported",
            "trust" => "unauthenticated_local",
            "source_epoch" => metadata["source_epoch"],
            "source_sequence" => metadata["source_sequence"],
            "boot_epoch" => metadata["boot_epoch"],
            "source_time_utc_ms" => nil,
            "received_time_utc_ms" => metadata["received_time_utc_ms"],
            "received_monotonic_ms" => metadata["received_monotonic_ms"]
          }

          if Capability.supports?(capability, "read") do
            case Observation.new(input, capability) do
              {:ok, observation} -> {:cont, {:ok, [observation | acc]}}
              _ -> {:halt, {:error, :invalid_lifx_report}}
            end
          else
            {:halt, {:error, :invalid_lifx_report}}
          end

        :error ->
          {:cont, {:ok, acc}}
      end
    end)
    |> case do
      {:ok, observations} when observations != [] -> {:ok, Enum.reverse(observations)}
      _ -> {:error, :invalid_lifx_report}
    end
  end
end
