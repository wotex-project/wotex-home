defmodule WotexHome.RoutineExternalFactFixture do
  @moduledoc false

  alias WotexHome.Profiles.{ExternalEnvelope, ExternalValue}

  def read(name), do: JSON.decode!(File.read!("test/fixtures/profiles/" <> name <> ".json"))

  def new do
    vector = read("routine-external-facts")
    source = read(vector["fixture"] |> Path.rootname())

    consumer =
      read(vector["consumer_fixture"] |> Path.rootname())[vector["consumer_family"]]["contract"]

    build(vector, source, consumer, vector["report"])
  end

  def build(vector, source, consumer, report) do
    installed =
      Map.take(source, ~w(bindings contracts home_contracts))
      |> Map.put("producer", vector["producer_assertion"])

    documents = %{
      "profile" => record(source["profile"], source["envelope"]["profile"]),
      "definitions" =>
        Enum.zip_with(source["definitions"], source["envelope"]["definitions"], &record/2)
    }

    {:ok, envelope} =
      ExternalEnvelope.compile(
        encode(source["envelope"]),
        documents,
        installed,
        source["capture"],
        source["reader_limits"]
      )

    {:ok, value} = ExternalValue.project(envelope, report, consumer, source["reader_limits"])

    %{
      vector: vector,
      source: source,
      consumer: consumer,
      report: report,
      value: value,
      mapping: vector["mapping"],
      metadata: vector["metadata"],
      context: %{
        "consumer" => consumer,
        "envelope" => envelope,
        "registry" => vector["registry"],
        "limits" => vector["limits"],
        "reader_limits" => source["reader_limits"]
      }
    }
  end

  def encode(data) do
    {:ok, bytes} = Wotex.JSON.encode(data)
    bytes
  end

  def hash(prefix, data),
    do: Base.encode16(:crypto.hash(:sha256, prefix <> "\n" <> encode(data)), case: :lower)

  def install(c, unsigned) do
    basis = unsigned["basis"]
    {:ok, digest} = Wotex.Routines.Basis.semantic_digest(basis, c.context["limits"])
    basis = Map.put(basis, "semantic_digest", digest)
    ref = Map.take(basis, ~w(id version semantic_digest))
    unsigned = Map.merge(unsigned, %{"basis" => basis, "legacy_basis_ref" => ref})

    registry =
      Enum.map(c.context["registry"], fn row ->
        row = if row["id"] == basis["id"], do: Map.put(row, "semantic_digest", digest), else: row

        Map.update!(
          row,
          "requires",
          &Enum.map(&1, fn old -> if old["id"] == basis["id"], do: ref, else: old end)
        )
      end)

    {:ok, digest} = Wotex.Routines.InputMapping.digest(unsigned, registry, c.context["limits"])
    mapping = Map.put(unsigned, "sha256", digest)

    registry =
      Enum.map(registry, fn row ->
        if row["id"] == mapping["id"],
          do:
            row |> Map.put("semantic_digest", "sha256:" <> digest) |> Map.put("requires", [ref]),
          else: row
      end)

    %{c | mapping: mapping, context: Map.put(c.context, "registry", registry)}
  end

  def typed(c, type, raw) do
    limits = c.context["reader_limits"]

    schema =
      if type == "boolean",
        do: %{"type" => "boolean"},
        else: %{"type" => "string", "enum" => ["0", "1"]}

    binding =
      hd(c.source["bindings"]) |> Map.delete("sha256") |> Map.put("raw_value_schema", schema)

    {:ok, digest} = Wotex.Profiles.Binding.digest(binding, limits)
    binding = Map.put(binding, "sha256", digest)
    ref = Map.take(binding, ~w(id version sha256))
    capture = c.source["capture"] |> Map.delete("digest") |> Map.put("binding", ref)
    {:ok, digest} = Wotex.Profiles.Capture.digest(capture, binding, limits)
    capture = Map.put(capture, "digest", digest)

    definition =
      Map.merge(hd(c.source["definitions"]), %{"value_schema" => schema, "unit" => nil})

    {:ok, semantic} = Wotex.Profiles.Definition.reference(definition, limits)

    profile =
      c.source["profile"]
      |> Map.put("binding", ref)
      |> put_in(["channels", Access.at!(0), "semantic"], semantic)
      |> put_in(["channels", Access.at!(0), "conversion"], nil)
      |> put_in(["channels", Access.at!(0), "invalid_values"], [])

    {:ok, profile_ref} = Wotex.Profiles.Profile.reference(profile, limits)

    source =
      Map.merge(c.source, %{
        "profile" => profile,
        "bindings" => [binding],
        "capture" => capture,
        "definitions" => [definition],
        "envelope" =>
          Map.merge(c.source["envelope"], %{"profile" => profile_ref, "definitions" => [semantic]})
      })

    consumer =
      Map.merge(c.consumer, %{
        "semantic_ref" => semantic,
        "value_kind" => if(type == "boolean", do: "boolean", else: "external"),
        "unit" => nil,
        "constraints" => nil
      })

    report =
      Map.merge(c.report, %{
        "binding" => ref,
        "profile_sha256" => profile_ref["sha256"],
        "value" => %{"type" => if(type == "boolean", do: "boolean", else: "text"), "value" => raw}
      })

    changed = build(c.vector, source, consumer, report)
    projection = changed.context["envelope"].projection.data

    unsigned =
      c.mapping
      |> Map.delete("sha256")
      |> Map.merge(Map.take(projection, ~w(profile_sha256 closure_sha256 capture_digest)))
      |> Map.merge(%{
        "semantic_ref" => semantic,
        "projection" => type,
        "external_unit" => nil,
        "enum_table" =>
          if(type == "enum",
            do: [%{"source" => "0", "target" => "closed"}, %{"source" => "1", "target" => "open"}],
            else: nil
          )
      })
      |> put_in(["basis", "value"], %{
        "type" => type,
        "unit" => nil,
        "enum" => if(type == "enum", do: ["closed", "open"], else: [])
      })
      |> put_in(["basis", "output"], nil)

    changed = install(changed, unsigned)
    put_in(changed.metadata["profile_digest"], "sha256:" <> projection["profile_sha256"])
  end

  defp record(data, ref) do
    bytes = encode(data)

    %{
      "reference" => ref,
      "bytes" => bytes,
      "raw_sha256" => Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    }
  end
end
