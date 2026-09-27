defmodule WotexHome.Shelly.Gen2RPC do
  @moduledoc """
  Read-only Shelly Gen2+ RPC frames for device identity and switch state.

  `request/2` builds a complete frame for HTTP `POST /rpc`. Pass its bytes to
  a separately owned local transport; this module does not open a connection
  or handle Digest authentication. `response/3` checks the matching RPC ID,
  a single result or error, and only the fields Home needs from
  `Shelly.GetDeviceInfo` or `Switch.GetStatus`.

  Reported model, firmware and switch output remain untrusted device claims.
  An exact product profile, component mapping and fresh local transport
  identity must be reviewed before they become Home observations. This module
  cannot encode `Switch.Set`, Toggle, firmware updates or other writes.
  """

  alias WotexHome.Id

  @max_body_bytes 32_768
  @max_depth 12
  @max_rpc_id 65_535
  @max_switch_id 15
  @max_text_bytes 128

  @type query :: :device_info | {:switch_status, non_neg_integer()}

  @doc "Builds one closed read-only full-frame request for Shelly's HTTP RPC endpoint."
  @spec request(query(), pos_integer()) :: {:ok, binary()} | {:error, :invalid_rpc_request}
  def request(query, rpc_id) when is_integer(rpc_id) and rpc_id in 1..@max_rpc_id do
    case query do
      :device_info ->
        {:ok, JSON.encode!(%{"id" => rpc_id, "method" => "Shelly.GetDeviceInfo"})}

      {:switch_status, switch_id} when is_integer(switch_id) and switch_id in 0..@max_switch_id ->
        {:ok,
         JSON.encode!(%{
           "id" => rpc_id,
           "method" => "Switch.GetStatus",
           "params" => %{"id" => switch_id}
         })}

      _ ->
        {:error, :invalid_rpc_request}
    end
  end

  def request(_, _), do: {:error, :invalid_rpc_request}

  @doc "Checks a complete response against the request and returns narrow reported fields."
  @spec response(binary(), pos_integer(), query()) :: {:ok, map()} | {:error, atom()}
  def response(body, rpc_id, query)
      when is_binary(body) and byte_size(body) in 1..@max_body_bytes and
             is_integer(rpc_id) and rpc_id in 1..@max_rpc_id do
    with {:ok, frame} <- decode_object(body),
         :ok <- envelope(frame, rpc_id),
         result <- Map.get(frame, "result") do
      case query do
        :device_info -> device_info(result, frame["src"])
        {:switch_status, switch_id} -> switch_status(result, switch_id, frame["src"])
        _ -> {:error, :invalid_rpc_request}
      end
    else
      {:error, _} = error -> error
    end
  end

  def response(_, _, _), do: {:error, :invalid_rpc_response}

  defp envelope(frame, rpc_id) do
    keys = Map.keys(frame) |> Enum.sort()

    cond do
      frame["id"] != rpc_id or not Id.valid?(frame["src"]) ->
        {:error, :rpc_correlation_failed}

      keys in [~w(id result src), ~w(dst id result src)] ->
        if not Map.has_key?(frame, "dst") or Id.valid?(frame["dst"]),
          do: :ok,
          else: {:error, :invalid_rpc_response}

      keys in [~w(error id src), ~w(dst error id src)] ->
        {:error, :device_error}

      true ->
        {:error, :invalid_rpc_response}
    end
  end

  defp device_info(result, source) when is_map(result) do
    with %{
           "id" => device_id,
           "model" => model,
           "gen" => generation,
           "fw_id" => firmware_id,
           "ver" => version,
           "auth_en" => authentication_enabled
         } <- result,
         true <- Enum.all?([device_id, model, firmware_id, version], &text?/1),
         true <- generation in [2, 3, 4] and is_boolean(authentication_enabled),
         true <- source == device_id do
      {:ok,
       %{
         device_id: device_id,
         model: model,
         generation: generation,
         firmware_id: firmware_id,
         firmware_version: version,
         authentication_enabled: authentication_enabled,
         trust: :unauthenticated_local
       }}
    else
      _ -> {:error, :invalid_device_identity}
    end
  end

  defp device_info(_, _), do: {:error, :invalid_device_identity}

  defp switch_status(result, switch_id, source)
       when is_map(result) and is_integer(switch_id) and switch_id in 0..@max_switch_id do
    case result do
      %{"id" => ^switch_id, "output" => output} when is_boolean(output) ->
        if not Map.has_key?(result, "errors") or result["errors"] == [] do
          {:ok,
           %{
             device_id: source,
             switch_id: switch_id,
             output: output,
             trust: :unauthenticated_local
           }}
        else
          {:error, :device_status_error}
        end

      _ ->
        {:error, :invalid_switch_status}
    end
  end

  defp switch_status(_, _, _), do: {:error, :invalid_switch_status}

  defp text?(value),
    do: is_binary(value) and byte_size(value) in 1..@max_text_bytes and String.valid?(value)

  defp decode_object(body) do
    with :ok <- check_depth(body, 0, false, false),
         {:ok, frame} <- strict_decode(body),
         true <- is_map(frame) do
      {:ok, frame}
    else
      _ -> {:error, :invalid_rpc_response}
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
