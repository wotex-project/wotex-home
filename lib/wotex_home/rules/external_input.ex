defmodule WotexHome.Rules.ExternalInput do
  @moduledoc """
  Binds a reviewed external reader and read-only routine Mapping to explicit context.

  `new/3` takes a closed claimed context, a complete plain Mapping map and Registry
  records. It returns `{:ok, definition}` with native `:data`, `:document` and
  `:sha256` fields, or `{:error, code}`. Construction checks reader/declaration,
  source and receipt-clock correspondence, then validates the supplied registry,
  installed Mapping and complete read-only Basis through public
  `Wotex.Routines.Registry` and `Wotex.Routines.InputMapping` constructors.
  Fixed limits apply to every embedded occurrence; the whole definition is
  bounded to 262,144 bytes and its inner documents to 131,072 bytes each.

  These are checks of supplied claims. The constructor neither consults Store
  nor measures installed runtime, live sources, clocks or grants. Validity in the
  supplied registry is not a current Home installation or signed qualification.

  `to_map/2` rebuilds the exact native data, document and digest and compares the
  retained context with the caller-supplied current context. It returns
  `{:ok, data}`, `{:error, :external_input_basis_changed}` for a changed context,
  or another named validation refusal. Store must independently measure that
  current context; passing a value's own claim does not establish freshness.
  `encode/1` deliberately reconstructs against that own claim and returns
  `{:ok, document}`, without asserting current use.

  `decode/1` is producer-independent historical parsing. It checks the bounded,
  duplicate-free inner JSON, closed Home correspondence and canonical outer
  array wire, preserving the original inner bytes in the retained document.
  Success is `{:ok, historical}` with exactly the plain string keys `"data"`,
  `"document"` and `"sha256"`. That object is not a native constructor result.
  Decoding computes Home's identity for those bytes and checks the claimed runtime
  commitment. It does not rerun opaque producer digest algebra, prove current
  installation or verify physical evidence. Native reuse must reconstruct.

  Refusals are payload-free `{:error, code}` tuples using
  `:invalid_external_input`, `:external_input_limit`, `:external_input_unavailable`,
  `:unsupported_external_input` or `:external_input_basis_changed`. No partial
  definition or fallback follows. Neither a native value nor historical metadata
  grants source trust, current fact authority, collection permission or effects.
  """

  alias WotexHome.Profiles.{AuthoringWire, DocumentChunks}
  alias WotexHome.Rules.{ExternalInputFormat, ExternalInputRuntime}
  alias Wotex.Routines.{Input, InputMapping, Registry}

  @format "wotex-home.external-input-definition@1"
  @wire "wotex-home.external-input-definition.v1"
  @reader ~w(affordance capture_digest channel_id closure_sha256 compiler_ref external_unit profile_sha256 reader_contract_ref semantic_ref)
  @digests ~w(byte_digest semantic_digest implementation_digest compiler_digest)
  @maximum 9_223_372_036_854_775_807
  @minimum -9_223_372_036_854_775_808
  @enforce_keys [:data, :document, :sha256]
  defstruct @enforce_keys
  @type t :: %__MODULE__{data: map(), document: String.t(), sha256: String.t()}

  @doc "Builds a read-only Definition from explicit claimed inputs, without consulting Store."
  @spec new(term(), term(), term()) :: {:ok, t()} | {:error, atom()}
  def new(context, mapping, registry) do
    ExternalInputFormat.guard(fn ->
      data = %{
        "format" => @format,
        "context" => context,
        "mapping" => mapping,
        "registry" => registry,
        "limits" => ExternalInputFormat.limits()
      }

      with :ok <- historical_shape(data),
           :ok <- producer_available(),
           {:ok, _} <- Registry.new(registry, data["limits"]),
           {:ok, ^mapping} <- InputMapping.to_map(mapping, registry, data["limits"]),
           {:ok, _} <- Input.binding_basis(mapping, registry, data["limits"]),
           :ok <- byte_digest(mapping["basis"]),
           {:ok, _} <- ExternalInputFormat.producer_json(data, 262_144),
           {:ok, document} <- document(data) do
        {:ok,
         %__MODULE__{
           data: data,
           document: document,
           sha256: ExternalInputFormat.hash(@format, document)
         }}
      else
        {:error, _} = error -> error
        _ -> {:error, :invalid_external_input}
      end
    end)
  end

  @doc "Reconstructs an exact native Definition and compares the supplied current context."
  @spec to_map(term(), term()) :: {:ok, map()} | {:error, atom()}
  def to_map(
        %__MODULE__{data: %{"context" => context, "mapping" => mapping, "registry" => registry}} =
          value,
        current_context
      )
      when map_size(value) == 4 do
    with {:ok, rebuilt} <- new(context, mapping, registry),
         true <- rebuilt == value do
      if context == current_context,
        do: {:ok, rebuilt.data},
        else: {:error, :external_input_basis_changed}
    else
      false -> {:error, :invalid_external_input}
      error -> error
    end
  end

  def to_map(_, _), do: {:error, :invalid_external_input}

  @doc "Returns exact native bytes after reconstruction, without proving a current installation."
  @spec encode(term()) :: {:ok, String.t()} | {:error, atom()}
  def encode(%__MODULE__{data: %{"context" => context}} = value) do
    with {:ok, _} <- to_map(value, context), do: {:ok, value.document}
  end

  def encode(_), do: {:error, :invalid_external_input}

  @doc "Decodes producer-independent historical metadata, preserving exact inner document bytes."
  @spec decode(term()) :: {:ok, map()} | {:error, atom()}
  def decode(bytes) do
    ExternalInputFormat.guard(fn ->
      with {:ok, [@wire, context, mapping, registry, limits] = wire} <-
             AuthoringWire.decode(bytes, 262_144),
           {:ok, ^bytes} <- ExternalInputFormat.wire(wire, 262_144),
           true <- limits == ExternalInputFormat.limit_values(),
           {:ok, context} <- inner(context),
           {:ok, mapping} <- inner(mapping),
           {:ok, registry} <- inner(registry),
           data = %{
             "format" => @format,
             "context" => context,
             "mapping" => mapping,
             "registry" => registry,
             "limits" => ExternalInputFormat.limits()
           },
           :ok <- historical_shape(data) do
        {:ok,
         %{
           "data" => data,
           "document" => bytes,
           "sha256" => ExternalInputFormat.hash(@format, bytes)
         }}
      else
        {:error, _} = error -> error
        _ -> {:error, :invalid_external_input}
      end
    end)
  end

  defp historical_shape(data) do
    with :ok <- ExternalInputFormat.bounded(data),
         true <- ExternalInputFormat.shape?(data, "input_definition"),
         :ok <- correspondence(data["context"], data["mapping"]) do
      :ok
    else
      false -> {:error, :invalid_external_input}
      error -> error
    end
  end

  defp correspondence(c, m) do
    d = c["declaration"]
    r = c["reader"]
    clock = c["receipt_clock"]
    basis = m["basis"]

    with {:ok, digest} <- ExternalInputRuntime.digest(c["runtime"]),
         true <- digest == c["runtime_sha256"],
         true <- d["producer"] == c["runtime"]["profiles"],
         true <- d["thing_id"] == c["target_id"] and d["capability_key"] == c["capability_key"],
         true <- Enum.all?(~w(channel_id semantic_ref value_schema), &(d[&1] == r[&1])),
         true <- Enum.all?(@reader, &(m[&1] == r[&1])),
         true <-
           m["observation"]["source_ref"] == c["source_ref"] and
             m["observation"]["source_epoch"] == c["source_epoch"],
         true <-
           m["receipt_clock"] == clock and clock["source_epoch"] == c["report_owner_epoch"] and
             clock["target_epoch"] == c["store_boot_epoch"],
         {origin, ""} <- Integer.parse(clock["source_origin_us"]),
         true <- origin in @minimum..@maximum and rem(origin, 1000) == 0,
         true <-
           basis["implementation_digest"] == "sha256:" <> digest and
             basis["compiler_digest"] == "sha256:" <> digest,
         true <- basis["evidence"]["freshness_ms"] <= d["freshness_ms"],
         true <- declaration?(d, r),
         true <- projection?(m, r["value_schema"]) do
      :ok
    else
      _ -> {:error, :unsupported_external_input}
    end
  end

  defp declaration?(
         %{
           "value_kind" => "integer",
           "constraints" => %{"min" => minimum, "max" => maximum},
           "unit" => unit
         },
         r
       ) do
    r["value_schema"]["type"] in ~w(integer number) and is_map(unit) and
      is_map(r["external_unit"]) and
      minimum <= maximum and
      Map.take(unit, ~w(quantity_kind dimension)) ==
        Map.take(r["external_unit"], ~w(quantity_kind dimension))
  end

  defp declaration?(%{"value_kind" => "boolean", "unit" => nil, "constraints" => nil}, r),
    do: r["value_schema"]["type"] == "boolean" and r["external_unit"] == nil

  defp declaration?(%{"value_kind" => "external", "unit" => unit, "constraints" => nil}, r),
    do: unit == r["external_unit"]

  defp declaration?(_, _), do: false

  defp projection?(%{"projection" => "exact_integer"}, schema),
    do: schema["type"] in ~w(integer number)

  defp projection?(%{"projection" => "boolean"}, schema), do: schema["type"] == "boolean"

  defp projection?(%{"projection" => "enum", "enum_table" => table}, %{
         "type" => "string",
         "enum" => values
       })
       when is_list(values) and values != [] do
    sources = Enum.map(table, & &1["source"])
    Enum.uniq(sources) == sources and Enum.sort(sources) == Enum.sort(values)
  end

  defp projection?(_, _), do: false

  defp byte_digest(basis) do
    with {:ok, bytes} <- ExternalInputFormat.producer_json(Map.drop(basis, @digests), 131_072) do
      digest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
      if basis["byte_digest"] == digest, do: :ok, else: {:error, :invalid_external_input}
    end
  end

  defp document(data) do
    with {:ok, inner} <-
           Enum.reduce_while(~w(context mapping registry), {:ok, []}, fn field, {:ok, all} ->
             with {:ok, bytes} <- ExternalInputFormat.producer_json(data[field], 131_072),
                  {:ok, chunks} <- DocumentChunks.encode(bytes, 131_072),
                  do: {:cont, {:ok, all ++ [chunks]}},
                  else: (error -> {:halt, error})
           end),
         do:
           ExternalInputFormat.wire(
             [@wire | inner] ++ [ExternalInputFormat.limit_values()],
             262_144
           )
  end

  defp inner(chunks) do
    with {:ok, bytes} <- DocumentChunks.decode(chunks, 131_072),
         do: ExternalInputFormat.decode_json(bytes, 131_072)
  end

  defp producer_available do
    if Enum.all?(
         [
           {Registry, :new, 2},
           {InputMapping, :to_map, 3},
           {Input, :binding_basis, 3},
           {Wotex.JSON, :encode, 2},
           {Wotex.Profiles.Proposal, :identity, 0}
         ],
         fn {module, function, arity} ->
           Code.ensure_loaded?(module) and function_exported?(module, function, arity)
         end
       ),
       do: :ok,
       else: {:error, :external_input_unavailable}
  end
end
