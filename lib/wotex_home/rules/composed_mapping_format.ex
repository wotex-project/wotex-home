defmodule WotexHome.Rules.ComposedMappingFormat do
  @moduledoc false

  alias Wotex.Routines.Source
  alias WotexHome.Id

  @external_resource Path.expand(
                       "../../../priv/profiles/composed-routine-mapping.schema.json",
                       __DIR__
                     )
  @schema @external_resource |> File.read!() |> JSON.decode!() |> ExJsonSchema.Schema.resolve()
  @maximum 9_223_372_036_854_775_807
  @own ~w(invalid_composed_mapping composed_mapping_limit unsupported_composed_mapping composed_mapping_basis_changed composed_registry_conflict composed_mapping_unavailable invalid_composed_projection)a
  @limit ~w(limit_or_json_error integer_overflow node_bound predicate_bound parallel_bound invocation_bound effect_bound wait_bound duration_bound path_bound definition_bound expansion_bound input_limit numeric_limit output_limit byte_limit_exceeded depth_limit_exceeded node_limit_exceeded string_limit_exceeded collection_limit_exceeded external_input_limit external_profile_limit)a
  @unsupported ~w(unsupported_node unsupported_trigger unsupported_predicate unsupported_argument unsupported_value unsupported_value_contract invalid_value_contract incompatible_effect incompatible_predicate incompatible_trigger incompatible_parameter incompatible_dimension inexact_conversion out_of_domain value_out_of_range invalid_value unsupported_mapping unsupported_external_input)a
  @unavailable ~w(routine_kernel_unavailable external_input_unavailable profiles_producer_unavailable missing_producer)a

  def guard(callback) do
    case callback.() do
      {:ok, value} when is_map(value) -> {:ok, value}
      :ok -> :ok
      error -> refusal(error)
    end
  rescue
    _ -> invalid()
  catch
    _, _ -> invalid()
  end

  def refusal({:error, %Wotex.Routines.Error{code: :invalid_type, path: "/value"}}),
    do: unsupported()

  def refusal({:error, %Wotex.Routines.Error{code: code}}), do: refusal({:error, code})
  def refusal({:error, %{code: code}}) when code in @limit, do: {:error, :composed_mapping_limit}
  def refusal({:error, %{code: _}}), do: invalid()
  def refusal({:error, code}) when code in @own, do: {:error, code}
  def refusal({:error, code}) when code in @limit, do: {:error, :composed_mapping_limit}
  def refusal({:error, code}) when code in @unsupported, do: unsupported()

  def refusal({:error, code}) when code in @unavailable,
    do: {:error, :composed_mapping_unavailable}

  def refusal(_), do: invalid()

  def admit(bytes, selection, maximum) when is_binary(bytes) do
    with true <- byte_size(bytes) <= maximum,
         {:ok, value} <- Wotex.JSON.decode(bytes, options(selection, maximum)),
         {:ok, _} <- canonical(value, selection, maximum) do
      {:ok, value}
    else
      false -> {:error, :composed_mapping_limit}
      error -> refusal(error)
    end
  end

  def admit(value, selection, maximum) do
    with {:ok, _} <- canonical(value, selection, maximum), do: {:ok, value}
  end

  def canonical(value, selection, maximum \\ 67_108_864) do
    with {:ok, bytes} <- Wotex.JSON.encode(value, options(selection, maximum)),
         true <- integers?(value),
         true <- byte_size(bytes) <= maximum do
      {:ok, bytes}
    else
      false -> {:error, :composed_mapping_limit}
      error -> refusal(error)
    end
  end

  def hash(prefix, value, selection) do
    with {:ok, bytes} <- canonical(value, selection) do
      {:ok, bare(prefix <> "\n" <> bytes)}
    end
  end

  def digest(value, selection) do
    with {:ok, bytes} <- canonical(value, selection), do: {:ok, "sha256:" <> bare(bytes)}
  end

  def bare(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  def reference(value), do: Map.take(value, ~w(id version semantic_digest))
  def iri(id), do: "urn:wotex-home:thing:" <> Base.url_encode64(id, padding: false)

  def bundle(bundle, selection) do
    with :ok <- fields(bundle, ~w(format source definitions arguments bindings)),
         true <- bundle["format"] == "wotex-home.routine-source@1",
         :ok <- count(bundle["definitions"], 63),
         :ok <- count(bundle["bindings"], 32),
         :ok <- each([bundle["source"] | bundle["definitions"]], &source(&1, selection)),
         :ok <- sorted(bundle["definitions"], & &1["id"]),
         true <-
           is_map(bundle["arguments"]) and Enum.all?(Map.keys(bundle["arguments"]), &Id.valid?/1),
         :ok <- each(bundle["bindings"], &selector/1),
         :ok <- sorted(bundle["bindings"], & &1["name"]),
         true <- shape?(bundle, "bundle"),
         true <- aliases(bundle) == Enum.map(bundle["bindings"], & &1["name"]) do
      :ok
    else
      false -> invalid()
      error -> error
    end
  end

  def environment(environment, bundle) do
    with :ok <- fields(environment, ~w(runtime_sha256 targets external_inputs)),
         :ok <- count(environment["targets"], 32),
         :ok <- count(environment["external_inputs"], 32),
         true <- shape?(environment, "environment"),
         :ok <- sorted(environment["targets"], & &1["target_id"]),
         :ok <- sorted(environment["external_inputs"], &{&1["target_id"], &1["capability_key"]}),
         true <- Enum.all?(environment["targets"], &counter?(&1["resource_revision"], 0)),
         true <- Enum.all?(environment["external_inputs"], &installation?/1),
         true <- coverage?(bundle, environment) do
      :ok
    else
      false -> invalid()
      error -> error
    end
  end

  def fields(value, keys) when is_map(value) and not is_struct(value) do
    if Enum.sort(Map.keys(value)) == Enum.sort(keys), do: :ok, else: invalid()
  end

  def fields(_, _), do: invalid()
  def invalid, do: {:error, :invalid_composed_mapping}
  def unsupported, do: {:error, :unsupported_composed_mapping}

  def each(values, callback) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case callback.(value) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp source(value, selection) do
    with {:ok, source} <- Source.new(value, selection.profile, selection.limits),
         data = source.data,
         true <- Id.valid?(data["id"]),
         :ok <- revision(data["revision"]),
         true <- Enum.all?(Map.keys(data["parameters"]) ++ data["bindings"], &Id.valid?/1),
         :ok <- nodes(data["steps"]) do
      :ok
    else
      false -> invalid()
      error -> refusal(error)
    end
  end

  defp nodes(node) do
    with true <- Id.valid?(node["id"]),
         :ok <- invocation(node) do
      each(children(node), &nodes/1)
    else
      false -> invalid()
      error -> error
    end
  end

  def children(%{"kind" => "if"} = node), do: [node["then"], node["else"]]
  def children(%{"kind" => "sequence", "steps" => steps}), do: steps
  def children(%{"kind" => "parallel", "branches" => branches}), do: branches
  def children(_), do: []

  defp invocation(%{"kind" => "invoke"} = node) do
    if Id.valid?(node["routine_id"]), do: revision(node["revision"]), else: invalid()
  end

  defp invocation(_), do: :ok

  defp revision(value) do
    if is_binary(value) and Regex.match?(~r/\A[1-9][0-9]*\z/, value) do
      if byte_size(value) <= 19 and String.to_integer(value) <= @maximum,
        do: :ok,
        else: {:error, :composed_mapping_limit}
    else
      invalid()
    end
  end

  defp selector(selector) do
    with :ok <- fields(selector, ~w(name kind target_id capability_key declaration_sha256 input)),
         true <- selector["kind"] in ~w(native_read native_write external_read),
         true <- shape?(selector, "selector"),
         true <- selected_input?(selector) do
      :ok
    else
      false ->
        if is_map(selector) and is_binary(selector["kind"]) and
             selector["kind"] not in ~w(native_read native_write external_read),
           do: unsupported(),
           else: invalid()

      error ->
        error
    end
  end

  defp selected_input?(%{"kind" => "external_read", "input" => input}),
    do: is_map(input) and installation?(input)

  defp selected_input?(%{"input" => nil}), do: true
  defp selected_input?(_), do: false

  defp installation?(value),
    do: counter?(value["install_revision"], 1) and counter?(value["generation"], 1)

  defp counter?(value, minimum), do: is_integer(value) and value in minimum..@maximum

  defp coverage?(bundle, environment) do
    targets = bundle["bindings"] |> Enum.map(& &1["target_id"]) |> Enum.uniq() |> Enum.sort()

    inputs =
      bundle["bindings"]
      |> Enum.filter(&(&1["kind"] == "external_read"))
      |> Enum.map(&{&1["target_id"], &1["capability_key"]})
      |> Enum.uniq()
      |> Enum.sort()

    targets == Enum.map(environment["targets"], & &1["target_id"]) and
      inputs == Enum.map(environment["external_inputs"], &{&1["target_id"], &1["capability_key"]})
  end

  defp aliases(bundle) do
    [bundle["source"] | bundle["definitions"]]
    |> Enum.flat_map(& &1["bindings"])
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp sorted(values, key) do
    keys = Enum.map(values, key)
    if keys == Enum.sort(Enum.uniq(keys)), do: :ok, else: invalid()
  end

  defp count(values, maximum) when is_list(values) do
    if length(values) <= maximum, do: :ok, else: {:error, :composed_mapping_limit}
  end

  defp count(_, _), do: invalid()

  defp shape?(value, name),
    do: ExJsonSchema.Validator.valid_fragment?(@schema, "#/definitions/" <> name, value)

  defp options(selection, maximum) do
    limits = selection.limits.data

    [
      max_bytes: min(maximum, limits["max_bytes"]),
      max_depth: limits["max_depth"],
      max_nodes: limits["max_nodes"],
      max_string_bytes: limits["max_string_bytes"],
      max_collection_size: limits["max_collection_size"]
    ]
  end

  defp integers?(value) when is_integer(value), do: abs(value) <= @maximum
  defp integers?(value) when is_list(value), do: Enum.all?(value, &integers?/1)
  defp integers?(value) when is_map(value), do: Enum.all?(Map.values(value), &integers?/1)
  defp integers?(_), do: true
end
