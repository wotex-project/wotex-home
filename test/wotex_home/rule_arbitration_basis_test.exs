defmodule WotexHome.RuleArbitrationBasisTest do
  use ExUnit.Case, async: true
  alias WotexHome.Rules.{Arbitration, ArbitrationBasis}
  alias WotexHome.RuntimeArtifacts
  alias WotexHome.Semantics.Value

  test "provided-set receipts bind all originals, complete outcomes and actual runtime" do
    candidates = candidates()
    assert {:ok, basis} = ArbitrationBasis.qualify(candidates)
    assert ArbitrationBasis.valid?(basis)
    assert basis.scope == :provided_proposal_set_only
    assert basis.profile == "whole-thing-arbitration-v1"
    assert basis.limit == 16

    assert basis.obligations ==
             ~w(closed_bounded_input whole_thing_conflicts equivalent_originals_preserved arbitration_before_cutoff deterministic_independent_capacity no_control_authority)a

    assert {:ok, runtime} =
             RuntimeArtifacts.digest(
               [:wotex_home],
               "wotex-home.whole-thing-arbitration-runtime.v1"
             )

    assert basis.runtime_digest == runtime
    assert {:ok, result} = Arbitration.batch(candidates)
    assert basis.outcome_digest == hash({basis.profile, :outcome, result})

    assert basis.input_digest ==
             hash({basis.profile, :input, 16, Enum.sort_by(candidates, & &1.rule_id)})

    assert {:ok, ^basis} = ArbitrationBasis.qualify(Enum.reverse(candidates))
    assert :ok = ArbitrationBasis.current(basis, candidates)

    assert {:ok, empty} = ArbitrationBasis.qualify([], 1)
    assert ArbitrationBasis.valid?(empty)

    complete =
      Enum.map(1..64, fn index ->
        %{hd(candidates) | rule_id: "rule:#{index}", target_id: "light:#{index}"}
      end)

    assert {:ok, full_basis} = ArbitrationBasis.qualify(complete)
    assert :ok = ArbitrationBasis.current(full_basis, Enum.reverse(complete))
    assert {:ok, full_result} = Arbitration.batch(complete)
    assert length(full_result.selected_groups) == 16
    assert length(full_result.capacity_blocked_groups) == 48
    assert full_basis.outcome_digest == hash({full_basis.profile, :outcome, full_result})
  end

  test "current correspondence repeats exact input, original metadata and batch policy" do
    candidates = candidates()
    {:ok, basis} = ArbitrationBasis.qualify(candidates)

    for changed <- [
          tl(candidates),
          List.update_at(candidates, 0, &%{&1 | root_id: "root:changed"}),
          List.update_at(candidates, 0, &%{&1 | ownership_ms: 2}),
          List.update_at(candidates, 0, &%{&1 | depth: 2}),
          List.update_at(candidates, 0, &%{&1 | value: %Value{kind: :boolean, data: false}})
        ] do
      assert {:error, :stale_arbitration_basis} = ArbitrationBasis.current(basis, changed)
    end

    assert {:error, :stale_arbitration_basis} = ArbitrationBasis.current(basis, candidates, 1)
    assert {:error, :invalid_proposal_set} = ArbitrationBasis.qualify(candidates ++ candidates)
    assert {:error, :invalid_proposal_set} = ArbitrationBasis.qualify(candidates, 17)
  end

  test "receipt syntax never accepts relabeling, expanded obligations or forged commitments" do
    {:ok, basis} = ArbitrationBasis.qualify(candidates())

    for changed <- [
          %{basis | result: :admitted},
          %{basis | scope: :autonomous_runtime},
          %{basis | profile: "future-profile"},
          %{basis | limit: 0},
          %{basis | limit: 17},
          %{basis | limit: 1.0},
          %{basis | obligations: []},
          %{basis | obligations: Enum.reverse(basis.obligations)},
          %{basis | input_digest: String.duplicate("A", 64)},
          Map.put(basis, :authority_epoch, 1),
          Map.delete(basis, :runtime_digest)
        ] do
      forged = Map.put(changed, :basis_digest, hash(Map.delete(changed, :basis_digest)))
      refute ArbitrationBasis.valid?(forged)
      assert {:error, :invalid_arbitration_basis} = ArbitrationBasis.current(forged, candidates())
    end

    forged = %{basis | outcome_digest: String.duplicate("a", 64)}
    refute ArbitrationBasis.valid?(forged)
    rehashed = Map.put(forged, :basis_digest, hash(Map.delete(forged, :basis_digest)))
    assert ArbitrationBasis.valid?(rehashed)
    assert {:error, :stale_arbitration_basis} = ArbitrationBasis.current(rehashed, candidates())
  end

  test "matching changed runtime still fails actual-set correspondence after a warmed receipt" do
    path = Path.expand("../../lib/wotex_home/rules/arbitration.ex", __DIR__)
    source = File.read!(path)

    replacements = [
      {"with {:ok, arbitration} <- resolve(candidates) do",
       "with {:ok, arbitration} <- resolve(Enum.take(candidates, limit)) do"},
      {"members = Enum.sort_by(members, & &1.rule_id)",
       "members = Enum.map(Enum.sort_by(members, & &1.rule_id), &%{&1 | ownership_ms: 1})"}
    ]

    for {expression, replacement} <- replacements do
      assert length(String.split(source, expression)) == 2
      mutant = String.replace(source, expression, replacement)
      ebin = Arbitration |> :code.which() |> List.to_string() |> Path.dirname()

      script = """
      alias WotexHome.Rules.{Arbitration, ArbitrationBasis}
      original = #{inspect(ebin)}
      private = Path.join(System.tmp_dir!(), "woh-arbitration-proof-" <> Base.encode16(:crypto.strong_rand_bytes(12)))
      File.mkdir!(private)
      File.chmod!(private, 0o700)
      for path <- Path.wildcard(Path.join(original, "*")), File.regular?(path), do: File.cp!(path, Path.join(private, Path.basename(path)))
      true = :code.del_path(String.to_charlist(original))
      true = :code.add_patha(String.to_charlist(private))
      try do
        candidates = #{inspect(candidates(), limit: :infinity)}
        {:ok, basis} = ArbitrationBasis.qualify(candidates)
        :ok = ArbitrationBasis.current(basis, candidates)
        Code.compiler_options(ignore_module_conflict: true)
        [{Arbitration, bytes}] = Code.compile_string(#{inspect(mutant, limit: :infinity, printable_limit: :infinity)})
        {:error, :runtime_artifact_unavailable} = ArbitrationBasis.current(basis, candidates)
        File.write!(Path.join(private, Atom.to_string(Arbitration) <> ".beam"), bytes)
        :code.purge(Arbitration)
        {:error, :arbitration_correspondence_failed} = ArbitrationBasis.qualify(candidates)
        {:error, :arbitration_correspondence_failed} = ArbitrationBasis.current(basis, candidates)
        IO.puts("verified")
      after
        File.rm_rf!(private)
      end
      """

      assert {"verified\n", 0} =
               System.cmd(System.find_executable("elixir"), ["-pa", ebin, "-e", script],
                 stderr_to_stdout: true
               )
    end
  end

  defp candidates do
    Enum.map(1..17, fn index ->
      %{
        rule_id: "rule:" <> String.pad_leading(Integer.to_string(index), 3, "0"),
        target_id: if(index in [1, 17], do: "light:shared", else: "light:#{index}"),
        capability_key: "power",
        value: %Value{kind: :boolean, data: index != 17},
        root_id: "root:#{index}",
        depth: 1,
        ownership_ms: if(index == 2, do: 86_400_000, else: 1)
      }
    end)
  end

  defp hash(value),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
      |> Base.encode16(case: :lower)
end
