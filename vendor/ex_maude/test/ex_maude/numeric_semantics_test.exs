defmodule ExMaude.NumericSemanticsTest do
  use ExUnit.Case, async: true

  @moduletag :integration

  alias ExMaude.Backend.Port
  alias ExMaude.IoT.Encoder

  setup do
    worker =
      start_supervised!(
        {Port, maude_path: ExMaude.Binary.path(), preload_modules: [ExMaude.iot_rules_path()]}
      )

    %{worker: worker}
  end

  test "ordering preserves integers and mixed numeric values in both models", %{worker: worker} do
    huge = Integer.pow(10, 400)

    for {left, right} <- [
          {9_007_199_254_740_993, 9_007_199_254_740_992},
          {-9_007_199_254_740_992, -9_007_199_254_740_993},
          {huge + 1, huge},
          {huge, 1.0e308},
          {9_007_199_254_740_993, 9_007_199_254_740_992.0},
          {2, 1.5},
          {1.5, 1},
          {1.5, 1.25},
          {-1.0, -1.5},
          {1.0000000000000002, 1.0},
          {1.0e308, 1.0e307},
          {5.0e-324, 0.0},
          {5.0e-324, 0},
          {0, -5.0e-324},
          {1.0e-20, 0}
        ],
        {module, prefix} <- [{"CONFLICT-DETECTOR", "cascade"}, {"IOT-EXEC", "num"}],
        {suffix, first, second, expected} <- [
          {"Gt", left, right, "true"},
          {"Gt", right, left, "false"},
          {"Lt", right, left, "true"},
          {"Lt", left, right, "false"},
          {"Gte", left, right, "true"},
          {"Gte", left, left, "true"},
          {"Lte", right, left, "true"},
          {"Lte", left, left, "true"}
        ] do
      command =
        "reduce in #{module} : #{prefix}#{suffix}(#{Encoder.encode_value(first)}, #{Encoder.encode_value(second)}) ."

      assert Port.execute(worker, command) == {:ok, expected}
    end
  end

  test "wrapped equality still distinguishes integers from floats", %{worker: worker} do
    assert {:ok, "false"} =
             Port.execute(
               worker,
               ~s|reduce in PROPERTY-VALUE : eqPropValue(intVal("1"), intVal("1.0")) .|
             )
  end

  test "a large integer threshold exposes the reachable safety counterexample" do
    pool = :numeric_safety_pool
    start_supervised!(ExMaude.Pool.child_spec(name: pool, pool_size: 1, pool_max_overflow: 0))

    rules = [
      %{
        id: "large-threshold",
        thing_id: "counter",
        trigger: {:prop_gt, "value", 9_007_199_254_740_992},
        actions: [{:set_prop, "counter", "alarm", true}]
      }
    ]

    assert {:error, {:counterexample, [_ | _]}} =
             ExMaude.IoT.verify_safety(rules, {:thing_state, "counter", "alarm", true},
               initial_state: [{:thing_state, "counter", "value", 9_007_199_254_740_993}],
               pool: pool
             )

    assert {:error, {:counterexample, [_ | _]}} =
             ExMaude.IoT.verify_safety([], [], pool: pool)
  end
end
