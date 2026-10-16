Code.require_file(Path.expand("../support/routine_external_fact_fixture.exs", __DIR__))

defmodule WotexHome.ComposedMappingTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias WotexHome.Durable.Registry, as: HomeRegistry
  alias WotexHome.Profiles.{ExternalReadDeclaration, ProducerIdentity}
  alias WotexHome.RoutineExternalFactFixture, as: F
  alias WotexHome.Rules.{ComposedMapping, ComposedProfile, ExternalInput, ExternalInputRuntime}
  alias WotexHome.Semantics.Thing

  @vectors "test/fixtures/routines/composed-mapping.json" |> File.read!() |> JSON.decode!()

  for vector <- @vectors["cases"] do
    @vector vector
    test "full independent mapping vector #{@vector["name"]}" do
      bundle = @vector["bundle"]
      environment = @vector["environment"]
      expected = @vector["expected"]
      assert {:ok, projection} = ComposedMapping.build(bundle, environment)

      assert Map.keys(projection) |> Enum.sort() ==
               Enum.sort(
                 ~w(format scope source_sha256 runtime_sha256 mapping_sha256 bindings program)
               )

      assert projection["format"] == "wotex-home.composed-mapping@1"
      assert projection["scope"] == "composed_mapping_claims_only"
      assert projection["source_sha256"] === expected["source_sha256"]
      assert projection["runtime_sha256"] === environment["runtime_sha256"]
      assert projection["mapping_sha256"] === expected["mapping_sha256"]
      assert projection["bindings"] === expected["bindings"]
      assert projection["program"]["context"] === expected["context"]
      assert projection["program"]["source"] === bundle["source"]
      assert :ok = ComposedMapping.validate(bundle, environment, projection)

      assert {:ok, ^projection} =
               ComposedMapping.build(JSON.encode!(bundle), JSON.encode!(environment))
    end
  end

  test "exact ppm and Kelvin boundaries remain integers and refuse coercion or wider domains" do
    for {name, accepted, refused} <- [
          {"native_write:brightness", [0, 1, 1_000_000], [-1, 1_000_001, 1.0, 0.5, "1"]},
          {"native_write:colour_temperature", [1500, 6500, 9000], [1499, 9001, 6500.0, "6500"]}
        ] do
      vector = vector(name)

      for value <- accepted do
        bundle = put_in(vector["bundle"], ["source", "steps", "input"], value)
        assert {:ok, projection} = ComposedMapping.build(bundle, vector["environment"])
        assert projection["program"]["ir"]["steps"]["input"] === value
      end

      for value <- refused do
        bundle = put_in(vector["bundle"], ["source", "steps", "input"], value)

        assert {:error, :unsupported_composed_mapping} =
                 ComposedMapping.build(bundle, vector["environment"])
      end
    end
  end

  test "selectors cover the whole unused closure and reject unsorted or inconsistent aliases" do
    vector = vector("native_write:power")
    first = hd(vector["bundle"]["bindings"])
    second = %{first | "name" => "unused"}

    child = %{
      vector["bundle"]["source"]
      | "id" => "child",
        "bindings" => ["unused"],
        "steps" => %{"id" => "nothing", "kind" => "noop"}
    }

    bundle = %{vector["bundle"] | "definitions" => [child], "bindings" => [first, second]}
    assert {:ok, projection} = ComposedMapping.build(bundle, vector["environment"])
    assert length(projection["program"]["context"]["bases"]) == 1
    assert Enum.map(projection["bindings"], & &1["name"]) == ["selected", "unused"]

    for changed <- [
          %{bundle | "bindings" => [second, first]},
          %{bundle | "bindings" => [first, first]},
          %{bundle | "bindings" => [first]},
          %{bundle | "definitions" => [child, child]},
          put_in(bundle, ["definitions", Access.at(0), "revision"], "01")
        ] do
      assert {:error, :invalid_composed_mapping} =
               ComposedMapping.build(changed, vector["environment"])
    end

    conflicting =
      put_in(bundle, ["bindings", Access.at(1), "declaration_sha256"], String.duplicate("0", 64))

    assert {:error, :composed_mapping_basis_changed} =
             ComposedMapping.build(conflicting, vector["environment"])
  end

  test "whole declaration changes and exact resource or installation identities are visible" do
    vector = vector("external-temperature")
    assert {:ok, projection} = ComposedMapping.build(vector["bundle"], vector["environment"])

    for environment <- [
          put_in(vector["environment"], ["runtime_sha256"], String.duplicate("9", 64)),
          put_in(vector["environment"], ["targets", Access.at(0), "resource_revision"], 2),
          put_in(
            vector["environment"],
            ["external_inputs", Access.at(0), "install_revision"],
            14
          ),
          put_in(vector["environment"], ["external_inputs", Access.at(0), "generation"], 3)
        ] do
      assert {:error, code} = ComposedMapping.validate(vector["bundle"], environment, projection)
      assert code in [:invalid_composed_projection, :composed_mapping_basis_changed]
    end

    native = vector("native_write:brightness")
    row = hd(native["environment"]["targets"])
    changed = JSON.decode!(row["thing_document"])

    changed =
      update_in(changed, ["capabilities"], fn capabilities ->
        Enum.map(capabilities, fn cap ->
          if cap["key"] == "power", do: %{cap | "freshness_ms" => 4000}, else: cap
        end)
      end)

    {:ok, thing} = Thing.new(changed)
    {:ok, document} = HomeRegistry.encode_thing(thing)

    environment =
      put_in(native["environment"], ["targets", Access.at(0), "thing_document"], document)

    assert {:error, :composed_mapping_basis_changed} =
             ComposedMapping.build(native["bundle"], environment)
  end

  test "different root durations share one installed Basis and retain separate step deadlines" do
    vector = vector("native_write:power")

    programs =
      for duration <- [1000, 2000] do
        bundle =
          vector["bundle"]
          |> put_in(["source", "id"], "duration:#{duration}")
          |> put_in(["source", "run_ms"], duration)

        assert {:ok, projection} = ComposedMapping.build(bundle, vector["environment"])
        projection["program"]
      end

    [first, second] = programs
    assert first["context"]["bases"] === second["context"]["bases"]
    assert hd(first["context"]["bases"])["timing"]["deadline_ms"] == 86_400_000
    assert {:ok, collection} = ComposedProfile.collect(collection_input(programs))
    assert length(collection.data["proposals"]) == 2

    assert Enum.map(collection.data["transitions"], & &1["result"]["run"]["deadline_ms"])
           |> Enum.sort() == [1020, 2020]

    assert Enum.flat_map(collection.data["transitions"], fn transition ->
             Enum.map(transition["result"]["run"]["steps"], & &1["deadline_ms"])
           end)
           |> Enum.sort() == [1020, 2020]

    dispositions =
      Map.new(collection.data["proposals"], fn proposal ->
        {proposal["step_original"], %{"constraint" => "allowed", "override" => "none"}}
      end)

    assert {:ok, arbitration} = ComposedProfile.arbitrate(collection, dispositions)
    assert [selected] = arbitration["selected"]
    assert length(selected) == 2
  end

  test "actual Boolean and enum reader Definitions keep their complete installed meanings" do
    original = F.new()

    for {type, value, expected} <- [
          {"boolean", false, false},
          {"boolean", true, true},
          {"enum", "0", "closed"},
          {"enum", "1", "open"}
        ] do
      typed = F.typed(original, type, value)
      definition = typed_definition(typed)
      {bundle, environment} = installed_external(definition)
      bundle = put_in(bundle, ["source", "condition", "value"], expected)
      assert {:ok, projection} = ComposedMapping.build(bundle, environment)
      assert projection["program"]["context"]["bases"] === [definition.data["mapping"]["basis"]]

      for record <- definition.data["registry"] do
        assert record in projection["program"]["context"]["registry"]
      end

      assert :ok = ComposedMapping.validate(bundle, environment, projection)

      assert projection["program"]["context"]["bindings"]["reading"]["basis"] ===
               definition.data["mapping"]["legacy_basis_ref"]
    end
  end

  test "an unchanged legacy Basis cannot conceal a changed full input Definition" do
    vector = vector("external-temperature")
    assert {:ok, original} = ComposedMapping.build(vector["bundle"], vector["environment"])

    {:ok, historical} =
      ExternalInput.decode(hd(vector["environment"]["external_inputs"])["definition_document"])

    d = historical["data"]
    context = Map.update!(d["context"], "selection_revision", &(&1 + 1))
    assert {:ok, changed} = ExternalInput.new(context, d["mapping"], d["registry"])
    assert changed.data["mapping"]["basis"] === d["mapping"]["basis"]
    {bundle, environment} = installed_external(changed)
    assert {:ok, replacement} = ComposedMapping.build(bundle, environment)
    refute original["mapping_sha256"] == replacement["mapping_sha256"]

    assert {:error, :invalid_composed_projection} =
             ComposedMapping.validate(bundle, environment, original)

    assert {:error, :composed_mapping_basis_changed} =
             ComposedMapping.build(vector["bundle"], environment)
  end

  test "valid HSV and XY declarations remain unsupported instead of scalar coercions" do
    vector = vector("native_write:power")
    row = hd(vector["environment"]["targets"])
    original = JSON.decode!(row["thing_document"])
    [power] = original["capabilities"]

    for {key, kind, unit} <- [{"colour_hsv", "hsv", "mdeg+ppm"}, {"colour_xy", "xy", "ppm"}] do
      cap = %{power | "key" => key, "value_kind" => kind, "unit" => unit}
      assert {:ok, thing} = Thing.new(%{original | "capabilities" => [power, cap]})
      assert {:ok, document} = HomeRegistry.encode_thing(thing)

      bundle =
        vector["bundle"]
        |> put_in(["bindings", Access.at(0), "capability_key"], key)
        |> put_in(["bindings", Access.at(0), "declaration_sha256"], sha(document))

      environment =
        put_in(vector["environment"], ["targets", Access.at(0), "thing_document"], document)

      assert {:error, :unsupported_composed_mapping} = ComposedMapping.build(bundle, environment)
    end
  end

  test "read meanings cannot become effects and native snapshots cannot become edges" do
    for name <- ["native_read:power", "native_read:smoke_state", "external-temperature"] do
      vector = vector(name)
      alias_ = hd(vector["bundle"]["bindings"])["name"]

      bundle =
        put_in(vector["bundle"], ["source", "steps"], %{
          "id" => "write",
          "kind" => "effect",
          "binding" => alias_,
          "input" => false,
          "completion" => "reported_match"
        })

      assert {:error, :unsupported_composed_mapping} =
               ComposedMapping.build(bundle, vector["environment"])
    end

    native = vector("native_read:power")
    bundle = put_in(native["bundle"], ["source", "trigger"], edge("selected", nil))

    assert {:error, :unsupported_composed_mapping} =
             ComposedMapping.build(bundle, native["environment"])

    external = vector("external-temperature")

    bundle =
      put_in(
        external["bundle"],
        ["source", "trigger"],
        edge("reading", %{"enter" => 2000, "exit" => 1900})
      )

    assert {:ok, projection} = ComposedMapping.build(bundle, external["environment"])
    assert projection["program"]["source"]["trigger"] === bundle["source"]["trigger"]
    assert hd(projection["program"]["context"]["bases"])["evidence"]["continuity"] == "continuous"

    smoke = vector("native_read:smoke_state")
    bundle = put_in(smoke["bundle"], ["bindings", Access.at(0), "kind"], "native_write")

    assert {:error, :unsupported_composed_mapping} =
             ComposedMapping.build(bundle, smoke["environment"])
  end

  test "equal registry records merge once and unequal same-id records never select an arrival winner" do
    vector = vector("external-temperature")
    native = vector("native_write:power")

    contract =
      Enum.find(
        native["expected"]["context"]["registry"],
        &(&1["id"] == "wotex-home.composed-security")
      )

    {:ok, historical} =
      ExternalInput.decode(hd(vector["environment"]["external_inputs"])["definition_document"])

    definition = historical["data"]

    for changed <- [
          contract,
          %{contract | "version" => "2"},
          %{contract | "semantic_digest" => "sha256:" <> String.duplicate("a", 64)}
        ] do
      {:ok, rebuilt} =
        ExternalInput.new(
          definition["context"],
          definition["mapping"],
          definition["registry"] ++ [changed]
        )

      bundle =
        put_in(
          vector["bundle"],
          ["bindings", Access.at(0), "input", "definition_sha256"],
          rebuilt.sha256
        )

      environment =
        put_in(
          vector["environment"],
          ["external_inputs", Access.at(0), "definition_document"],
          rebuilt.document
        )

      if changed === contract do
        assert {:ok, projection} = ComposedMapping.build(bundle, environment)

        assert Enum.count(
                 projection["program"]["context"]["registry"],
                 &(&1["id"] == contract["id"])
               ) == 1
      else
        assert {:error, :composed_registry_conflict} = ComposedMapping.build(bundle, environment)
      end
    end
  end

  test "every origin and nested Program field is checked against rebuilt current claims" do
    vector = vector("native_write:brightness")
    assert {:ok, projection} = ComposedMapping.build(vector["bundle"], vector["environment"])

    for {path, value} <- leaves(projection, []) do
      changed = put_in(projection, Enum.map(path, &access/1), changed(value))

      assert {:error, :invalid_composed_projection} =
               ComposedMapping.validate(vector["bundle"], vector["environment"], changed)
    end

    for field <- Map.keys(projection) do
      assert {:error, :invalid_composed_projection} =
               ComposedMapping.validate(
                 vector["bundle"],
                 vector["environment"],
                 Map.delete(projection, field)
               )
    end

    assert {:error, :invalid_composed_projection} =
             ComposedMapping.validate(
               vector["bundle"],
               vector["environment"],
               Map.put(projection, "authorized", true)
             )

    changed_bundle = put_in(vector["bundle"], ["source", "steps", "input"], 2)
    assert {:ok, rehashed} = ComposedMapping.build(changed_bundle, vector["environment"])
    refute projection["source_sha256"] == rehashed["source_sha256"]
    refute projection["mapping_sha256"] == rehashed["mapping_sha256"]
    refute projection["program"]["ir_digest"] == rehashed["program"]["ir_digest"]

    for forgery <- [rehashed, %{projection | "program" => rehashed["program"]}] do
      assert {:error, :invalid_composed_projection} =
               ComposedMapping.validate(vector["bundle"], vector["environment"], forgery)
    end
  end

  test "malformed, oversized and forged native boundaries return payload-free whole refusals" do
    vector = vector("native_write:power")
    bundle = vector["bundle"]
    environment = vector["environment"]

    for value <- [
          self(),
          [nil | false],
          <<255>>,
          Map.put(bundle, :extra, true),
          Map.put(bundle, "authorized", true),
          %ComposedProfile{profile: nil, limits: nil}
        ] do
      assert {:error, :invalid_composed_mapping} = ComposedMapping.build(value, environment)
    end

    duplicate =
      String.replace(
        JSON.encode!(bundle),
        "\"revision\":\"1\"",
        "\"revision\":\"1\",\"revision\":\"1\""
      )

    assert {:error, :invalid_composed_mapping} = ComposedMapping.build(duplicate, environment)

    assert {:error, :composed_mapping_limit} =
             ComposedMapping.build(String.duplicate(" ", 4_194_305), environment)

    assert {:error, :composed_mapping_limit} =
             ComposedMapping.build(
               %{bundle | "bindings" => List.duplicate(hd(bundle["bindings"]), 33)},
               environment
             )

    for value <- [1.0, -1] do
      changed = put_in(environment, ["targets", Access.at(0), "resource_revision"], value)
      assert {:error, :invalid_composed_mapping} = ComposedMapping.build(bundle, changed)
    end

    changed =
      put_in(
        environment,
        ["targets", Access.at(0), "resource_revision"],
        9_223_372_036_854_775_808
      )

    assert {:error, :composed_mapping_limit} = ComposedMapping.build(bundle, changed)
  end

  defp vector(name), do: Enum.find(@vectors["cases"], &(&1["name"] == name))

  defp typed_definition(typed) do
    d = F.read("routine-external-inputs")["definition"]
    {:ok, producer} = ProducerIdentity.current()
    {:ok, runtime, runtime_sha256} = ExternalInputRuntime.current()

    actual =
      F.build(
        Map.put(typed.vector, "producer_assertion", producer),
        typed.source,
        typed.consumer,
        typed.report
      )

    policy =
      Map.take(
        d["context"]["declaration"],
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
      Map.merge(d["context"], %{
        "declaration" => declaration.data,
        "reader" =>
          Map.merge(
            Map.take(typed.mapping, Map.keys(d["context"]["reader"]) -- ["value_schema"]),
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

    mapping = put_in(mapping, ["basis", "byte_digest"], "sha256:" <> sha(basis_bytes))
    reviewed = F.install(typed, Map.delete(mapping, "sha256"))
    {:ok, native} = ExternalInput.new(context, reviewed.mapping, reviewed.context["registry"])
    native
  end

  defp installed_external(definition) do
    vector = vector("external-temperature")
    row = hd(vector["environment"]["targets"])
    thing = JSON.decode!(row["thing_document"])
    [record] = thing["capabilities"]
    declaration_document = F.encode(definition.data["context"]["declaration"])

    record = %{
      record
      | "declaration_document" => declaration_document,
        "declaration_sha256" =>
          sha("wotex-home.external-read-declaration@1\n" <> declaration_document)
    }

    {:ok, native} = Thing.new(%{thing | "capabilities" => [record]})
    {:ok, document} = HomeRegistry.encode_thing(native)

    bundle =
      vector["bundle"]
      |> put_in(["bindings", Access.at(0), "declaration_sha256"], sha(document))
      |> put_in(["bindings", Access.at(0), "input", "definition_sha256"], definition.sha256)

    environment =
      vector["environment"]
      |> put_in(["targets", Access.at(0), "thing_document"], document)
      |> put_in(["external_inputs", Access.at(0), "definition_document"], definition.document)

    {bundle, environment}
  end

  defp collection_input(programs) do
    ids = Enum.map(programs, & &1["ir_digest"])

    entries =
      Enum.map(programs, fn program ->
        binding = program["context"]["bindings"]["selected"]
        target = binding["thing_id"]

        %{
          "program" => program,
          "event" => %{
            "kind" => "manual",
            "program_digest" => program["ir_digest"],
            "original" => "original:" <> program["source"]["id"]
          },
          "prior" => %{"original" => nil, "busy" => nil, "edge" => nil},
          "snapshot" => %{
            "id" => "fixture:cut",
            "membership_generation" => "fixture:members",
            "active_programs" => ids,
            "resource_revisions" => %{target => 3},
            "facts" => %{"selected" => nil},
            "binding_bases" => %{
              "selected" => %{
                "profile_digest" => binding["basis"]["semantic_digest"],
                "source_id" => target,
                "source_epoch" => "fixture:connection",
                "source_time_basis" => nil
              }
            }
          }
        }
      end)

    %{
      "format" => "wotex.routines.collection-input@2",
      "membership" => %{"generation" => "fixture:members", "programs" => ids},
      "entries" => entries,
      "time" => %{
        "format" => "wotex.routines.time@2",
        "epoch" => "fixture:boot",
        "clock_generation" => "fixture:elapsed",
        "elapsed_ms" => 20,
        "utc_generation" => nil,
        "utc_low_ms" => nil,
        "utc_high_ms" => nil
      }
    }
  end

  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp edge(binding, hysteresis),
    do: %{
      "kind" => "edge",
      "binding" => binding,
      "direction" => "rising",
      "debounce_ms" => 0,
      "cooldown_ms" => 0,
      "hysteresis" => hysteresis
    }

  defp leaves(map, path) when is_map(map),
    do: Enum.flat_map(map, fn {key, value} -> leaves(value, path ++ [key]) end)

  defp leaves(list, path) when is_list(list),
    do:
      list
      |> Enum.with_index()
      |> Enum.flat_map(fn {value, index} -> leaves(value, path ++ [index]) end)

  defp leaves(value, path), do: [{path, value}]
  defp access(index) when is_integer(index), do: Access.at(index)
  defp access(key), do: key
  defp changed(value) when is_binary(value), do: value <> ":changed"
  defp changed(9_223_372_036_854_775_807), do: 9_223_372_036_854_775_806
  defp changed(value) when is_integer(value), do: value + 1
  defp changed(value) when is_boolean(value), do: not value
  defp changed(nil), do: "changed"
end
