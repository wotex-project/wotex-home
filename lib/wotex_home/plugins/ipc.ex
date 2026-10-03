defmodule WotexHome.Plugins.IPC do
  @moduledoc "Closed native framing; no guest text or dynamic atom creation."

  alias WotexHome.Plugins.Bundle

  def input(:decode_power, bytes) when is_binary(bytes) and byte_size(bytes) <= 2, do: :ok
  def input(:encode_power, power) when is_boolean(power), do: :ok
  def input(_, _), do: {:error, :invalid_input}

  def request(bundle, operation, input) do
    {tag, value} =
      case {operation, input} do
        {:decode_power, bytes} -> {0, bytes}
        {:encode_power, true} -> {1, <<1>>}
        {:encode_power, false} -> {1, <<0>>}
      end

    digest = Base.decode16!(bundle.digest, case: :lower)
    wit_digest = Base.decode16!(Bundle.wit_digest(), case: :lower)
    bytes = bundle.bytes

    body =
      <<1, tag, digest::binary, wit_digest::binary, byte_size(bytes)::32, bytes::binary,
        value::binary>>

    <<byte_size(body)::32, body::binary>>
  end

  def response(<<1, 0, power>>, :decode_power, _) when power in [0, 1],
    do: {:ok, power == 1}

  def response(<<1, 1, 0>>, :decode_power, _), do: {:error, :malformed}
  def response(<<1, 1, 1>>, :decode_power, _), do: {:error, :unsupported}

  def response(<<1, 2, payload::binary-size(6)>>, :encode_power, power) do
    expected = if power, do: <<255, 255, 0, 0, 0, 0>>, else: <<0, 0, 0, 0, 0, 0>>
    if payload == expected, do: {:ok, payload}, else: {:error, :invalid_output}
  end

  def response(<<1, 3, code>>, _, _) do
    reason =
      case code do
        0 -> :invalid_request
        1 -> :digest_mismatch
        2 -> :invalid_component
        3 -> :incompatible_world
        4 -> :guest_trap
        5 -> :invalid_output
        6 -> :resource_setup
        7 -> :resource_exhausted
        8 -> :interface_mismatch
        _ -> :invalid_response
      end

    {:error, reason}
  end

  def response(_, _, _), do: {:error, :invalid_response}

  def preview(bundle, result),
    do: %{
      scope: :unqualified_profile_preview,
      component_digest: bundle.digest,
      wit_digest: Bundle.wit_digest(),
      result: result
    }
end
