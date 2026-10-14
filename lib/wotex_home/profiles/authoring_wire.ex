defmodule WotexHome.Profiles.AuthoringWire do
  @moduledoc false
  @maximum 9_223_372_036_854_775_807
  def decode(bytes, maximum) when is_binary(bytes) and byte_size(bytes) in 1..maximum//1 do
    with true <- String.valid?(bytes),
         {data, {0, nodes, nil}, ""} when nodes <= 4096 <-
           JSON.decode(bytes, {0, 0, nil},
             object_start: fn _ -> throw(:invalid_authoring_candidate) end,
             array_start: &start/1,
             array_push: &push/2,
             array_finish: &finish/2,
             string: &string/1,
             integer: &integer/1,
             float: fn _ -> throw(:invalid_authoring_candidate) end
           ) do
      {:ok, data}
    else
      _ -> {:error, :invalid_authoring_candidate}
    end
  catch
    :throw, code when code in [:authoring_limit, :invalid_authoring_candidate] -> {:error, code}
  end

  def decode(bytes, maximum) when is_binary(bytes) and byte_size(bytes) > maximum,
    do: {:error, :authoring_limit}

  def decode(_, _), do: {:error, :invalid_authoring_candidate}
  defp start({depth, nodes, _}) when depth < 8 and nodes < 4096, do: {depth + 1, nodes + 1, []}
  defp start(_), do: throw(:authoring_limit)

  defp push(value, {depth, nodes, values}) when length(values) < 256 do
    nodes = nodes + if(is_list(value), do: 0, else: 1)
    if nodes <= 4096, do: {depth, nodes, [value | values]}, else: throw(:authoring_limit)
  end

  defp push(_, _), do: throw(:authoring_limit)

  defp finish({_, nodes, values}, {depth, _, parent}),
    do: {Enum.reverse(values), {depth, nodes, parent}}

  defp string(value) when byte_size(value) <= 4096, do: value
  defp string(_), do: throw(:authoring_limit)

  defp integer(bytes) when byte_size(bytes) <= 20 do
    value = String.to_integer(bytes)
    if value in -@maximum..@maximum, do: value, else: throw(:invalid_authoring_candidate)
  end

  defp integer(_), do: throw(:invalid_authoring_candidate)
end
