defmodule ExMaude.ConflictRegressionTest do
  use ExUnit.Case, async: false

  test "every IoT detector rejects an echoed unevaluated command" do
    pool = :unverified_iot_pool

    start_supervised!(
      ExMaude.Pool.child_spec(
        name: pool,
        pool_size: 1,
        pool_max_overflow: 0,
        worker_module: ExMaude.Backend.Port,
        maude_path: Path.expand("../support/fake_maude.sh", __DIR__)
      )
    )

    rules = [%{id: "r", thing_id: "device", trigger: {:always}, actions: []}]

    for detector <- [
          :detect_conflicts,
          :detect_state_conflicts,
          :detect_env_conflicts,
          :detect_cascade_conflicts
        ] do
      assert {:error, %ExMaude.Error{type: :parse_error}} =
               apply(ExMaude.IoT, detector, [rules, [pool: pool]])
    end
  end

  test "strict parsers reject invalid suffixes and preserve delimiters inside reasons" do
    cases = [
      {ExMaude.IoT.ConflictParser, "noConflict", " | ",
       ~s/conflict(stateConflict, rule("a", "d", always, nil, 1), rule("b", "d", always, nil, 1), "reason, (with | delimiters)")/},
      {ExMaude.AI.ConflictParser, "noAIConflict", " ||c|| ",
       ~s/aiConflict(authorityEscalation, aiRule("a", agent(tenant("t"), "a"), alwaysP, nilInvocation, noCap, 0, 1), aiRule("b", agent(tenant("t"), "b"), alwaysP, nilInvocation, noCap, 1, 1), "reason, (with ||c|| delimiters)")/}
    ]

    for {parser, empty, separator, valid} <- cases do
      assert {:ok, []} = parser.parse_result(empty)
      assert {:ok, [%{rule1: "a", rule2: "b", reason: reason}]} = parser.parse_result(valid)
      assert reason =~ "delimiters"
      assert {:ok, [_]} = parser.parse_result(valid <> separator <> valid)

      for invalid <- ["garbage", "unfinished(", Regex.replace(~r/^\w+\(/, valid, "unexpected(")] do
        assert {:error, %ExMaude.Error{type: :parse_error}} =
                 parser.parse_result(valid <> separator <> invalid)
      end
    end
  end
end
