defmodule WotexHome.Profiles.RetainedJSON do
  @moduledoc false

  # This is a bounded historical container, not a WPF parser or unit validator.
  def decode(bytes) when is_binary(bytes) and byte_size(bytes) in 1..262_144 do
    with true <- String.valid?(bytes),
         {value, {0, nodes, nil}, ""} when nodes <= 4096 <-
           JSON.decode(bytes, {0, 0, nil},
             array_start: &start/1,
             array_push: &push/2,
             array_finish: &finish_array/2,
             object_start: &start/1,
             object_push: &push_member/3,
             object_finish: &finish_object/2,
             string: &string/1,
             integer: &integer/1,
             float: &float/1
           ),
         true <- is_map(value) or is_list(value),
         do: {:ok, value},
         else: (_ -> invalid())
  catch
    :throw, :external_profile_limit -> {:error, :external_profile_limit}
    :throw, :invalid_retained_json -> invalid()
  end

  def decode(bytes) when is_binary(bytes) and byte_size(bytes) > 262_144,
    do: {:error, :external_profile_limit}

  def decode(_), do: invalid()

  defp start({depth, nodes, _}) when depth < 8 and nodes < 4096,
    do: {depth + 1, nodes + 1, []}

  defp start(_), do: throw(:external_profile_limit)

  defp push(value, {depth, nodes, values}) when length(values) < 256 do
    nodes = nodes + if(is_list(value) or is_map(value), do: 0, else: 1)
    if nodes <= 4096, do: {depth, nodes, [value | values]}, else: throw(:external_profile_limit)
  end

  defp push(_, _), do: throw(:external_profile_limit)

  defp push_member(key, value, {depth, nodes, values}) do
    if List.keymember?(values, key, 0), do: throw(:invalid_retained_json)

    push(
      {key, value},
      {depth, nodes + if(is_list(value) or is_map(value), do: -1, else: 0), values}
    )
  end

  defp finish_array({_, nodes, values}, {depth, _, parent}),
    do: {Enum.reverse(values), {depth, nodes, parent}}

  defp finish_object({_, nodes, values}, {depth, _, parent}),
    do: {Map.new(values), {depth, nodes, parent}}

  defp string(value) when byte_size(value) <= 4096, do: value
  defp string(_), do: throw(:external_profile_limit)
  defp integer(bytes) when byte_size(bytes) <= 64, do: String.to_integer(bytes)
  defp integer(_), do: throw(:external_profile_limit)
  defp float(bytes) when byte_size(bytes) <= 64, do: String.to_float(bytes)
  defp float(_), do: throw(:external_profile_limit)
  defp invalid, do: {:error, :invalid_retained_json}
end
