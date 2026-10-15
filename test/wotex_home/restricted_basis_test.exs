defmodule WotexHome.RestrictedBasisTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias WotexHome.Rules.{
    AdmissionArtifact,
    Codec,
    Compiler,
    KernelProposal,
    RestrictedBasis,
    Rule
  }

  alias WotexHome.Durable.Registry
  alias WotexHome.RuntimeArtifacts
  alias WotexHome.Semantics.Thing

  @power %{
    "thing_id" => "light:desk",
    "role" => "Light",
    "key" => "power",
    "value_kind" => "boolean",
    "unit" => "none",
    "operations" => ["read", "write"],
    "risk_class" => "ordinary",
    "profile_ref" => "lifx.old:1",
    "evidence_ref" => "fixture:power:1",
    "freshness_ms" => 5_000,
    "constraints" => %{},
    "extensions" => %{}
  }

  @rule %{
    "version" => 1,
    "id" => "rule:power-on",
    "source_revision" => 1,
    "trigger" => %{"kind" => "explicit_request"},
    "predicate" => %{"op" => "literal_true"},
    "effect" => %{
      "target_id" => "light:desk",
      "capability_key" => "power",
      "value" => %{"type" => "boolean", "value" => true}
    },
    "authority_class" => "automation",
    "unknown_policy" => "block",
    "ownership_ms" => 10_000,
    "cooldown_ms" => 0,
    "causal_budget" => 1
  }

  test "one explicit Boolean Light rule receives a digest-bound proposal basis" do
    assert {:ok, rule} = Rule.new(@rule)
    things = registry()

    assert {:ok, basis} = RestrictedBasis.qualify([rule], things)
    assert basis.result == :basis_complete
    assert basis.profile == "explicit-boolean-light-v4"
    assert basis.scope == :proposal_generation_only
    assert :runtime_correspondence in basis.obligations
    assert :pure_gate_precedence in basis.obligations
    assert :blocked_root_preservation in basis.obligations
    assert :closed_source_bound_ir in basis.obligations
    assert :compiler_correspondence in basis.obligations
    assert {:ok, program} = Compiler.compile([rule])
    assert basis.compiler_profile == program.profile
    assert basis.source_digest == program.source_digest
    assert basis.ir_digest == program.ir_digest
    assert byte_size(basis.rule_digest) == 64
    assert byte_size(basis.registry_digest) == 64
    assert byte_size(basis.runtime_digest) == 64
    assert {:ok, ^basis} = RestrictedBasis.qualify([rule], things)
    assert RestrictedBasis.valid?(basis)
    assert :ok = RestrictedBasis.current(basis, [rule], things)

    assert {:ok, expected} =
             RuntimeArtifacts.digest(
               RuntimeArtifacts.temporal_applications(),
               "wotex-home.explicit-kernel-runtime.v1"
             )

    assert basis.runtime_digest == expected

    assert Enum.take(basis.obligations, -3) == [
             :generic_manual_kernel,
             :exact_single_proposal,
             :complete_kernel_runtime_cohort
           ]

    assert {:ok, kernel} = KernelProposal.qualify(rule, things["light:desk"], expected)
    assert Map.take(basis, Map.keys(kernel)) == kernel

    assert {:ok, changed} = Rule.new(%{@rule | "source_revision" => 2})
    assert {:ok, changed_basis} = RestrictedBasis.qualify([changed], things)
    refute changed_basis.rule_digest == basis.rule_digest

    assert {:ok, alternate_id} = Rule.new(%{@rule | "id" => "rule:other"})

    assert {:ok, %{result: :basis_complete}} =
             RestrictedBasis.qualify([alternate_id], things)
  end

  test "edge, predicate, extra budget and extra writer remain outside the basis" do
    things = registry()
    assert {:ok, rule} = Rule.new(@rule)

    edge =
      %{
        @rule
        | "trigger" => %{
            "kind" => "rising_edge",
            "fact" => %{"thing_id" => "light:desk", "capability_key" => "power"}
          }
      }

    assert {:ok, edge_rule} = Rule.new(edge)

    assert {:error, _reason} = RestrictedBasis.qualify([edge_rule], things)

    assert {:ok, predicate_rule} =
             Rule.new(%{
               @rule
               | "predicate" => %{
                   "op" => "eq",
                   "fact" => %{"thing_id" => "light:desk", "capability_key" => "power"},
                   "value" => %{"type" => "boolean", "value" => true}
                 }
             })

    assert {:error, _reason} = RestrictedBasis.qualify([predicate_rule], things)

    for field <- ["causal_budget", "cooldown_ms"] do
      assert {:ok, widened} =
               Rule.new(Map.put(@rule, field, if(field == "causal_budget", do: 2, else: 1)))

      assert {:error, :unsupported_restricted_profile} =
               RestrictedBasis.qualify([widened], things)
    end

    assert {:error, :unsupported_restricted_profile} =
             RestrictedBasis.qualify([rule, %{rule | id: "rule:other"}], things)
  end

  test "forged rule and registry cannot obtain a basis" do
    assert {:ok, rule} = Rule.new(@rule)
    things = registry()
    refute match?({:ok, _}, RestrictedBasis.qualify([%{rule | causal_budget: 100}], things))

    refute match?(
             {:ok, _},
             RestrictedBasis.qualify([rule], %{"light:other" => things["light:desk"]})
           )
  end

  test "closed receipts reject relabelled scope, omitted obligations and legacy input" do
    {:ok, rule} = Rule.new(@rule)
    things = registry()
    {:ok, basis} = RestrictedBasis.qualify([rule], things)

    for changed <- [
          %{basis | scope: :admitted},
          %{basis | result: :safe},
          %{basis | profile: "explicit-boolean-light-v1"},
          %{basis | profile: "explicit-boolean-light-v2"},
          %{basis | compiler_profile: "unchecked-ir"},
          Map.delete(basis, :ir_digest),
          %{basis | target_id: ""},
          %{basis | obligations: tl(basis.obligations)},
          %{basis | runtime_digest: "not-a-digest"},
          Map.delete(basis, :basis_digest),
          Map.put(basis, :driver_token, <<1>>)
        ] do
      refute RestrictedBasis.valid?(changed)
      assert {:error, :invalid_proposal_basis} = RestrictedBasis.current(changed, [rule], things)
    end

    assert {:error, :invalid_proposal_basis} = RestrictedBasis.current(nil, [rule], things)
  end

  test "a content-valid but stale receipt is not current input or runtime evidence" do
    {:ok, rule} = Rule.new(@rule)
    things = registry()
    {:ok, basis} = RestrictedBasis.qualify([rule], things)
    {:ok, changed} = Rule.new(%{@rule | "source_revision" => 2})
    assert {:error, :stale_proposal_basis} = RestrictedBasis.current(basis, [changed], things)
    altered = %{basis | runtime_digest: String.duplicate("f", 64)}
    altered = Map.put(altered, :basis_digest, term_digest(Map.delete(altered, :basis_digest)))
    assert RestrictedBasis.valid?(altered)
    assert {:error, :stale_proposal_basis} = RestrictedBasis.current(altered, [rule], things)
    altered = %{basis | ir_digest: String.duplicate("e", 64)}
    altered = Map.put(altered, :basis_digest, term_digest(Map.delete(altered, :basis_digest)))
    assert RestrictedBasis.valid?(altered)
    assert {:error, :stale_proposal_basis} = RestrictedBasis.current(altered, [rule], things)
    declaration = things["light:desk"]
    power = %{declaration.capabilities["power"] | freshness_ms: 4_999}
    revised = %{declaration | capabilities: %{"power" => power}}

    assert {:error, :stale_proposal_basis} =
             RestrictedBasis.current(basis, [rule], %{"light:desk" => revised})
  end

  test "omitted safety, unknown and lease guards and priority inversions fail correspondence" do
    script = """
    alias WotexHome.Rules.{RestrictedBasis, Rule}
    alias WotexHome.Semantics.Thing
    {:ok, rule} = Rule.new(#{inspect(@rule)})
    {:ok, thing} = Thing.new(%{"id" => "light:desk", "role" => "Light", "profile_ref" => "lifx.old:1",
      "capabilities" => [#{inspect(@power)}]})
    things = %{thing.id => thing}
    {:ok, _} = RestrictedBasis.qualify([rule], things)
    Code.compiler_options(ignore_module_conflict: true)
    mutations = [
      "_ = {invariants, leases, epoch, now}; :allow",
      "_ = {leases, epoch, now}; if invariants[target] == :unknown, do: :safety_unknown, else: :allow",
      "_ = {leases, epoch, now}; case invariants[target] do :deny -> :safety_denied; :unknown -> :safety_unknown; :allow -> :allow end",
      "_ = {epoch, now}; if leases != [], do: :operator_override, else: (case invariants[target] do :deny -> :safety_denied; :unknown -> :safety_unknown; :allow -> :allow end)"
    ]
    for expression <- mutations do
      source = "defmodule WotexHome.Rules.RuntimeGate do; def decisions(targets, invariants, leases, epoch, now) do " <>
        "{:ok, Map.new(targets, fn target -> {target, (" <> expression <> ")} end)}; end; end"
      [{module, bytes}] = Code.compile_string(source)
      File.write!(Path.join(private_home, Atom.to_string(module) <> ".beam"), bytes)
      :code.purge(module)
      {:error, :runtime_correspondence_failed} = RestrictedBasis.qualify([rule], things)
      :code.purge(WotexHome.Rules.RuntimeGate)
    end
    IO.puts("mutants rejected")
    """

    isolated_basis(script, "mutants rejected\n")
  end

  test "current and exact historical codecs preserve all content without accepting mixed grammars" do
    {:ok, rule} = Rule.new(@rule)
    {:ok, basis} = RestrictedBasis.qualify([rule], registry())
    historical = historical(basis, rule)

    for receipt <- [basis, historical] do
      assert RestrictedBasis.valid?(receipt)
      assert {:ok, encoded} = RestrictedBasis.to_map(receipt)
      assert {:ok, ^receipt} = RestrictedBasis.from_map(encoded)

      for key <- Map.keys(encoded) do
        assert :error = RestrictedBasis.from_map(Map.delete(encoded, key))
        assert :error = RestrictedBasis.from_map(Map.put(encoded, key, nil))
      end

      for changed <- [
            Map.put(encoded, "foreign", true),
            Map.put(encoded, "result", "safe"),
            Map.put(encoded, "obligations", Enum.reverse(encoded["obligations"])),
            Map.put(encoded, "profile", "explicit-boolean-light-v2")
          ] do
        assert :error = RestrictedBasis.from_map(changed)
      end
    end

    assert {:error, :stale_proposal_basis} =
             RestrictedBasis.current(historical, [rule], registry())

    refute RestrictedBasis.valid?(Map.merge(historical, Map.take(basis, kernel_keys())))
    refute RestrictedBasis.valid?(%{basis | profile: "explicit-boolean-light-v3"})
    assert :error = RestrictedBasis.to_map(nil)
    assert :error = RestrictedBasis.from_map(nil)
  end

  test "historical admissions and codecs remain readable in a fresh producer-absent VM" do
    {:ok, rule} = Rule.new(%{@rule | "ownership_ms" => 1})
    things = registry()
    {:ok, source} = Codec.encode([rule])
    {:ok, declaration} = Registry.encode_thing(things["light:desk"])

    resources = [
      %{"thing_id" => "light:desk", "resource_revision" => 1, "document" => declaration}
    ]

    invariant = %{"target_id" => "light:desk", "revision" => 0, "digest" => nil}
    assert {:ok, current_document} = AdmissionArtifact.build(source, resources, invariant)
    assert {:ok, _} = AdmissionArtifact.current(current_document)
    data = JSON.decode!(current_document)
    {:ok, basis} = RestrictedBasis.from_map(data["proposal_basis"])
    historical = historical(basis, rule)
    {:ok, encoded} = RestrictedBasis.to_map(historical)
    historical_document = JSON.encode!(%{data | "proposal_basis" => encoded})
    assert {:ok, decoded} = AdmissionArtifact.decode(historical_document)
    assert decoded.proposal_basis == historical
    assert {:error, :stale_rule_admission} = AdmissionArtifact.current(historical_document)

    script = """
    false = Code.ensure_loaded?(Wotex.Routines.Kernel)
    {:ok, decoded} = WotexHome.Rules.AdmissionArtifact.decode(#{inspect(historical_document)})
    true = decoded.proposal_basis.profile == "explicit-boolean-light-v3"
    {:ok, encoded} = WotexHome.Rules.RestrictedBasis.to_map(decoded.proposal_basis)
    {:ok, same} = WotexHome.Rules.RestrictedBasis.from_map(encoded)
    true = same == decoded.proposal_basis
    {:error, :stale_proposal_basis} = WotexHome.Rules.RestrictedBasis.current(same, [], %{})
    false = Code.ensure_loaded?(Wotex.Routines.Kernel)
    IO.puts("history decoded")
    """

    ebin = RestrictedBasis |> :code.which() |> List.to_string() |> Path.dirname()

    assert {"history decoded\n", 0} =
             System.cmd(System.find_executable("elixir"), ["-pa", ebin, "-e", script],
               stderr_to_stdout: true
             )
  end

  test "one warm positive proof freshly binds bytes, version, inventory and availability of all ten members" do
    isolated_basis(
      """
      alias WotexHome.Rules.{RestrictedBasis, Rule}
      {:ok, rule} = Rule.new(#{inspect(@rule)})
      {:ok, thing} = WotexHome.Semantics.Thing.new(%{"id" => "light:desk", "role" => "Light", "profile_ref" => "lifx.old:1", "capabilities" => [#{inspect(@power)}]})
      things = %{thing.id => thing}
      {:ok, baseline} = RestrictedBasis.qualify([rule], things)
      {:ok, ^baseline} = RestrictedBasis.qualify([rule], things)
      for app <- RuntimeArtifacts.temporal_applications() do
        directory = Map.fetch!(private_applications, app)
        {:ok, [original_app]} = :file.consult(String.to_charlist(Path.join(directory, Atom.to_string(app) <> ".app")))
        {:application, ^app, properties} = original_app
        [module | _] = Keyword.fetch!(properties, :modules)
        path = Path.join(directory, Atom.to_string(module) <> ".beam")
        original = File.read!(path)
        {:ok, ^module, chunks} = :beam_lib.all_chunks(original)
        {:ok, changed} = :beam_lib.build_module(chunks ++ [{~c"TEST", "proof drift"}])
        {:ok, ^baseline} = RestrictedBasis.qualify([rule], things)
        File.write!(path, changed)
        {:ok, changed_basis} = RestrictedBasis.qualify([rule], things)
        true = changed_basis != baseline
        File.write!(path, original)
        {:ok, ^baseline} = RestrictedBasis.qualify([rule], things)
        for modified <- [Keyword.put(properties, :vsn, ~c"changed"), Keyword.update!(properties, :modules, &tl/1)] do
          :ok = Application.unload(app)
          :ok = :application.load({:application, app, modified})
          {:ok, changed_basis} = RestrictedBasis.qualify([rule], things)
          true = changed_basis != baseline
          :ok = Application.unload(app)
          :ok = :application.load(original_app)
          {:ok, ^baseline} = RestrictedBasis.qualify([rule], things)
        end
        File.rm!(path)
        {:error, :runtime_artifact_unavailable} = RestrictedBasis.qualify([rule], things)
        nil = Process.get({RestrictedBasis, :positive_correspondence})
        File.write!(path, original)
        {:ok, ^baseline} = RestrictedBasis.qualify([rule], things)
      end
      IO.puts("ten members rebound")
      """,
      "ten members rebound\n"
    )
  end

  test "a warm proof cannot hide changed actual kernel proposal semantics" do
    isolated_basis(
      """
      alias WotexHome.Rules.{RestrictedBasis, Rule}
      {:ok, rule} = Rule.new(#{inspect(@rule)})
      {:ok, thing} = WotexHome.Semantics.Thing.new(%{"id" => "light:desk", "role" => "Light", "profile_ref" => "lifx.old:1", "capabilities" => [#{inspect(@power)}]})
      things = %{thing.id => thing}
      {:ok, baseline} = RestrictedBasis.qualify([rule], things)
      {:ok, ^baseline} = RestrictedBasis.qualify([rule], things)
      module = Wotex.Routines.Kernel
      source = module.module_info(:compile)[:source] |> List.to_string() |> File.read!()
      marker = "      with :ok <- checked_run(run, program, profile, limits),\n"
      true = length(String.split(source, marker)) == 2
      mutation = ~S/result = put_in(result, ["proposals", Access.at!(0), "input"], not hd(result["proposals"])["input"])/
      Code.compiler_options(ignore_module_conflict: true)
      [{^module, bytes}] = Code.compile_string(String.replace(source, marker, "      " <> mutation <> "\n" <> marker))
      File.write!(Path.join(private_applications[:wotex_routines], Atom.to_string(module) <> ".beam"), bytes)
      :code.purge(module)
      {:error, :invalid_kernel_projection} = RestrictedBasis.qualify([rule], things)
      nil = Process.get({RestrictedBasis, :positive_correspondence})
      IO.puts("kernel mutant refused")
      """,
      "kernel mutant refused\n"
    )
  end

  test "cold qualification repeats the complete inventory after actual kernel calculation" do
    isolated_basis(
      """
      alias WotexHome.Rules.{RestrictedBasis, Rule}
      {:ok, rule} = Rule.new(#{inspect(@rule)})
      {:ok, thing} = WotexHome.Semantics.Thing.new(%{"id" => "light:desk", "role" => "Light", "profile_ref" => "lifx.old:1", "capabilities" => [#{inspect(@power)}]})
      things = %{thing.id => thing}
      module = Wotex.Routines.Kernel
      source = module.module_info(:compile)[:source] |> List.to_string() |> File.read!()
      marker = "      with :ok <- checked_run(run, program, profile, limits),\n"
      true = length(String.split(source, marker)) == 2
      mutation = ~S/{:ok, [app]} = :file.consult(String.to_charlist(Path.join(private_tz, "tz.app"))); {:application, :tz, properties} = app; :ok = Application.unload(:tz); :ok = :application.load({:application, :tz, Keyword.put(properties, :vsn, ~c"changed-during-kernel")})/
      mutation = String.replace(mutation, "private_tz", inspect(private_applications[:tz]))
      Code.compiler_options(ignore_module_conflict: true)
      [{^module, bytes}] = Code.compile_string(String.replace(source, marker, "      " <> mutation <> "\n" <> marker))
      File.write!(Path.join(private_applications[:wotex_routines], Atom.to_string(module) <> ".beam"), bytes)
      :code.purge(module)
      {:error, :runtime_artifact_unavailable} = RestrictedBasis.qualify([rule], things)
      nil = Process.get({RestrictedBasis, :positive_correspondence})
      IO.puts("cold closing drift refused")
      """,
      "cold closing drift refused\n"
    )
  end

  defp isolated_basis(body, expected) do
    directory =
      Path.join(
        System.tmp_dir!(),
        "woh-kernel-proof-" <> Base.encode16(:crypto.strong_rand_bytes(12))
      )

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)

    paths =
      Map.new(RuntimeArtifacts.temporal_applications(), fn app ->
        original = Application.app_dir(app, "ebin")
        private = Path.join([directory, Atom.to_string(app), "ebin"])
        File.mkdir_p!(private)

        for path <- Path.wildcard(Path.join(original, "*")),
            File.regular?(path),
            do: File.cp!(path, Path.join(private, Path.basename(path)))

        {app, private}
      end)

    script = """
    alias WotexHome.RuntimeArtifacts
    private_applications = #{inspect(paths)}
    private_home = private_applications[:wotex_home]
    _ = private_home
    #{body}
    """

    arguments = Enum.flat_map(paths, fn {_app, path} -> ["-pa", path] end) ++ ["-e", script]

    assert {^expected, 0} =
             System.cmd(System.find_executable("elixir"), arguments, stderr_to_stdout: true)
  end

  defp kernel_keys,
    do: ~w(kernel_mapping_digest kernel_source_digest kernel_ir_digest kernel_compiler_profile)a

  defp historical(basis, rule) do
    basis
    |> Map.drop(kernel_keys() ++ [:basis_digest])
    |> Map.put(:profile, "explicit-boolean-light-v3")
    |> Map.update!(:obligations, &Enum.drop(&1, -3))
    |> Map.put(:rule_digest, term_digest({"explicit-boolean-light-v3", rule}))
    |> Map.put(:runtime_digest, String.duplicate("d", 64))
    |> then(&Map.put(&1, :basis_digest, term_digest(&1)))
  end

  defp term_digest(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp registry do
    assert {:ok, thing} =
             Thing.new(%{
               "id" => "light:desk",
               "role" => "Light",
               "profile_ref" => "lifx.old:1",
               "capabilities" => [@power]
             })

    %{"light:desk" => thing}
  end
end
