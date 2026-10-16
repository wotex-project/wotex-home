defmodule WotexHome.ComposedMappingSchemaTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Wotex.Routines.{Basis, Registry}
  alias WotexHome.Durable.Registry, as: HomeRegistry
  alias WotexHome.Rules.{ComposedProfile, ExternalInput}

  setup_all do
    raw = "priv/profiles/composed-routine-mapping.schema.json" |> File.read!() |> JSON.decode!()
    vectors = "test/fixtures/routines/composed-mapping.json" |> File.read!() |> JSON.decode!()
    %{schema: ExJsonSchema.Schema.resolve(raw), vectors: vectors}
  end

  test "independently authored complete inputs and full contexts pass selected public constructors",
       c do
    {:ok, selection} = ComposedProfile.new()

    for vector <- c.vectors["cases"] do
      assert valid?(c.schema, "bundle", vector["bundle"])
      assert valid?(c.schema, "environment", vector["environment"])
      expected = vector["expected"]
      context = expected["context"]
      assert {:ok, registry} = Registry.new(context["registry"], selection.limits)

      for basis <- context["bases"] do
        assert {:ok, _} = Basis.new(basis, registry, selection.limits)
      end

      for target <- vector["environment"]["targets"] do
        assert {:ok, thing} = HomeRegistry.decode_thing(target["thing_document"])
        assert thing.id == target["target_id"]
        assert {:ok, document} = HomeRegistry.encode_thing(thing)
        assert document === target["thing_document"]
      end

      for input <- vector["environment"]["external_inputs"] do
        assert {:ok, historical} = ExternalInput.decode(input["definition_document"])
        data = historical["data"]

        assert {:ok, rebuilt} =
                 ExternalInput.new(data["context"], data["mapping"], data["registry"])

        assert rebuilt.document === input["definition_document"]
      end

      assert {:ok, program} = ComposedProfile.compile(vector["bundle"]["source"], context)

      projection = %{
        "format" => "wotex-home.composed-mapping@1",
        "scope" => "composed_mapping_claims_only",
        "source_sha256" => expected["source_sha256"],
        "runtime_sha256" => vector["environment"]["runtime_sha256"],
        "mapping_sha256" => expected["mapping_sha256"],
        "bindings" => expected["bindings"],
        "program" => program.data
      }

      assert valid?(c.schema, "projection", projection)
    end
  end

  test "closed inputs and selectors reject every omission and authority extension", c do
    vector = hd(c.vectors["cases"])

    for {fragment, value} <- [
          {"bundle", vector["bundle"]},
          {"environment", vector["environment"]},
          {"selector", hd(vector["bundle"]["bindings"])},
          {"target", hd(vector["environment"]["targets"])},
          {"origin", hd(vector["expected"]["bindings"])}
        ] do
      for key <- Map.keys(value), do: refute(valid?(c.schema, fragment, Map.delete(value, key)))
      refute valid?(c.schema, fragment, Map.put(value, "authorized", true))
    end
  end

  test "canonical vectors are reproducible without Home or producer digest helpers" do
    {output, status} =
      System.cmd("python3", ["test/support/composed_mapping_oracle.py", "--check"])

    assert status == 0, output
    assert output =~ "12 independent mapping input/hash/Basis vectors agree"
  end

  defp valid?(schema, fragment, value),
    do: ExJsonSchema.Validator.valid_fragment?(schema, "#/definitions/" <> fragment, value)
end
