defmodule ExMaude.ModelScalingTest do
  use ExUnit.Case, async: true
  @moduletag :integration

  test "pairwise models grow quadratically in rewrite count" do
    for {encoder, path, module, operations, rule} <- [
          {ExMaude.IoT.Encoder, ExMaude.iot_rules_path(), "CONFLICT-DETECTOR",
           ~w(detectConflicts detectEnvConflicts detectCascades detectAllConflicts),
           fn i -> %{id: "r#{i}", thing_id: "d#{i}", trigger: {:always}, actions: []} end},
          {ExMaude.AI.Encoder, ExMaude.ai_rules_path(), "AI-CONFLICT-DETECTOR",
           ["detectAllPairConflicts"],
           fn i ->
             %{id: "r#{i}", agent_id: {"t", "a#{i}"}, trigger: {:always}, invocations: []}
           end}
        ],
        operation <- operations do
      [small, large] =
        for count <- [8, 16] do
          {:ok, rules} = encoder.encode_rules(Enum.map(1..count, rule))

          file =
            Path.join(
              System.tmp_dir!(),
              "model-scale-#{System.unique_integer([:positive])}.maude"
            )

          File.write!(
            file,
            "load #{ExMaude.Syntax.encode_string(path)}\nreduce in #{module} : #{operation}(#{rules}) .\nquit\n"
          )

          try do
            {:ok, output, 0} =
              ExMaude.Subprocess.run(
                ExMaude.Binary.path(),
                ["-no-banner", "-no-wrap", file],
                10_000,
                1024 * 1024
              )

            refute output =~ "Warning:"
            [_, rewrites] = Regex.run(~r/rewrites: (\d+)/, output)
            String.to_integer(rewrites)
          after
            File.rm(file)
          end
        end

      assert small > 0
      assert large > small
      assert large < small * 5, "#{operation} repeated work when doubling the rule count"
    end
  end

  test "pairwise enumeration retains every conflict among four rules" do
    pool = :complete_pairs_pool

    start_supervised!(
      ExMaude.Pool.child_spec(
        name: pool,
        pool_size: 1,
        pool_max_overflow: 0,
        worker_module: ExMaude.Backend.Port,
        maude_path: ExMaude.Binary.path()
      )
    )

    rules =
      for id <- ~w(a b c d),
          do: %{
            id: id,
            thing_id: "device",
            trigger: {:always},
            actions: [{:set_prop, "device", "state", id}]
          }

    assert {:ok, conflicts} = ExMaude.IoT.detect_state_conflicts(rules, pool: pool)
    pairs = Enum.sort(Enum.map(conflicts, &Enum.sort([&1.rule1, &1.rule2])))
    assert pairs == [["a", "b"], ["a", "c"], ["a", "d"], ["b", "c"], ["b", "d"], ["c", "d"]]

    agent_rules =
      for id <- ~w(a b c d),
          do: %{
            id: id,
            agent_id: {"tenant", id},
            trigger: {:always},
            invocations: [],
            capability_grants: [{:cap, "search", id}]
          }

    assert {:ok, agent_conflicts} = ExMaude.AI.detect_pair_conflicts(agent_rules, pool: pool)

    agent_pairs =
      agent_conflicts
      |> Enum.filter(&(&1.type == :capability_shadowing))
      |> Enum.map(&Enum.sort([&1.rule1, &1.rule2]))
      |> Enum.sort()

    assert agent_pairs == pairs
  end
end
