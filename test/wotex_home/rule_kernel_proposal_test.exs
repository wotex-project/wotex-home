defmodule WotexHome.RuleKernelProposalTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias WotexHome.Rules.{KernelMapping, KernelProposal, Rule}
  alias WotexHome.Semantics.{Thing, Value}

  @runtime String.duplicate("a", 64)
  @invocation %{
    principal_id: "operator:kernel",
    authority_epoch: 1,
    operation_id: "operation:kernel",
    rule_generation: 1,
    preparation_digest: String.duplicate("b", 64)
  }

  test "the actual public kernel emits one exact Boolean proposal across ownership bounds" do
    for value <- [false, true], ownership <- [1, 10_000, 86_400_000] do
      {rule, thing} = inputs(value, ownership)
      assert {:ok, projection} = KernelProposal.propose(rule, thing, 7, @invocation, @runtime)

      assert {:ok, %Value{kind: :boolean, data: ^value}} =
               KernelProposal.validate(rule, thing, 7, @invocation, @runtime, projection)

      assert projection["program"]["source"]["id"] == rule.id
      assert projection["program"]["source"]["revision"] == "1"
      assert projection["program"]["source"]["run_ms"] == ownership
      assert projection["program"]["source"]["steps"]["input"] == value
      assert projection["program"]["context"]["compiler_basis"] == "sha256:" <> @runtime
      assert [proposal] = projection["result"]["proposals"]
      assert proposal["input"] == value
      iri = "urn:wotex-home:thing:" <> Base.url_encode64(thing.id, padding: false)
      assert proposal["thing_id"] == iri
      assert proposal["resource_domains"] == [iri]
      assert proposal["resource_roles"] == %{"target" => iri}
      assert proposal["path"] == []
      assert proposal["operation"] == "writeproperty"
      assert proposal["completion"] == "reported_match"
      assert proposal["original"] == original(@invocation)
      assert proposal["evidence_contract"]["id"] == "wotex-home.boolean-report"
      run = projection["result"]["run"]
      assert run["deadline_ms"] == ownership
      assert run["spent"] == []
      assert [%{"status" => "proposed", "original" => step}] = run["steps"]
      assert proposal["step_original"] == step
    end
  end

  test "the installed mapping supplies an exact consumer closure with independent byte commitments" do
    {rule, thing} = inputs()
    assert {:ok, mapping} = KernelMapping.build(rule, thing, @runtime)

    assert Enum.map(mapping.context["registry"], & &1["id"]) ==
             ~w(wotex-home.boolean-power wotex-home.boolean-report wotex-home.rule-lifecycle wotex-home.rule-security)

    assert mapping.basis["effects"] == %{
             "resource_roles" => ["target"],
             "repeat" => "never",
             "stop" => "separate_effect",
             "supersession" => "block_until_known",
             "partial_possible" => true,
             "unknown_possible" => true
           }

    assert mapping.basis["evidence"]["freshness_ms"] == 5_000
    assert mapping.basis["evidence"]["sources"] == ["device_report"]
    assert mapping.basis["evidence"]["require_source_time"] == false
    assert mapping.basis["evidence"]["continuity"] == "snapshot"

    assert mapping.basis["analysis"] ==
             %{"classification" => "unsupported", "profile" => nil, "properties" => []}

    descriptor =
      Map.drop(
        mapping.basis,
        ~w(byte_digest semantic_digest implementation_digest compiler_digest)
      )

    assert mapping.basis["byte_digest"] == json_hash(descriptor)
    assert mapping.basis["semantic_digest"] == json_hash(descriptor)
    assert mapping.basis["implementation_digest"] == "sha256:" <> @runtime
    assert mapping.basis["compiler_digest"] == "sha256:" <> @runtime

    security = %{
      "format" => "wotex-home.routine-contract.v1",
      "id" => "wotex-home.rule-security",
      "version" => "1",
      "obligations" =>
        ~w(current_authenticated_invoker current_original_author exact_target_grant single_store_commit)
    }

    assert mapping.basis["security_contract"]["semantic_digest"] == json_hash(security)
    assert mapping.profile.data["effects"] == 1
    assert mapping.profile.data["run_ms"] == 86_400_000
    assert mapping.limits.data["max_bytes"] == 262_144
    assert mapping.limits.data["max_collection_size"] == 128
  end

  test "program identity binds the requested source and runtime while originals bind caller scope" do
    {rule, thing} = inputs()
    assert {:ok, baseline} = KernelProposal.propose(rule, thing, 0, @invocation, @runtime)

    for changed <- [
          %{@invocation | principal_id: "operator:other"},
          %{@invocation | authority_epoch: 2},
          %{@invocation | operation_id: "operation:other"}
        ] do
      assert {:ok, projection} = KernelProposal.propose(rule, thing, 0, changed, @runtime)
      assert projection["program"] == baseline["program"]
      assert hd(projection["result"]["proposals"])["original"] == original(changed)
      refute original(changed) == original(@invocation)
    end

    for changed <- [%{rule | id: "rule:other"}, %{rule | source_revision: 2}] do
      assert {:ok, projection} = KernelProposal.propose(changed, thing, 0, @invocation, @runtime)
      refute projection["program"]["source_digest"] == baseline["program"]["source_digest"]
      refute projection["program"]["ir_digest"] == baseline["program"]["ir_digest"]
    end

    assert {:ok, other_runtime} =
             KernelProposal.propose(rule, thing, 0, @invocation, String.duplicate("c", 64))

    refute other_runtime["program"] == baseline["program"]
    assert other_runtime["mapping_digest"] == baseline["mapping_digest"]
    assert {:ok, basis} = KernelProposal.qualify(rule, thing, @runtime)

    assert basis.kernel_source_digest ==
             String.replace_prefix(baseline["program"]["source_digest"], "sha256:", "")

    assert basis.kernel_ir_digest ==
             String.replace_prefix(baseline["program"]["ir_digest"], "sha256:", "")

    assert basis.kernel_mapping_digest == baseline["mapping_digest"]
    assert basis.kernel_compiler_profile == "wotex.routines.compiler@1"
  end

  test "malformed native values and unsupported semantics cannot silently become a supported rule" do
    {rule, thing} = inputs()

    for changed <- [
          Map.put(rule, :extra, true),
          %{rule | authority_class: :operator},
          %{rule | causal_budget: 2},
          %{rule | cooldown_ms: 1},
          %{rule | ownership_ms: 0},
          %{rule | ownership_ms: 86_400_001},
          %{rule | predicate: %{rule.predicate | args: :forged}},
          %{rule | effect: {thing.id, "power", %Value{kind: :boolean, data: 1}}}
        ] do
      assert {:error, :unsupported_kernel_profile} =
               KernelProposal.propose(changed, thing, 0, @invocation, @runtime)
    end

    for changed <- [
          Map.put(thing, :extra, true),
          %{thing | id: "light:foreign"},
          %{thing | role: "Other"}
        ] do
      assert {:error, :unsupported_kernel_profile} =
               KernelProposal.propose(rule, changed, 0, @invocation, @runtime)
    end

    for changed <- [
          Map.put(@invocation, :extra, true),
          %{@invocation | authority_epoch: 0},
          %{@invocation | rule_generation: 9_223_372_036_854_775_807},
          %{@invocation | principal_id: "invalid identity"},
          %{@invocation | operation_id: String.duplicate("a", 129)},
          %{@invocation | preparation_digest: String.duplicate("A", 64)}
        ] do
      assert {:error, :invalid_kernel_projection} =
               KernelProposal.propose(rule, thing, 0, changed, @runtime)
    end

    assert {:error, :invalid_kernel_projection} =
             KernelProposal.propose(rule, thing, -1, @invocation, @runtime)

    assert {:error, :unsupported_kernel_profile} =
             KernelProposal.propose(rule, thing, 0, @invocation, String.duplicate("a", 63))
  end

  test "maximum native coordinates and identifiers remain exact without integer coercion" do
    {rule, thing} = inputs(true, 86_400_000, String.duplicate("t", 128))
    maximum = 9_223_372_036_854_775_807
    rule = %{rule | id: String.duplicate("r", 128), source_revision: maximum}

    invocation = %{
      @invocation
      | principal_id: String.duplicate("p", 128),
        operation_id: String.duplicate("o", 128),
        authority_epoch: maximum,
        rule_generation: maximum - 1
    }

    assert {:ok, mapping} = KernelMapping.build(rule, thing, @runtime)

    assert {:ok, program} =
             Wotex.Routines.Compiler.compile(
               mapping.source,
               mapping.context,
               mapping.profile,
               mapping.limits
             )

    assert {:ok, _} = Wotex.Routines.Compiler.to_map(program, mapping.profile, mapping.limits)
    assert {:ok, _} = KernelProposal.propose(rule, thing, 0, invocation, @runtime)
    assert {:ok, projection} = KernelProposal.propose(rule, thing, maximum, invocation, @runtime)
    assert projection["program"]["source"]["revision"] == Integer.to_string(maximum)

    assert projection["result"]["basis"]["snapshot"]["resource_revisions"] == %{
             ("urn:wotex-home:thing:" <> Base.url_encode64(thing.id, padding: false)) => maximum
           }

    assert hd(projection["result"]["proposals"])["original"] == original(invocation)

    assert {:error, :invalid_kernel_projection} =
             KernelProposal.propose(rule, thing, maximum + 1, invocation, @runtime)
  end

  test "opaque Home IDs map injectively without imposing producer IRI grammar on them" do
    alphabet = ~c"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:-"

    ids =
      ["a", "A", "light:kernel", String.duplicate("x", 128)] ++
        Enum.map(alphabet, &("i" <> <<&1>>))

    iris =
      for id <- ids do
        {rule, thing} = inputs(false, 1, id)
        assert {:ok, projection} = KernelProposal.propose(rule, thing, 0, @invocation, @runtime)
        iri = hd(projection["result"]["proposals"])["thing_id"]
        assert "urn:wotex-home:thing:" <> suffix = iri
        assert Base.url_decode64!(suffix, padding: false) == id
        iri
      end

    assert length(Enum.uniq(iris)) == length(ids)
  end

  test "every wrapper, result basis and proposal member is checked rather than projected away" do
    {rule, thing} = inputs(true, 10_000)
    {:ok, projection} = KernelProposal.propose(rule, thing, 7, @invocation, @runtime)

    collections = [
      [],
      ["result"],
      ["result", "basis"],
      ["result", "basis", "event"],
      ["result", "basis", "prior"],
      ["result", "basis", "snapshot"],
      ["result", "basis", "time"],
      ["result", "run"],
      ["result", "proposals", Access.at!(0)],
      ["result", "run", "steps", Access.at!(0)]
    ]

    for path <- collections do
      map = if path == [], do: projection, else: get_in(projection, path)

      for key <- Map.keys(map) do
        corrupted = Map.put(map, key, %{"foreign" => "input"})
        mutation = if path == [], do: corrupted, else: put_in(projection, path, corrupted)

        assert {:error, :invalid_kernel_projection} =
                 KernelProposal.validate(rule, thing, 7, @invocation, @runtime, mutation)
      end

      mutation = Map.put(map, "unknown", true)
      mutation = if path == [], do: mutation, else: put_in(projection, path, mutation)

      assert {:error, :invalid_kernel_projection} =
               KernelProposal.validate(rule, thing, 7, @invocation, @runtime, mutation)
    end

    for proposals <- [[], projection["result"]["proposals"] ++ projection["result"]["proposals"]] do
      mutation = put_in(projection, ["result", "proposals"], proposals)

      assert {:error, :invalid_kernel_projection} =
               KernelProposal.validate(rule, thing, 7, @invocation, @runtime, mutation)
    end

    # No shortened deadline is accepted as the canonical initial transition.
    shortened = put_in(projection, ["result", "run", "steps", Access.at!(0), "deadline_ms"], 1)
    {:ok, mapping} = KernelMapping.build(rule, thing, @runtime)

    assert {:error, :invalid_kernel_projection} =
             KernelProposal.validate(rule, thing, 7, @invocation, @runtime, shortened)

    # General retained validity also permits later coordinates. This adapter
    # requires the exact initial transition, including last_ms zero.
    later = put_in(projection, ["result", "run", "last_ms"], 1)

    assert {:ok, _} =
             Wotex.Routines.Run.to_map(
               later["result"]["run"],
               later["program"],
               mapping.profile,
               mapping.limits
             )

    assert {:error, :invalid_kernel_projection} =
             KernelProposal.validate(rule, thing, 7, @invocation, @runtime, later)

    {other_rule, _} = inputs(false, 10_000)
    {:ok, foreign} = KernelProposal.propose(other_rule, thing, 7, @invocation, @runtime)

    assert {:error, :invalid_kernel_projection} =
             KernelProposal.validate(rule, thing, 7, @invocation, @runtime, foreign)
  end

  test "malformed program data and JSON work bounds fail before any value is returned" do
    {rule, thing} = inputs()
    {:ok, projection} = KernelProposal.propose(rule, thing, 0, @invocation, @runtime)

    program_mutations =
      for key <- Map.keys(projection["program"]) do
        put_in(projection, ["program", key], %{"foreign" => true})
      end

    for mutation <-
          program_mutations ++
            [
              Map.put(projection, "extra", true),
              put_in(projection, ["program", "source"], %{
                "oversized" => String.duplicate("s", 8_193)
              }),
              put_in(projection, ["result", "proposals"], List.duplicate(%{}, 129)),
              put_in(
                projection,
                ["result", "basis"],
                Enum.reduce(1..34, nil, fn _, acc -> [acc] end)
              ),
              put_in(projection, ["result", "run"], %Value{kind: :boolean, data: true}),
              put_in(projection, ["program", "source", "condition"], %{
                "op" => "literal",
                "value" => false
              })
            ] do
      assert {:error, :invalid_kernel_projection} =
               KernelProposal.validate(rule, thing, 0, @invocation, @runtime, mutation)
    end
  end

  test "fresh producer-absent VM refuses all pure entry points without loading an alternative" do
    {rule, thing} = inputs()
    ebin = KernelProposal |> :code.which() |> List.to_string() |> Path.dirname()

    script = """
    rule = #{inspect(rule, structs: false, limit: :infinity)}
    thing = #{inspect(thing, structs: false, limit: :infinity)}
    invocation = #{inspect(@invocation)}
    runtime = #{inspect(@runtime)}
    {:error, :routine_kernel_unavailable} = WotexHome.Rules.KernelMapping.build(rule, thing, runtime)
    {:error, :routine_kernel_unavailable} = WotexHome.Rules.KernelProposal.qualify(rule, thing, runtime)
    {:error, :routine_kernel_unavailable} = WotexHome.Rules.KernelProposal.propose(rule, thing, 0, invocation, runtime)
    {:error, :routine_kernel_unavailable} = WotexHome.Rules.KernelProposal.validate(rule, thing, 0, invocation, runtime, %{})
    IO.puts("producer absence refused")
    """

    assert {"producer absence refused\n", 0} =
             System.cmd(System.find_executable("elixir"), ["-pa", ebin, "-e", script],
               stderr_to_stdout: true
             )
  end

  test "actual producer output mutations fail source-specific correspondence in an isolated VM" do
    {rule, thing} = inputs(true, 10_000)

    source =
      Wotex.Routines.Kernel.module_info(:compile)[:source] |> List.to_string() |> File.read!()

    marker = "      with :ok <- checked_run(run, program, profile, limits),\n"
    assert length(String.split(source, marker)) == 2

    mutations = [
      ~S/result = %{result | "proposals" => []}/,
      ~S/result = put_in(result, ["proposals", Access.at!(0), "input"], not hd(result["proposals"])["input"])/,
      ~S/result = put_in(result, ["proposals", Access.at!(0), "original"], "foreign:original")/,
      ~S/result = put_in(result, ["proposals", Access.at!(0), "completion"], "protocol_response")/,
      ~S/result = put_in(result, ["run", "steps", Access.at!(0), "deadline_ms"], 1)/,
      ~S/result = put_in(result, ["basis", "time", "elapsed_ms"], 1)/,
      ~S/result = %{result | "edge" => %{}}/,
      ~S/result = put_in(result, ["run", "spent"], [%{"original" => "foreign:spend", "ref" => "foreign:receipt"}])/,
      ~S/if result["outcome"] == "running", do: raise("injected producer fault")/,
      ~S/if result["outcome"] == "running", do: throw(:injected_producer_fault)/
    ]

    script = """
    rule = #{inspect(rule, structs: false, limit: :infinity)}
    thing = #{inspect(thing, structs: false, limit: :infinity)}
    source = #{inspect(source, limit: :infinity, printable_limit: :infinity)}
    marker = #{inspect(marker)}
    Code.compiler_options(ignore_module_conflict: true)
    for mutation <- #{inspect(mutations, limit: :infinity)} do
      Code.compile_string(String.replace(source, marker, "      " <> mutation <> "\\n" <> marker))
      {:error, reason} = WotexHome.Rules.KernelProposal.qualify(rule, thing, #{inspect(@runtime)})
      true = reason in [:invalid_kernel_projection, :routine_kernel_refused]
      :code.purge(Wotex.Routines.Kernel)
    end
    IO.puts("ten producer mutants refused")
    """

    paths = Enum.flat_map(:code.get_path(), fn path -> ["-pa", List.to_string(path)] end)

    assert {"ten producer mutants refused\n", 0} =
             System.cmd(System.find_executable("elixir"), paths ++ ["-e", script],
               stderr_to_stdout: true
             )
  end

  defp original(invocation) do
    "home:rule:" <>
      Base.encode16(
        :crypto.hash(
          :sha256,
          :erlang.term_to_binary(
            {"wotex-home.rule-original.v1", invocation.principal_id, invocation.authority_epoch,
             invocation.operation_id},
            [:deterministic]
          )
        ),
        case: :lower
      )
  end

  # Independent tiny canonical encoder for this integer/Boolean/string corpus.
  # Do not call the mapping's digest helper or the producer's canonical encoder.
  defp canonical(value) when is_map(value) do
    members =
      value
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, value} -> [JSON.encode!(key), ":", canonical(value)] end)
      |> Enum.intersperse(",")

    ["{", members, "}"]
  end

  defp canonical(value) when is_list(value),
    do: ["[", Enum.intersperse(Enum.map(value, &canonical/1), ","), "]"]

  defp canonical(value), do: JSON.encode!(value)

  defp json_hash(value),
    do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, canonical(value)), case: :lower)

  defp inputs(value \\ true, ownership \\ 1, id \\ "light:kernel") do
    profile = "fixture:kernel:1"

    {:ok, thing} =
      Thing.new(%{
        "id" => id,
        "role" => "Light",
        "profile_ref" => profile,
        "capabilities" => [
          %{
            "thing_id" => id,
            "role" => "Light",
            "key" => "power",
            "value_kind" => "boolean",
            "unit" => "none",
            "operations" => ["read", "write"],
            "risk_class" => "ordinary",
            "profile_ref" => profile,
            "evidence_ref" => "fixture:power:1",
            "freshness_ms" => 5_000,
            "constraints" => %{},
            "extensions" => %{}
          }
        ]
      })

    {:ok, rule} =
      Rule.new(%{
        "version" => 1,
        "id" => "rule:kernel",
        "source_revision" => 1,
        "trigger" => %{"kind" => "explicit_request"},
        "predicate" => %{"op" => "literal_true"},
        "effect" => %{
          "target_id" => id,
          "capability_key" => "power",
          "value" => %{"type" => "boolean", "value" => value}
        },
        "authority_class" => "automation",
        "unknown_policy" => "block",
        "ownership_ms" => ownership,
        "cooldown_ms" => 0,
        "causal_budget" => 1
      })

    {rule, thing}
  end
end
