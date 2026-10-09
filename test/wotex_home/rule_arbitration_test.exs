defmodule WotexHome.RuleArbitrationTest do
  use ExUnit.Case, async: true
  alias WotexHome.Rules.{Arbitration, ArbitrationReference}
  alias WotexHome.Semantics.Value

  test "empty and full bounded sets resolve without dropping original members" do
    assert {:ok, %{proposals: [], conflicts: [], suppressed: %{}, groups: []}} =
             Arbitration.resolve([])

    assert {:ok, %{selected_groups: [], capacity_blocked_groups: []}} = Arbitration.batch([])

    candidates = Enum.map(1..64, &proposal(&1, "light:#{&1}", "power", boolean(true)))
    assert {:ok, result} = Arbitration.batch(Enum.reverse(candidates))
    assert result.arbitration.proposals == candidates
    assert length(result.selected_groups) == 16
    assert length(result.capacity_blocked_groups) == 48
    assert members(result.arbitration.groups) == candidates

    assert members(result.selected_groups) ++ members(result.capacity_blocked_groups) ==
             candidates
  end

  test "a conflicting member beyond the batch prefix removes the domain before selection" do
    first = proposal(1, "light:shared", "power", boolean(true))
    middle = Enum.map(2..16, &proposal(&1, "light:#{&1}", "power", boolean(true)))
    last = proposal(17, "light:shared", "power", boolean(false))

    assert {:ok, result} = Arbitration.batch([first | middle] ++ [last])
    assert length(result.selected_groups) == 15
    assert result.capacity_blocked_groups == []

    assert result.arbitration.conflicts == [
             %{target_id: "light:shared", rule_ids: [first.rule_id, last.rule_id]}
           ]

    refute Enum.any?(result.selected_groups, &(&1.target_id == "light:shared"))
    assert {:ok, ^result} = Arbitration.batch([last | Enum.reverse(middle)] ++ [first])
  end

  test "equivalent effects retain every independent root and ownership field" do
    first = proposal(1, "light:shared", "power", boolean(true))
    second = %{proposal(2, "light:shared", "power", boolean(true)) | ownership_ms: 86_400_000}
    third = %{proposal(3, "light:shared", "power", boolean(true)) | depth: 32}

    assert {:ok, result} = Arbitration.batch([third, second, first], 1)
    assert result.arbitration.proposals == [first]

    assert result.arbitration.suppressed == %{
             second.rule_id => :equivalent_effect,
             third.rule_id => :equivalent_effect
           }

    assert [%{members: [^first, ^second, ^third], state: :compatible}] = result.selected_groups
    assert result.capacity_blocked_groups == []
  end

  test "coupled capabilities conflict even when their scalar values agree" do
    first = proposal(1, "light:shared", "power", boolean(true))
    second = proposal(2, "light:shared", "other", boolean(true))

    assert {:ok, %{proposals: [], groups: [%{state: :conflict}]}} =
             Arbitration.resolve([first, second])

    fraction = %Value{kind: :fraction, data: 1}

    assert {:ok, %{proposals: []}} =
             Arbitration.resolve([first, %{second | capability_key: "power", value: fraction}])
  end

  test "pairwise independent reference matches all three-source coupled-effect assignments and permutations" do
    choices =
      for target <- ["light:a", "light:b"],
          {key, value} <- [
            {"power", boolean(true)},
            {"power", boolean(false)},
            {"level", %Value{kind: :fraction, data: 250_000}},
            {"level", %Value{kind: :fraction, data: 750_000}}
          ],
          do: {target, key, value}

    for a <- choices, b <- choices, c <- choices do
      candidates =
        [a, b, c]
        |> Enum.with_index(1)
        |> Enum.map(fn {{target, key, value}, index} -> proposal(index, target, key, value) end)

      expected = reference(candidates)

      for permutation <- permutations(candidates) do
        assert Arbitration.resolve(permutation) == {:ok, expected}

        for limit <- [1, 2, 16] do
          expected_batch = {:ok, reference_batch(expected, limit)}
          assert Arbitration.batch(permutation, limit) == expected_batch
          assert ArbitrationReference.batch(permutation, limit) == expected_batch
        end
      end
    end
  end

  test "invalid identities, duplicate sources, forged values and bounds fail before selection" do
    valid = proposal(1, "light:a", "power", boolean(true))

    invalid = [
      nil,
      %{},
      Map.delete(valid, :root_id),
      Map.put(valid, :authority_class, :safety),
      Map.new(valid, fn {key, value} -> {Atom.to_string(key), value} end),
      %{valid | rule_id: :rule},
      %{valid | target_id: "../foreign"},
      %{valid | capability_key: ""},
      %{valid | root_id: String.duplicate("a", 129)},
      %{valid | depth: 0},
      %{valid | depth: 33},
      %{valid | depth: 1.0},
      %{valid | ownership_ms: 0},
      %{valid | ownership_ms: 86_400_001},
      %{valid | ownership_ms: true},
      %{valid | value: true},
      %{valid | value: %Value{kind: :boolean, data: "true"}},
      %{valid | value: %Value{kind: :fraction, data: 1_000_001}},
      %{valid | value: Map.put(valid.value, :unchecked, true)}
    ]

    for candidate <- invalid do
      assert Arbitration.resolve([candidate]) == {:error, :invalid_proposal_set}
      assert Arbitration.batch([valid, candidate]) == {:error, :invalid_proposal_set}
      assert ArbitrationReference.batch([valid, candidate], 16) == {:error, :invalid_proposal_set}
    end

    for set <- [nil, %{}, [valid | :tail], [valid, valid], List.duplicate(valid, 65)] do
      assert Arbitration.resolve(set) == {:error, :invalid_proposal_set}
      assert Arbitration.batch(set) == {:error, :invalid_proposal_set}
      assert ArbitrationReference.batch(set, 16) == {:error, :invalid_proposal_set}
    end

    for limit <- [0, 17, -1, 1.0, true, nil] do
      assert Arbitration.batch([valid], limit) == {:error, :invalid_proposal_set}
      assert ArbitrationReference.batch([valid], limit) == {:error, :invalid_proposal_set}
    end
  end

  defp proposal(index, target, key, value),
    do: %{
      rule_id: "rule:" <> String.pad_leading(Integer.to_string(index), 3, "0"),
      target_id: target,
      capability_key: key,
      value: value,
      root_id: "root:#{index}",
      depth: 1,
      ownership_ms: 1
    }

  defp boolean(value), do: %Value{kind: :boolean, data: value}
  defp members(groups), do: groups |> Enum.flat_map(& &1.members) |> Enum.sort_by(& &1.rule_id)

  # Separate all-pairs incompatibility relation, then a linear representative
  # scan. This reference uses neither production grouping nor effect deduping.
  defp reference(candidates) do
    ordered = Enum.sort_by(candidates, & &1.rule_id)

    conflicted =
      for left <- ordered,
          right <- ordered,
          left.target_id == right.target_id,
          left.capability_key != right.capability_key or left.value != right.value,
          into: MapSet.new(),
          do: left.target_id

    {proposals, _, suppressed} =
      Enum.reduce(ordered, {[], MapSet.new(), %{}}, fn candidate, {accepted, seen, suppressed} ->
        cond do
          MapSet.member?(conflicted, candidate.target_id) ->
            {accepted, seen, Map.put(suppressed, candidate.rule_id, :effect_conflict)}

          MapSet.member?(seen, candidate.target_id) ->
            {accepted, seen, Map.put(suppressed, candidate.rule_id, :equivalent_effect)}

          true ->
            {accepted ++ [candidate], MapSet.put(seen, candidate.target_id), suppressed}
        end
      end)

    groups =
      for target <- ordered |> Enum.map(& &1.target_id) |> Enum.uniq() |> Enum.sort() do
        %{
          target_id: target,
          members: Enum.filter(ordered, &(&1.target_id == target)),
          state: if(MapSet.member?(conflicted, target), do: :conflict, else: :compatible)
        }
      end

    conflicts =
      for target <- Enum.sort(conflicted),
          do: %{
            target_id: target,
            rule_ids: for(p <- ordered, p.target_id == target, do: p.rule_id)
          }

    %{proposals: proposals, conflicts: conflicts, suppressed: suppressed, groups: groups}
  end

  defp reference_batch(result, limit) do
    eligible =
      for proposal <- result.proposals,
          do: Enum.find(result.groups, &(&1.target_id == proposal.target_id))

    %{
      arbitration: result,
      selected_groups: Enum.take(eligible, limit),
      capacity_blocked_groups: Enum.drop(eligible, limit)
    }
  end

  defp permutations([]), do: [[]]

  defp permutations(list),
    do: for(head <- list, tail <- permutations(list -- [head]), do: [head | tail])
end
