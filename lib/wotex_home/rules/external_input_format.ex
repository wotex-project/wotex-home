defmodule WotexHome.Rules.ExternalInputFormat do
  @moduledoc """
  Internal bounded representation helpers for reviewed external routine inputs.

  `WotexHome.Rules.ExternalInput` owns the native construction and historical
  decoding workflow. This collaborator supplies its fixed limit selections,
  compiled offline schema, bounded JSON traversal, canonical outer wire and
  format-separated document hashes. Its functions are internal representation
  operations, rather than a separate installation or qualification API.

  The closed schema is read and resolved at compilation, with no runtime schema
  lookup. Historical JSON uses Home's duplicate-free parser and structural bounds
  without invoking a WoTEx producer. Shape checks do not rerun the producer's
  semantic digest or Mapping algebra. The owning decoder retains exact inner
  document bytes and separately requires canonical outer array encoding.

  Native construction uses public producer JSON encoding for canonical inner
  documents. Bounds include depth 16, 20,000 nodes, 8192-byte strings and
  128-member collections; callers also supply the encoded-document byte ceiling.
  Every embedded occurrence counts, with no hidden references or truncation.
  Error normalization returns the owning closed external-input refusal codes
  without exposing producer exceptions or caller text.

  These helpers establish representation and byte identity. They do not measure
  installed code, sample clocks, consult Store, verify physical evidence or
  establish that a claimed registry/context is currently authorized.
  """

  alias WotexHome.LocalAPI.Frame

  @external_resource Path.expand(
                       "../../../priv/profiles/routine-external-input.schema.json",
                       __DIR__
                     )
  @schema @external_resource |> File.read!() |> JSON.decode!() |> ExJsonSchema.Schema.resolve()
  @limits %{
    "max_bytes" => 262_144,
    "max_depth" => 16,
    "max_nodes" => 20_000,
    "max_string_bytes" => 8192,
    "max_collection_size" => 128,
    "max_integer" => 9_223_372_036_854_775_807
  }
  @order ~w(max_bytes max_depth max_nodes max_string_bytes max_collection_size max_integer)
  @own_errors ~w(invalid_external_input external_input_limit external_input_unavailable unsupported_external_input external_input_basis_changed)a
  @limit_errors ~w(input_limit numeric_limit output_limit byte_limit_exceeded depth_limit_exceeded node_limit_exceeded string_limit_exceeded collection_limit_exceeded authoring_limit external_profile_limit request_too_large too_deep integer_overflow)a
  @unavailable_errors ~w(missing_producer profiles_producer_unavailable profile_runtime_source_unavailable runtime_artifact_unavailable)a

  @doc false
  def limits, do: @limits

  @doc false
  def limit_values, do: Enum.map(@order, &@limits[&1])

  @doc false
  def shape?(data, fragment),
    do:
      ExJsonSchema.Validator.valid_fragment?(@schema, "#/definitions/" <> fragment, data) == true

  @doc false
  def bounded(data) do
    case walk(data, 0, 0, 0) do
      {:ok, _, _} -> :ok
      error -> error
    end
  end

  @doc false
  def decode_json(bytes, maximum) do
    with {:ok, data} <- Frame.decode_document(bytes, maximum),
         :ok <- bounded(data),
         do: {:ok, data}
  end

  @doc false
  def producer_json(data, maximum) do
    if Code.ensure_loaded?(Wotex.JSON) and function_exported?(Wotex.JSON, :encode, 2) do
      with :ok <- bounded(data),
           {:ok, bytes} <- Wotex.JSON.encode(data, json_options(maximum)),
           :ok <- byte_limit(bytes, maximum),
           do: {:ok, bytes}
    else
      {:error, :external_input_unavailable}
    end
  end

  @doc false
  def wire(value, maximum) do
    bytes = JSON.encode!(value)
    with :ok <- byte_limit(bytes, maximum), do: {:ok, bytes}
  end

  @doc false
  def byte_limit(bytes, maximum) when is_binary(bytes) and byte_size(bytes) <= maximum, do: :ok
  def byte_limit(_, _), do: {:error, :external_input_limit}

  @doc false
  def hash(format, bytes),
    do: :crypto.hash(:sha256, format <> "\n" <> bytes) |> Base.encode16(case: :lower)

  @doc false
  def guard(callback) do
    case callback.() do
      {:ok, result} when is_map(result) -> {:ok, result}
      :ok -> :ok
      error -> refusal(error)
    end
  rescue
    _ -> {:error, :invalid_external_input}
  catch
    _, _ -> {:error, :invalid_external_input}
  end

  defp refusal({:error, %{code: code}}), do: refusal({:error, code})
  defp refusal({:error, code}) when code in @own_errors, do: {:error, code}
  defp refusal({:error, code}) when code in @limit_errors, do: {:error, :external_input_limit}

  defp refusal({:error, code}) when code in @unavailable_errors,
    do: {:error, :external_input_unavailable}

  defp refusal({:error, _}), do: {:error, :unsupported_external_input}
  defp refusal(_), do: {:error, :invalid_external_input}

  defp json_options(maximum),
    do: [
      max_bytes: maximum,
      max_depth: 16,
      max_nodes: 20_000,
      max_string_bytes: 8192,
      max_collection_size: 128
    ]

  defp walk(_, depth, nodes, bytes) when depth > 16 or nodes >= 20_000 or bytes > 262_144,
    do: {:error, :external_input_limit}

  defp walk(data, depth, nodes, bytes) when is_map(data) and not is_struct(data) do
    if map_size(data) <= 128 do
      Enum.reduce_while(data, {:ok, nodes + 1, bytes}, fn {key, value}, {:ok, count, size} ->
        with :ok <- string(key),
             {:ok, next, total} <- walk(value, depth + 1, count, size + byte_size(key)),
             do: {:cont, {:ok, next, total}},
             else: (error -> {:halt, error})
      end)
    else
      {:error, :external_input_limit}
    end
  end

  defp walk(data, depth, nodes, bytes) when is_list(data),
    do: walk_list(data, depth, nodes + 1, bytes, 0)

  defp walk(data, _, nodes, bytes) when is_binary(data) do
    with :ok <- string(data),
         true <- bytes + byte_size(data) <= 262_144,
         do: {:ok, nodes + 1, bytes + byte_size(data)},
         else: (
           false -> {:error, :external_input_limit}
           error -> error
         )
  end

  defp walk(data, _, nodes, bytes) when is_nil(data) or is_boolean(data) or is_number(data),
    do: {:ok, nodes + 1, bytes}

  defp walk(_, _, _, _), do: {:error, :invalid_external_input}
  defp walk_list([], _, nodes, bytes, _), do: {:ok, nodes, bytes}
  defp walk_list([_ | _], _, _, _, 128), do: {:error, :external_input_limit}

  defp walk_list([value | rest], depth, nodes, bytes, count) do
    with {:ok, next, total} <- walk(value, depth + 1, nodes, bytes),
         do: walk_list(rest, depth, next, total, count + 1)
  end

  defp walk_list(_, _, _, _, _), do: {:error, :invalid_external_input}

  defp string(value) when is_binary(value) and byte_size(value) <= 8192,
    do: if(String.valid?(value), do: :ok, else: {:error, :invalid_external_input})

  defp string(value) when is_binary(value), do: {:error, :external_input_limit}
  defp string(_), do: {:error, :invalid_external_input}
end
