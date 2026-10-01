defmodule WotexHome.Hue.V2 do
  @moduledoc """
  Closed read-only Hue v2 request paths and bounded reported resource mapping.

  The protocol reference is OpenHue 1ffc817857abf456d5ff2ae50400ef768dbce28e.
  Only bridge identity and individual Light resources are projected. This
  module carries neither credentials nor transport/persistence authority.
  Reported power, brightness and valid mirek remain bridge claims; this does
  not establish reachability, physical light output or control qualification.
  """
  @max_body_bytes 262_144
  @max_depth 16
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @bridge ~r/\A[0-9a-f]{16}\z/

  def path(:bridges), do: {:ok, "/clip/v2/resource/bridge"}
  def path(:lights), do: {:ok, "/clip/v2/resource/light"}

  def path({:light, id}) do
    if uuid?(id), do: {:ok, "/clip/v2/resource/light/" <> id}, else: {:error, :invalid_hue_query}
  end

  def path(_), do: {:error, :invalid_hue_query}

  def response(body, query, bridge_id)
      when is_binary(body) and byte_size(body) in 1..@max_body_bytes do
    with {:ok, _} <- path(query),
         true <- bridge_id?(bridge_id),
         {:ok, %{"errors" => [], "data" => data} = envelope} <- decode_object(body),
         true <- map_size(envelope) == 2 and is_list(data) and length(data) <= 256,
         {:ok, reports} <- project(data, query, bridge_id),
         true <- length(reports) == length(Enum.uniq_by(reports, & &1.resource_id)),
         :ok <- selected(reports, query) do
      {:ok, reports}
    else
      _ -> {:error, :invalid_hue_response}
    end
  end

  def response(_, _, _), do: {:error, :invalid_hue_response}

  def bridge_id?(value), do: is_binary(value) and value =~ @bridge
  def uuid?(value), do: is_binary(value) and value =~ @uuid

  defp project(data, query, bridge) do
    Enum.reduce_while(data, {:ok, []}, fn resource, {:ok, reports} ->
      case resource(resource, query, bridge) do
        {:ok, report} -> {:cont, {:ok, [report | reports]}}
        _ -> {:halt, {:error, :invalid_hue_resource}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp resource(%{"id" => id, "type" => "bridge", "bridge_id" => bridge}, :bridges, bridge) do
    if uuid?(id),
      do: {:ok, %{resource_id: id, bridge_id: bridge}},
      else: {:error, :invalid_bridge_resource}
  end

  defp resource(
         %{
           "id" => id,
           "type" => "light",
           "owner" => %{"rid" => device, "rtype" => "device"},
           "on" => %{"on" => power},
           "mode" => mode
         } = light,
         query,
         _bridge
       )
       when query == :lights or is_tuple(query) do
    with true <-
           uuid?(id) and uuid?(device) and is_boolean(power) and mode in ["normal", "streaming"],
         {:ok, brightness} <- brightness(light),
         {:ok, temperature} <- temperature(light) do
      {:ok,
       %{
         resource_id: id,
         device_id: device,
         power: power,
         mode: mode,
         brightness_ppm: brightness,
         colour_temperature_kelvin: temperature
       }}
    else
      _ -> {:error, :invalid_light_resource}
    end
  end

  defp resource(_, _, _), do: {:error, :invalid_hue_resource}

  defp brightness(%{"dimming" => %{"brightness" => value}})
       when is_number(value) and value >= 0 and value <= 100,
       do: {:ok, round(value * 10_000)}

  defp brightness(light) do
    if Map.has_key?(light, "dimming"), do: {:error, :invalid_brightness}, else: {:ok, nil}
  end

  defp temperature(%{
         "color_temperature" => %{
           "mirek_valid" => true,
           "mirek" => value,
           "mirek_schema" => %{"mirek_minimum" => low, "mirek_maximum" => high}
         }
       })
       when is_integer(value) and is_integer(low) and is_integer(high) and low >= 153 and
              high <= 500 and low <= value and value <= high,
       do: {:ok, div(1_000_000 + div(value, 2), value)}

  defp temperature(%{"color_temperature" => %{"mirek_valid" => false}}), do: {:ok, nil}

  defp temperature(light) do
    if Map.has_key?(light, "color_temperature"),
      do: {:error, :invalid_temperature},
      else: {:ok, nil}
  end

  defp selected([%{resource_id: id}], {:light, id}), do: :ok
  defp selected(_, {:light, _}), do: {:error, :light_identity_changed}
  defp selected(_, _), do: :ok

  defp decode_object(body) do
    with :ok <- check_depth(body, 0, false, false),
         {:ok, frame} <- strict_decode(body),
         true <- is_map(frame) do
      {:ok, frame}
    else
      _ -> {:error, :invalid_hue_response}
    end
  end

  defp strict_decode(body) do
    try do
      case JSON.decode(body, :ok,
             object_finish: fn pairs, old_acc ->
               keys = Enum.map(pairs, &elem(&1, 0))
               if length(keys) != length(Enum.uniq(keys)), do: throw(:duplicate_member)
               {Map.new(pairs), old_acc}
             end
           ) do
        {value, :ok, ""} -> {:ok, value}
        _ -> {:error, :invalid_json}
      end
    catch
      :throw, :duplicate_member -> {:error, :duplicate_member}
    end
  end

  defp check_depth(<<>>, 0, false, false), do: :ok
  defp check_depth(<<>>, _, _, _), do: {:error, :invalid_json}

  defp check_depth(<<byte, rest::binary>>, depth, true, escaped) do
    cond do
      escaped -> check_depth(rest, depth, true, false)
      byte == ?\\ -> check_depth(rest, depth, true, true)
      byte == ?" -> check_depth(rest, depth, false, false)
      true -> check_depth(rest, depth, true, false)
    end
  end

  defp check_depth(<<byte, rest::binary>>, depth, false, _escaped) do
    cond do
      byte == ?" -> check_depth(rest, depth, true, false)
      byte in [?{, ?[] and depth + 1 > @max_depth -> {:error, :too_deep}
      byte in [?{, ?[] -> check_depth(rest, depth + 1, false, false)
      byte in [?}, ?]] and depth > 0 -> check_depth(rest, depth - 1, false, false)
      byte in [?}, ?]] -> {:error, :invalid_json}
      true -> check_depth(rest, depth, false, false)
    end
  end
end
