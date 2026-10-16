defmodule WotexHome.ComposedProfileTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Wotex.Routines.{Error, Limits, Profile, Source}
  alias WotexHome.Rules.ComposedProfile

  @vectors "test/fixtures/routines/composed-profile.json" |> File.read!() |> JSON.decode!()

  test "the Home selection accepts only its complete fixed native or plain bounds" do
    %{"profile" => profile, "limits" => limits} = @vectors["selection"]
    assert {:ok, selection} = ComposedProfile.new()
    assert selection.profile.data === profile
    assert selection.limits.data === limits
    assert {:ok, ^selection} = ComposedProfile.new(profile, limits)
    assert {:ok, ^selection} = ComposedProfile.new(selection.profile, selection.limits)

    for field <- Map.keys(profile) do
      for changed <- [
            Map.delete(profile, field),
            Map.put(profile, field, 0),
            Map.update!(profile, field, &(&1 + 1))
          ] do
        assert {:error, %Error{code: :invalid_profile}} = ComposedProfile.new(changed, limits)
      end
    end

    for field <- Map.keys(limits) do
      for changed <- [
            Map.delete(limits, field),
            Map.put(limits, field, 0),
            Map.update!(limits, field, &(&1 - 1))
          ] do
        assert {:error, %Error{code: :invalid_limits}} = ComposedProfile.new(profile, changed)
      end
    end

    assert {:error, %Error{}} = ComposedProfile.new(Map.put(profile, "authority", true), limits)
    assert {:error, %Error{}} = ComposedProfile.new(profile, Map.put(limits, "authority", true))

    assert {:error, %Error{}} =
             ComposedProfile.new(Map.put(selection.profile, :extra, true), limits)

    assert {:error, %Error{}} =
             ComposedProfile.new(profile, Map.put(selection.limits, :extra, true))
  end

  for vector <- @vectors["cases"] do
    @vector vector
    test "complete source/count vector #{@vector["name"]}" do
      source = @vector["source"]
      context = @vector["context"]
      {counts, paths} = source_inventory(source, context["definitions"])
      assert counts === @vector["expected"]

      case @vector["refusal"] do
        nil ->
          assert {:ok, program} = ComposedProfile.compile(source, context)
          assert :ok = ComposedProfile.current(program, context)
          assert {:ok, plain} = ComposedProfile.to_map(program)
          assert plain === program.data
          assert plain["source"] === source
          assert plain["context"] === context
          assert plain["profile"] === @vectors["selection"]["profile"]
          assert plain["json_limits"] === @vectors["selection"]["limits"]
          assert ir_paths(plain["ir"]["steps"]) === paths
          assert ir_predicates(plain["ir"]) == counts["predicate_nodes"]

        expected ->
          assert {:error, %Error{code: code}} = ComposedProfile.compile(source, context)
          assert Atom.to_string(code) == expected
      end
    end
  end

  test "JSON admission rejects duplicate members, excessive raw bytes and malformed native values" do
    vector = hd(@vectors["cases"])
    {:ok, bytes} = Wotex.JSON.encode(vector["source"])
    assert {:ok, program} = ComposedProfile.compile(bytes, vector["context"])
    assert {:ok, ^program} = ComposedProfile.compile(vector["source"], vector["context"])
    assert {:ok, selection} = ComposedProfile.new()
    assert {:ok, source} = Source.new(vector["source"], selection.profile, selection.limits)
    assert {:ok, ^program} = ComposedProfile.compile(source, vector["context"])

    duplicate =
      String.replace(bytes, "\"revision\":\"1\"", "\"revision\":\"1\",\"revision\":\"1\"")

    for value <- [
          duplicate,
          bytes <> String.duplicate(" ", 32_768),
          <<255>>,
          self(),
          [nil | false],
          Map.put(source, :extra, true),
          Map.put(vector["source"], "authority", true)
        ] do
      assert {:error, %Error{}} = ComposedProfile.compile(value, vector["context"])
    end
  end

  test "typed parameters refuse coercion and complete child closure refuses hidden recursion" do
    vector = hd(@vectors["cases"])
    parameter = %{"type" => "boolean", "unit" => nil, "enum" => []}

    source =
      vector["source"]
      |> put_in(["parameters"], %{"enabled" => parameter})
      |> put_in(["steps", "branches", Access.at(0), "input"], %{"parameter" => "enabled"})

    context = %{vector["context"] | "arguments" => %{"enabled" => true}}
    assert {:ok, program} = ComposedProfile.compile(source, context)
    assert hd(program.data["ir"]["steps"]["branches"])["input"] === true

    assert {:error, %Error{code: :stale_or_forged_program}} =
             ComposedProfile.current(program, put_in(context, ["arguments", "enabled"], false))

    for value <- [1, 1.0, "true", nil, %{"h" => 0, "s" => 0, "v" => 1}] do
      assert {:error, %Error{}} =
               ComposedProfile.compile(source, put_in(context, ["arguments", "enabled"], value))
    end

    recursive = %{
      vector["source"]
      | "id" => "unused",
        "steps" => %{
          "id" => "cycle",
          "kind" => "invoke",
          "routine_id" => "unused",
          "revision" => "1",
          "arguments" => %{}
        }
    }

    assert {:error, %Error{code: :recursive_invocation}} =
             ComposedProfile.compile(
               vector["source"],
               %{vector["context"] | "definitions" => [recursive]}
             )
  end

  test "full correspondence includes unused child bytes, mappings, arguments and compiler basis" do
    vector = Enum.find(@vectors["cases"], &(&1["name"] == "unused-child-retained"))
    context = vector["context"]
    assert {:ok, program} = ComposedProfile.compile(vector["source"], context)

    for changed <- [
          put_in(context, ["definitions", Access.at(0), "steps", "id"], "changed-unused"),
          put_in(context, ["bindings", "output", "thing_id"], "urn:home-fixture:other"),
          %{context | "compiler_basis" => "sha256:" <> String.duplicate("8", 64)}
        ] do
      assert {:ok, _} = ComposedProfile.compile(vector["source"], changed)

      assert {:error, %Error{code: :stale_or_forged_program}} =
               ComposedProfile.current(program, changed)
    end

    forged = put_in(program.data, ["ir", "steps", "path"], [0])
    body = Map.take(forged, ~w(source_digest ir profile compiler_profile))
    {:ok, bytes} = Wotex.JSON.encode(body)
    digest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    forged = %{program | data: Map.put(forged, "ir_digest", digest)}
    assert {:error, %Error{code: :stale_or_forged_program}} = ComposedProfile.to_map(forged)

    {:ok, bytes} = Wotex.JSON.encode(vector["source"])

    members =
      vector["source"]
      |> Map.to_list()
      |> Enum.reverse()
      |> Enum.map_join(",", fn {key, value} -> JSON.encode!(key) <> ":" <> JSON.encode!(value) end)

    reordered = "{" <> members <> "}"
    refute reordered == bytes
    assert {:ok, ^program} = ComposedProfile.compile(bytes, context)
    assert {:ok, ^program} = ComposedProfile.compile(reordered, context)
    assert {:error, %Error{}} = ComposedProfile.to_map(Map.put(program, :extra, true))
  end

  test "a program made with another valid selection cannot pass the fixed Home profile" do
    vector = hd(@vectors["cases"])
    assert {:ok, selection} = ComposedProfile.new()
    {:ok, profile} = Profile.new(%{selection.profile.data | "effects" => 15})
    {:ok, limits} = Limits.new(%{selection.limits.data | "max_bytes" => 1_048_576})

    {:ok, program} =
      Wotex.Routines.Compiler.compile(vector["source"], vector["context"], profile, limits)

    assert {:error, %Error{code: :stale_or_forged_program}} = ComposedProfile.to_map(program)
  end

  test "source bytes and supplied closure have inclusive fixed ceilings" do
    vector = Enum.find(@vectors["cases"], &(&1["name"] == "unused-child-retained"))
    source = %{vector["source"] | "id" => ""}
    remaining = 32_768 - byte_size(JSON.encode!(source))
    source = %{source | "id" => String.duplicate("s", remaining)}
    assert byte_size(JSON.encode!(source)) == 32_768
    context = %{vector["context"] | "definitions" => []}
    assert {:ok, _} = ComposedProfile.compile(source, context)
    assert {:ok, _} = ComposedProfile.compile(JSON.encode!(source), context)
    oversized = %{source | "id" => source["id"] <> "s"}
    assert {:error, %Error{}} = ComposedProfile.compile(oversized, context)
    assert {:error, %Error{}} = ComposedProfile.compile(JSON.encode!(oversized), context)

    root = vector["source"]
    children = Enum.map(1..63, &%{root | "id" => "unused:#{&1}"})
    assert {:ok, program} = ComposedProfile.compile(root, %{context | "definitions" => children})
    assert length(program.data["context"]["definitions"]) == 63
    assert program.data["ir"]["steps"]["kind"] == "noop"

    assert {:error, %Error{code: :definition_bound}} =
             ComposedProfile.compile(
               root,
               %{context | "definitions" => [%{root | "id" => "unused:64"} | children]}
             )
  end

  defp source_inventory(source, definitions) do
    definitions = Map.new(definitions, &{&1["id"], &1})

    counts = %{
      "expanded_nodes" => 0,
      "predicate_nodes" => predicate_size(source["condition"]),
      "effects" => 0,
      "waits" => 0,
      "invocation_depth" => 0,
      "parallel_width" => 0
    }

    inventory([{source["steps"], [], 0}], definitions, counts, [])
  end

  defp inventory([], _, counts, paths), do: {counts, Enum.reverse(paths)}

  defp inventory([{node, path, depth} | rest], definitions, counts, paths) do
    counts =
      counts
      |> Map.update!("expanded_nodes", &(&1 + 1))
      |> Map.update!("invocation_depth", &max(&1, depth))

    {children, counts} =
      case node["kind"] do
        "invoke" ->
          child = Map.fetch!(definitions, node["routine_id"])

          counts =
            Map.update!(counts, "predicate_nodes", &(&1 + predicate_size(child["condition"])))

          {[{child["steps"], path ++ [0], depth + 1}], counts}

        "effect" ->
          {[], Map.update!(counts, "effects", &(&1 + 1))}

        "wait" ->
          counts = Map.update!(counts, "waits", &(&1 + 1))
          {[], Map.update!(counts, "predicate_nodes", &(&1 + predicate_size(node["condition"])))}

        "delay" ->
          {[], Map.update!(counts, "waits", &(&1 + 1))}

        "if" ->
          counts =
            Map.update!(counts, "predicate_nodes", &(&1 + predicate_size(node["condition"])))

          {[{node["then"], path ++ [0], depth}, {node["else"], path ++ [1], depth}], counts}

        "sequence" ->
          {indexed(node["steps"], path, depth), counts}

        "parallel" ->
          counts = Map.update!(counts, "parallel_width", &max(&1, length(node["branches"])))
          {indexed(node["branches"], path, depth), counts}

        "noop" ->
          {[], counts}
      end

    inventory(children ++ rest, definitions, counts, [{path, node["kind"]} | paths])
  end

  defp indexed(children, path, depth),
    do: Enum.with_index(children, fn child, index -> {child, path ++ [index], depth} end)

  defp predicate_size(%{"op" => "not", "arg" => arg}), do: 1 + predicate_size(arg)

  defp predicate_size(%{"op" => op, "args" => args}) when op in ~w(all any),
    do: 1 + Enum.sum(Enum.map(args, &predicate_size/1))

  defp predicate_size(_), do: 1

  defp ir_paths(node),
    do: [{node["path"], node["kind"]} | Enum.flat_map(ir_children(node), &ir_paths/1)]

  defp ir_predicates(ir) do
    length(ir["condition"]) + node_predicates(ir["steps"])
  end

  defp node_predicates(node) do
    length(Map.get(node, "condition", [])) +
      Enum.sum(Enum.map(ir_children(node), &node_predicates/1))
  end

  defp ir_children(%{"kind" => "invoke", "body" => body}), do: [body]
  defp ir_children(%{"kind" => "if"} = node), do: [node["then"], node["else"]]
  defp ir_children(%{"kind" => "sequence", "steps" => steps}), do: steps
  defp ir_children(%{"kind" => "parallel", "branches" => branches}), do: branches
  defp ir_children(_), do: []
end
