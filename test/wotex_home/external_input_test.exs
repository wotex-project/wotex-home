Code.require_file(Path.expand("../support/routine_external_fact_fixture.exs", __DIR__))

defmodule WotexHome.ExternalInputTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias WotexHome.Profiles.{DocumentChunks, ExternalReadDeclaration, ProducerIdentity}
  alias WotexHome.Rules.{ExternalInput, ExternalInputRuntime}
  alias WotexHome.RoutineExternalFactFixture, as: F

  setup_all do
    v = F.read("routine-external-inputs")
    d = v["definition"]
    {:ok, native} = ExternalInput.new(d["context"], d["mapping"], d["registry"])
    %{v: v, d: d, native: native}
  end

  test "native construction matches the independent complete definition, document and digest",
       c do
    assert c.native.data == c.d
    assert c.native.document == c.v["definition_document"]
    assert c.native.sha256 == c.v["definition_sha256"]
    assert {:ok, c.d} == ExternalInput.to_map(c.native, c.d["context"])
    assert {:ok, c.native.document} == ExternalInput.encode(c.native)
    assert {:ok, historical} = ExternalInput.decode(c.native.document)

    assert historical == %{
             "data" => c.d,
             "document" => c.native.document,
             "sha256" => c.native.sha256
           }

    assert {:error, :invalid_external_input} = ExternalInput.to_map(historical, c.d["context"])

    assert {:error, :runtime_artifact_unavailable} =
             ExternalInputRuntime.check_current(
               c.d["context"]["runtime"],
               c.d["context"]["runtime_sha256"]
             )
  end

  test "native reuse checks every field before comparing caller-supplied current context", c do
    for native <- [
          %{},
          Map.from_struct(c.native),
          Map.put(c.native, :extra, true),
          %{c.native | document: c.native.document <> " "},
          %{c.native | sha256: String.duplicate("0", 64)},
          put_in(c.native.data["qualified"], true),
          put_in(c.native.data["limits"]["max_depth"], 32)
        ] do
      assert {:error, _} = ExternalInput.to_map(native, c.d["context"])
      assert {:error, _} = ExternalInput.encode(native)
    end

    for context <- [nil, %{}, Map.put(c.d["context"], "selection_revision", 12)] do
      assert {:error, :external_input_basis_changed} = ExternalInput.to_map(c.native, context)
    end

    changed = put_in(c.d, ["context", "selection_revision"], 12)
    assert {:ok, different} = construct(changed)
    refute different.sha256 == c.native.sha256
  end

  test "read-only scope, actual reader coordinates and own clock/runtime correspondence are closed",
       c do
    for d <- [
          put_in(c.d, ["mapping", "basis", "output"], c.d["mapping"]["basis"]["value"]),
          put_in(c.d, ["mapping", "basis", "effects", "repeat"], "bounded"),
          put_in(c.d, ["mapping", "basis", "timing", "duration_ms"], 1),
          put_in(c.d, ["mapping", "basis", "timing", "deadline_ms"], 0),
          put_in(c.d, ["context", "source_trust"], "synthetic_lab"),
          put_in(c.d, ["context", "runtime_sha256"], String.duplicate("0", 64)),
          put_in(
            c.d,
            ["context", "declaration", "producer", "core_runtime_sha256"],
            String.duplicate("0", 64)
          ),
          put_in(c.d, ["context", "reader", "capture_digest"], String.duplicate("0", 64)),
          put_in(c.d, ["context", "reader", "semantic_ref", "sha256"], String.duplicate("0", 64)),
          put_in(c.d, ["context", "declaration", "thing_id"], "other"),
          put_in(c.d, ["context", "declaration", "capability_key"], "other"),
          put_in(c.d, ["context", "source_ref"], "other"),
          put_in(c.d, ["context", "source_epoch"], String.duplicate("0", 32)),
          put_in(c.d, ["context", "report_owner_epoch"], String.duplicate("0", 32)),
          put_in(c.d, ["context", "store_boot_epoch"], "other"),
          put_in(c.d, ["context", "receipt_clock", "source_origin_us"], "-10000001"),
          put_in(c.d, ["context", "receipt_clock", "source_origin_us"], "9223372036854776000"),
          put_in(c.d, ["context", "declaration", "freshness_ms"], 999),
          put_in(
            c.d,
            ["mapping", "basis", "byte_digest"],
            "sha256:" <> String.duplicate("0", 64)
          ),
          put_in(c.d, ["context", "current"], true)
        ] do
      assert {:error, code} = construct(d)
      assert code in [:invalid_external_input, :unsupported_external_input]
    end
  end

  test "Home converted scale stays distinct while integer range and reader quantity remain exact",
       c do
    assert c.d["context"]["declaration"]["unit"]["scale_d"] == "1000"
    assert c.d["context"]["reader"]["external_unit"]["scale_d"] == "1"

    assert {:ok, _} =
             construct(
               put_in(
                 c.d,
                 ["context", "declaration", "constraints", "min"],
                 -9_223_372_036_854_775_808
               )
             )

    for d <- [
          put_in(
            c.d,
            ["context", "declaration", "constraints", "min"],
            9_223_372_036_854_775_808
          ),
          put_in(c.d, ["context", "declaration", "constraints"], %{"min" => 2, "max" => 1}),
          put_in(c.d, ["context", "declaration", "unit", "quantity_kind"], "urn:other:quantity"),
          put_in(c.d, ["context", "declaration", "unit", "dimension"], [0, 0, 0, 0, 0, 0, 0]),
          put_in(c.d, ["context", "declaration", "constraints"], nil)
        ] do
      assert {:error, _} = construct(d)
    end
  end

  test "actual integer, Boolean and enum readers supply exact pure review correspondence", c do
    original = F.new()
    {:ok, producer} = ProducerIdentity.current()
    {:ok, runtime, runtime_sha256} = ExternalInputRuntime.current()

    for typed <- [
          original,
          F.typed(original, "boolean", false),
          F.typed(original, "boolean", true),
          F.typed(original, "enum", "0"),
          F.typed(original, "enum", "1")
        ] do
      actual =
        F.build(
          Map.put(typed.vector, "producer_assertion", producer),
          typed.source,
          typed.consumer,
          typed.report
        )

      policy =
        Map.take(
          c.d["context"]["declaration"],
          ~w(thing_id capability_key evidence_ref risk_class freshness_ms)
        )

      {:ok, declaration} =
        ExternalReadDeclaration.new(
          actual.context["envelope"],
          actual.consumer,
          policy,
          "sample",
          actual.source["reader_limits"]
        )

      context =
        Map.merge(c.d["context"], %{
          "declaration" => declaration.data,
          "reader" =>
            Map.merge(
              Map.take(typed.mapping, Map.keys(c.d["context"]["reader"]) -- ["value_schema"]),
              %{"value_schema" => declaration.data["value_schema"]}
            ),
          "runtime" => runtime,
          "runtime_sha256" => runtime_sha256
        })

      mapping =
        typed.mapping
        |> Map.put("receipt_clock", context["receipt_clock"])
        |> put_in(["basis", "output"], nil)
        |> put_in(["basis", "implementation_digest"], "sha256:" <> runtime_sha256)
        |> put_in(["basis", "compiler_digest"], "sha256:" <> runtime_sha256)

      basis_bytes =
        F.encode(
          Map.drop(
            mapping["basis"],
            ~w(byte_digest semantic_digest implementation_digest compiler_digest)
          )
        )

      mapping =
        put_in(
          mapping,
          ["basis", "byte_digest"],
          "sha256:" <> Base.encode16(:crypto.hash(:sha256, basis_bytes), case: :lower)
        )

      reviewed = F.install(typed, Map.delete(mapping, "sha256"))

      d = %{
        c.d
        | "context" => context,
          "mapping" => reviewed.mapping,
          "registry" => reviewed.context["registry"]
      }

      assert {:ok, native} = construct(d)
      assert native.data == d
      assert {:ok, _} = ExternalInput.decode(native.document)

      bad_schema = %{"type" => "array"}

      mismatch =
        d
        |> put_in(["context", "declaration", "value_schema"], bad_schema)
        |> put_in(["context", "reader", "value_schema"], bad_schema)

      assert {:error, :unsupported_external_input} = construct(mismatch)

      if reviewed.mapping["projection"] == "enum" do
        mismatch =
          d
          |> put_in(["context", "declaration", "value_schema", "enum"], ["0"])
          |> put_in(["context", "reader", "value_schema", "enum"], ["0"])

        assert {:error, :unsupported_external_input} = construct(mismatch)
      end
    end
  end

  test "the exact complete registry and every producer identity remain required", c do
    for d <- [
          put_in(c.d, ["registry"], []),
          put_in(c.d, ["registry"], [hd(c.d["registry"]) | c.d["registry"]]),
          put_in(c.d, ["mapping", "sha256"], String.duplicate("0", 64)),
          put_in(
            c.d,
            ["mapping", "legacy_basis_ref", "semantic_digest"],
            "sha256:" <> String.duplicate("0", 64)
          ),
          put_in(c.d, ["mapping", "reader_contract_ref", "sha256"], String.duplicate("0", 64))
        ] do
      assert {:error, _} = construct(d)
    end

    reversed = put_in(c.d, ["registry"], Enum.reverse(c.d["registry"]))
    assert {:ok, reordered} = construct(reversed)
    assert reordered.data == reversed
    refute reordered.sha256 == c.native.sha256
  end

  test "historical outer encoding, chunks and duplicate-free closed inner objects are checked",
       c do
    wire = JSON.decode!(c.native.document)
    [tag, context, mapping, registry, limits] = wire
    {:ok, context_bytes} = DocumentChunks.decode(context, 131_072)

    {:ok, duplicate} =
      DocumentChunks.encode(
        String.replace_prefix(context_bytes, "{", "{\"authority_epoch\":1,"),
        131_072
      )

    for bytes <- [
          c.native.document <> " ",
          JSON.encode!([tag, duplicate, mapping, registry, limits]),
          JSON.encode!([
            tag,
            [
              binary_part(context_bytes, 0, 10),
              binary_part(context_bytes, 10, byte_size(context_bytes) - 10)
            ],
            mapping,
            registry,
            limits
          ]),
          JSON.encode!([
            tag,
            context,
            mapping,
            registry,
            [262_144, 32, 20_000, 8192, 128, 9_223_372_036_854_775_807]
          ]),
          JSON.encode!([tag, context, mapping, registry, limits, "extra"])
        ] do
      assert {:error, _} = ExternalInput.decode(bytes)
    end

    opaque = put_in(c.d, ["mapping", "sha256"], String.duplicate("0", 64))
    historical_bytes = replace_inner(wire, 2, F.encode(opaque["mapping"]))
    assert {:ok, historical} = ExternalInput.decode(historical_bytes)
    assert historical["data"] == opaque
    refute historical["sha256"] == c.native.sha256

    assert {:error, _} =
             ExternalInput.encode(
               struct!(ExternalInput,
                 data: opaque,
                 document: historical_bytes,
                 sha256: historical["sha256"]
               )
             )

    write_mapping = put_in(c.d, ["mapping", "basis", "affordance", "operation"], "writeproperty")

    assert {:error, :invalid_external_input} =
             ExternalInput.decode(replace_inner(wire, 2, F.encode(write_mapping["mapping"])))
  end

  test "whole definition limits include each repeated schema, UTF-8 strings and nested container",
       c do
    schema =
      Map.put(
        c.d["context"]["reader"]["value_schema"],
        "description",
        String.duplicate("å", 4096)
      )

    d = schemas(c.d, schema)
    assert {:ok, native} = construct(d)
    assert {:ok, _} = ExternalInput.decode(native.document)

    nested = Enum.reduce(1..16, true, fn _, value -> %{"x" => value} end)

    for schema <- [
          Map.put(schema, "description", schema["description"] <> "x"),
          Map.put(schema, "examples", Enum.to_list(1..129)),
          Map.put(schema, "examples", List.duplicate(Enum.to_list(1..128), 100)),
          Map.put(schema, "nested", nested)
        ] do
      assert {:error, :external_input_limit} = construct(schemas(c.d, schema))
    end

    assert {:error, :external_input_limit} = ExternalInput.decode(String.duplicate(" ", 262_145))
  end

  test "history remains decodable with actual producer paths absent and native construction refuses" do
    script = """
    alias WotexHome.Rules.ExternalInput
    v = JSON.decode!(File.read!("test/fixtures/profiles/routine-external-inputs.json"))
    for module <- [Wotex.JSON, Wotex.Runtime.Context, Wotex.Profiles.Proposal, Wotex.Routines.InputMapping] do
      path = module |> :code.which() |> List.to_string() |> Path.dirname()
      true = :code.del_path(String.to_charlist(path))
    end
    false = Code.ensure_loaded?(Wotex.JSON)
    false = Code.ensure_loaded?(Wotex.Profiles.Proposal)
    false = Code.ensure_loaded?(Wotex.Routines.InputMapping)
    {:ok, historical} = ExternalInput.decode(v["definition_document"])
    true = historical["data"] == v["definition"]
    true = historical["sha256"] == v["definition_sha256"]
    d = v["definition"]
    {:error, :external_input_unavailable} = ExternalInput.new(d["context"], d["mapping"], d["registry"])
    IO.puts("verified producer-independent historical definition")
    """

    arguments =
      Enum.flat_map(:code.get_path(), fn path -> ["-pa", List.to_string(path)] end) ++
        ["-e", script]

    assert {"verified producer-independent historical definition\n", 0} =
             System.cmd(System.find_executable("elixir"), arguments, stderr_to_stdout: true)
  end

  defp construct(d), do: ExternalInput.new(d["context"], d["mapping"], d["registry"])

  defp schemas(d, schema),
    do:
      d
      |> put_in(["context", "reader", "value_schema"], schema)
      |> put_in(["context", "declaration", "value_schema"], schema)

  defp replace_inner(wire, index, bytes) do
    {:ok, chunks} = DocumentChunks.encode(bytes, 131_072)
    JSON.encode!(List.replace_at(wire, index, chunks))
  end
end
